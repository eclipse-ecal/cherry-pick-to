#!/bin/bash
#
# Cherry-pick the pushed commit range onto every target branch derived from
# the source PR's labels and open one pull request per target. Called from
# action.yml; composite actions cannot loop over steps, so the whole
# per-target flow lives here.
#
# A hard failure on one target (missing branch, failed push, ...) does not
# stop the remaining targets; the script exits 1 at the end if any target had
# a hard error. Cherry-pick conflicts are NOT hard errors — they produce a
# pull request with resolution instructions.
#
# Environment (all externally controlled values arrive as env vars and are
# only ever used as quoted shell variables — never build commands from them):
#   TARGETS                  newline-separated target branch names
#   BEFORE, AFTER            commit range, validated by the setup step
#   PR_NUMBER                number of the merged source PR
#   LABEL_PREFIX             used in messages only
#   BRANCH_PREFIX            created branch: <prefix>/<short-sha>/<target>
#   SUCCESS_LABEL, FAILURE_LABEL
#   USE_DRAFT_PR             "true": open conflict PRs as drafts
#   ALLOWED_TARGET_BRANCHES  optional space-separated glob patterns; empty = all
#   INPUT_USER_NAME, INPUT_USER_EMAIL, PUSHER_NAME, PUSHER_EMAIL
#   EXPIRY_WARNING_IN_PR_BODY  "true": append the token expiry warning to PR bodies
#   WARNING_DAYS             expiry warning threshold in days (default: 14)
#   TOKEN_EXPIRATION_DATE, TOKEN_DAYS_LEFT
#                            token expiry as reported by check-token.sh; empty
#                            for non-expiring tokens and the default GITHUB_TOKEN
#   ERROR_HINT               optional extra text appended to the expiry warning
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY
#
# Outputs (GITHUB_OUTPUT): performed, pr-urls, results (JSON array)

set -uo pipefail

short_sha="${AFTER:0:7}"

# Optional warning block appended to every created PR body when the token is
# about to expire (opt-in via the token-expiry-warning-in-pr-body input;
# TOKEN_DAYS_LEFT is empty for non-expiring tokens, which disables it too).
# The same threshold as the workflow warning in check-token.sh.
token_expiry_note=""
if [ "${EXPIRY_WARNING_IN_PR_BODY:-false}" = "true" ] \
    && [[ "${TOKEN_DAYS_LEFT:-}" =~ ^-?[0-9]+$ ]] \
    && [[ "${WARNING_DAYS:-14}" =~ ^[0-9]+$ ]] \
    && [ "$TOKEN_DAYS_LEFT" -lt "${WARNING_DAYS:-14}" ]; then
  token_expiry_note="> [!WARNING]
> The cherry-pick token expires on $TOKEN_EXPIRATION_DATE ($TOKEN_DAYS_LEFT days from now). Renew the fine-grained PAT and update the secret, otherwise the cherry-pick workflows will start failing.${ERROR_HINT:+ $ERROR_HINT}"
fi

error_count=0
target_count=0
performed=false
pr_urls=""
results_json=""

# Branch names are check-ref-format-validated before use, but *invalid*
# targets (from arbitrary label text) are recorded in the results JSON too,
# so escape properly: strip control characters, escape backslash and quote.
json_escape() {
  local s
  s="$(printf '%s' "$1" | tr -d '\000-\037')"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

record() { # <target> <outcome> <pr-url>
  local target="$1" outcome="$2" url="$3" icon
  target_count=$((target_count + 1))
  case "$outcome" in
    success)  icon="✅" ;;
    conflict) icon="⚠️" ;;
    error)    icon="❌"; error_count=$((error_count + 1)) ;;
    *)        icon="⏭️" ;;
  esac
  results_json="${results_json:+$results_json,}{\"target\":\"$(json_escape "$target")\",\"outcome\":\"$outcome\",\"pr-url\":\"$(json_escape "$url")\"}"
  if [ -n "$url" ]; then
    performed=true
    pr_urls+="$url"$'\n'
  fi
  # shellcheck disable=SC2016 # the backticks are literal Markdown code spans
  printf '%s `%s` — %s%s\n' "$icon" "$target" "$outcome" "${url:+ — $url}" >> "$GITHUB_STEP_SUMMARY"
}

validate_branch() { # <name>; returns non-zero for invalid branch names
  [[ "$1" != -* ]] && git check-ref-format "refs/heads/$1" > /dev/null 2>&1
}

# Labels already ensured in this run; avoids re-listing per target.
ensured_labels=""

list_labels() {
  gh label list --repo "$GITHUB_REPOSITORY" --limit 1000 --json name --jq '.[].name'
}

ensure_label() { # <name> <color>
  local name="$1" color="$2" existing
  if grep -Fxq -- "$name" <<< "$ensured_labels"; then
    return 0
  fi
  # Exact match against the full list; `gh label list | grep` would match
  # substrings and only sees the first 30 labels.
  if ! existing="$(list_labels)"; then
    echo "::error::Could not list the labels of '$GITHUB_REPOSITORY'."
    return 1
  fi
  if ! grep -Fxq -- "$name" <<< "$existing"; then
    if ! gh label create "$name" --repo "$GITHUB_REPOSITORY" --color "$color"; then
      # A concurrent workflow run may have created the label in the
      # meantime; only fail if it is still missing.
      if ! existing="$(list_labels)" || ! grep -Fxq -- "$name" <<< "$existing"; then
        echo "::error::Could not create label '$name'."
        return 1
      fi
    fi
  fi
  ensured_labels+="$name"$'\n'
  return 0
}

# Sets g_outcome (success | conflict | skipped-* | error) and g_url.
process_target() { # <target>
  local target="$1"

  if ! validate_branch "$target"; then
    echo "::error::'$target' (from label '${LABEL_PREFIX}${target}') is not a valid branch name."
    g_outcome=error
    return
  fi

  if [ -n "${ALLOWED_TARGET_BRANCHES:-}" ]; then
    # Split with `read` instead of an unquoted expansion: the latter would
    # also perform pathname expansion, silently replacing a pattern like
    # "support/*" with matching paths from the repository checkout.
    local allowed=false pattern
    local -a patterns=()
    read -ra patterns <<< "$ALLOWED_TARGET_BRANCHES"
    for pattern in "${patterns[@]}"; do
      # shellcheck disable=SC2254 # glob matching is the point here
      case "$target" in
        $pattern) allowed=true; break ;;
      esac
    done
    if [ "$allowed" != true ]; then
      echo "::notice::Target branch '$target' does not match allowed-target-branches, skipping."
      g_outcome=skipped-not-allowed
      return
    fi
  fi

  local cherry_pick_branch="$BRANCH_PREFIX/$short_sha/$target"
  if ! validate_branch "$cherry_pick_branch"; then
    echo "::error::'$cherry_pick_branch' is not a valid branch name."
    g_outcome=error
    return
  fi

  if ! git ls-remote --exit-code --heads origin "refs/heads/$target" > /dev/null; then
    echo "::error::Target branch '$target' (from label '${LABEL_PREFIX}${target}') does not exist on origin."
    g_outcome=error
    return
  fi

  if git ls-remote --exit-code --heads origin "refs/heads/$cherry_pick_branch" > /dev/null; then
    echo "::notice::Branch '$cherry_pick_branch' already exists on origin (re-run of this workflow, or someone is resolving conflicts on it), skipping '$target'."
    g_outcome=skipped-branch-exists
    return
  fi

  if ! git fetch -q origin "+refs/heads/$target:refs/remotes/origin/$target" \
      || ! git switch -q --no-track -C "$cherry_pick_branch" "refs/remotes/origin/$target"; then
    echo "::error::Could not create branch '$cherry_pick_branch' from 'origin/$target'."
    g_outcome=error
    return
  fi

  local cherry_pick_ok=true conflict_files=""
  if ! git cherry-pick "${cherry_pick_opts[@]}" "$BEFORE..$AFTER"; then
    cherry_pick_ok=false
    # Capture the conflicting files while the conflict state still exists,
    # then reset to a clean branch and add an empty commit so a PR can be
    # created from it. The bot identity is used for the placeholder commit,
    # it does not carry any of the pusher's work.
    conflict_files="$(git diff --name-only --diff-filter=U)"
    git cherry-pick --abort 2> /dev/null || git reset -q --hard "refs/remotes/origin/$target"
    git -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit --allow-empty -m "Cherry-pick of $BEFORE..$AFTER failed"
  fi

  if [ "$cherry_pick_ok" = true ] \
      && [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/remotes/origin/$target")" ]; then
    echo "::notice::All commits were dropped, their changes already exist on '$target'. Nothing to create a PR for."
    g_outcome=skipped-nothing-to-pick
    return
  fi

  if ! git push origin "HEAD:refs/heads/$cherry_pick_branch"; then
    echo "::error::Could not push branch '$cherry_pick_branch'."
    g_outcome=error
    return
  fi

  local pr_title="[CP #$PR_NUMBER > $target] $original_pr_title"
  local pr_label label_color pr_body
  if [ "$cherry_pick_ok" = true ]; then
    pr_label="$SUCCESS_LABEL"
    label_color="0e8a16"  # green
    pr_body="$(cat <<EOF
# Cherry-pick

Cherry-picked PR #$PR_NUMBER to branch \`$target\`.
The cherry-pick was **successful**.

Please review the changes and **rebase-merge** if desired.

$token_expiry_note
EOF
    )"
  else
    pr_label="$FAILURE_LABEL"
    label_color="d93f0b"  # red
    pr_body="$(cat <<EOF
# Cherry-pick failed

Cherry-picked PR #$PR_NUMBER to branch \`$target\`.
The cherry-pick has **failed**.

The following files have caused conflicts:

\`\`\`
$conflict_files
\`\`\`

## Resolving

Please resolve conflicts manually. You can use this PR and branch to your convenience.

\`\`\`bash
git fetch origin
git checkout -b "local/$cherry_pick_branch" "origin/$target"
git branch -u "origin/$cherry_pick_branch"
git cherry-pick $BEFORE..$AFTER

# Resolve conflicts and use
#     git cherry-pick --continue
# until all conflicts are resolved.

git push -f origin "HEAD:$cherry_pick_branch"
\`\`\`

After resolving all conflicts, **rebase-merge** this PR.

$token_expiry_note
EOF
    )"
  fi

  if ! ensure_label "$pr_label" "$label_color"; then
    g_outcome=error
    return
  fi

  local args=(
    --repo  "$GITHUB_REPOSITORY"
    --base  "$target"
    --head  "$cherry_pick_branch"
    --title "$pr_title"
    --body  "$pr_body"
    --label "$pr_label"
  )
  # Some repos (like personal ones) might not have the draft PR feature.
  if [ "$cherry_pick_ok" != true ] && [ "$USE_DRAFT_PR" = "true" ]; then
    args+=(--draft)
  fi

  # stderr captured separately: gh prints progress there, the URL to stdout.
  local url pr_err
  pr_err="$(mktemp)"
  if ! url="$(gh pr create "${args[@]}" 2> "$pr_err")"; then
    cat "$pr_err"
    if grep -qi 'not permitted to create or approve pull requests' "$pr_err"; then
      # Repository-level gate that the workflow permissions block CANNOT
      # grant; it must be enabled once in the repository settings.
      echo "::error::GitHub Actions is not permitted to create pull requests in this repository. Enable 'Allow GitHub Actions to create and approve pull requests' under Settings > Actions > General > Workflow permissions, or pass a fine-grained PAT to this action. For organization repositories the checkbox may be greyed out until the same setting is enabled at the organization level."
    else
      echo "::error::Could not create the pull request for '$target'."
    fi
    rm -f "$pr_err"
    g_outcome=error
    return
  fi
  rm -f "$pr_err"
  echo "Created pull request: $url"
  g_url="$url"
  if [ "$cherry_pick_ok" = true ]; then
    g_outcome=success
  else
    g_outcome=conflict
  fi
}

# ---------------------------------------------------------------------------

# --empty=drop (git >= 2.45) skips commits whose changes already exist on the
# target branch instead of failing on them. On older git (e.g. self-hosted
# runners) such commits land on the conflict path instead.
# Note: `git <cmd> -h` exits 129 even on success, so grep the captured text —
# piping directly would always fail under pipefail.
cherry_pick_opts=()
cherry_pick_help="$(git cherry-pick -h 2>&1 || true)"
if grep -q -- '--empty' <<< "$cherry_pick_help"; then
  cherry_pick_opts+=(--empty=drop)
fi

git config user.name  "${INPUT_USER_NAME:-${PUSHER_NAME:-github-actions[bot]}}"
git config user.email "${INPUT_USER_EMAIL:-${PUSHER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}}"

if ! original_pr_title="$(gh pr view "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --json title --jq '.title')"; then
  echo "::error::Could not read the title of PR #$PR_NUMBER."
  exit 1
fi

while IFS= read -r target; do
  [ -z "$target" ] && continue
  echo "::group::Cherry-pick to '$target'"
  g_outcome=error
  g_url=""
  process_target "$target"
  echo "::endgroup::"
  record "$target" "$g_outcome" "$g_url"
done <<< "$TARGETS"

# Random heredoc delimiter so that URLs cannot terminate the output block
# early and smuggle in additional outputs.
delimiter="OUTPUT_EOF_${RANDOM}${RANDOM}${RANDOM}"
{
  echo "performed=$performed"
  echo "pr-urls<<$delimiter"
  printf '%s' "$pr_urls"
  echo "$delimiter"
  echo "results=[$results_json]"
} >> "$GITHUB_OUTPUT"

if [ "$error_count" -gt 0 ]; then
  echo "::error::$error_count of $target_count target branch(es) failed. See the log and the run summary for details."
  exit 1
fi
