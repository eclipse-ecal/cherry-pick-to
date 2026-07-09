#!/bin/bash
#
# Check that the token in GH_TOKEN is valid for the current repository and
# warn when it is about to expire. Shared by the root action and the
# check-token sub-action.
#
# Environment:
#   GH_TOKEN           token to check (consumed by the gh CLI)
#   GITHUB_REPOSITORY  "owner/repo" to check access against (set by the runner)
#   WARNING_DAYS       warn when the token expires within this many days (default: 14)
#   ERROR_HINT         optional extra text appended to error and warning messages
#   GITHUB_OUTPUT      step output file (set by the runner)
#
# Outputs (via GITHUB_OUTPUT):
#   valid                  "true" or "false" (the script exits 1 when false)
#   expiration-date        expiration date of the token, empty if it does not expire
#   days-until-expiration  whole days until expiration, empty if it does not expire

set -euo pipefail

warning_days="${WARNING_DAYS:-14}"
error_hint="${ERROR_HINT:-}"

if [[ ! "$warning_days" =~ ^[0-9]+$ ]]; then
  echo "::error::warning-days must be a non-negative integer (got '$warning_days')."
  exit 1
fi

# The workflow's default GITHUB_TOKEN is an ephemeral GitHub App installation
# token (prefix "ghs_"); fine-grained PATs start with "github_pat_". The two
# need different treatment: installation tokens always expire within hours by
# design (no point warning about that), and their permission problems are
# fixed with a workflow permissions block instead of PAT settings.
token_is_installation=false
if [[ "${GH_TOKEN:-}" == ghs_* ]]; then
  token_is_installation=true
fi

permissions_block_advice="Grant the required permissions in the calling workflow or job: permissions: { contents: write, pull-requests: write, issues: write }."

fail_check() { # <message>; appends the error hint, records the output, exits
  local message="$1"
  [ -n "$error_hint" ] && message="$message $error_hint"
  echo "::error::$message"
  echo "valid=false" >> "$GITHUB_OUTPUT"
  exit 1
}

# -i includes the response headers, which carry the token expiration date.
set +e
response="$(gh api -i "repos/$GITHUB_REPOSITORY" 2>&1)"
gh_exit=$?
set -e

# HTTP status, either from the response status line ("HTTP/2.0 401 ...") or
# from the gh error message ("gh: Bad credentials (HTTP 401)").
http_status="$(sed -n 's|^HTTP/[0-9.]* \([0-9]\{3\}\).*|\1|p' <<< "$response" | head -n 1)"
if [ -z "$http_status" ]; then
  http_status="$(sed -n 's|.*(HTTP \([0-9]\{3\}\)).*|\1|p' <<< "$response" | head -n 1)"
fi

if [ "$gh_exit" -ne 0 ]; then
  echo "Response was:"
  echo "$response"
  case "$http_status" in
    401)
      if [ "$token_is_installation" = true ]; then
        fail_check "The workflow's GITHUB_TOKEN was rejected (HTTP 401). This is unexpected for the default token; re-run the workflow, or pass a fine-grained PAT explicitly."
      else
        fail_check "The cherry-pick token is invalid or has expired (HTTP 401). Renew the fine-grained PAT and update the secret that is passed to this action. Note: an expired token also makes actions/checkout fail with \"could not read Username for 'https://github.com': terminal prompts disabled\"."
      fi
      ;;
    403|404)
      if [ "$token_is_installation" = true ]; then
        fail_check "The workflow's GITHUB_TOKEN has no access to '$GITHUB_REPOSITORY' (HTTP $http_status). $permissions_block_advice"
      else
        fail_check "The cherry-pick token was rejected for '$GITHUB_REPOSITORY' (HTTP $http_status). The token itself works, but it has no access to this repository or lacks permissions. Required permissions: Actions (read/write), Contents (read/write), Metadata (read-only), Pull requests (read/write), Workflows (read/write)."
      fi
      ;;
    *)
      fail_check "Could not verify the cherry-pick token (gh exit code $gh_exit, HTTP status '${http_status:-unknown}')."
      ;;
  esac
fi

# A token that can read the repository might still lack write access, which
# would otherwise only surface much later, at the push step. The repository
# response reports the token's effective permissions; when the field is
# missing (empty result), no conclusion can be drawn and the check is skipped.
push_allowed="$(gh api "repos/$GITHUB_REPOSITORY" --jq '.permissions.push' 2> /dev/null || true)"
if [ "$push_allowed" = "false" ]; then
  if [ "$token_is_installation" = true ]; then
    fail_check "The workflow's GITHUB_TOKEN has no write access to '$GITHUB_REPOSITORY' (the default is read-only). $permissions_block_advice"
  else
    fail_check "The cherry-pick token has no write access to '$GITHUB_REPOSITORY'. Grant the fine-grained PAT Contents (read/write) and Pull requests (read/write) on this repository."
  fi
fi

echo "valid=true" >> "$GITHUB_OUTPUT"

if [ "$token_is_installation" = true ]; then
  echo "The workflow's default GITHUB_TOKEN is in use. It is ephemeral by design, so the expiration check is skipped."
  echo "::notice::Running with the default GITHUB_TOKEN: pull requests created by this action will not trigger other workflows, so CI will not run on the cherry-pick PRs. Close and re-open a created PR to run CI on it, or pass a fine-grained PAT for production use."
  {
    echo "expiration-date="
    echo "days-until-expiration="
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# Expiring tokens (fine-grained PATs always expire) are reported through this
# response header. It is absent for non-expiring tokens.
expiration="$(grep -i '^github-authentication-token-expiration:' <<< "$response" | head -n 1 | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '\r' || true)"

if [ -z "$expiration" ]; then
  echo "The token is valid and has no expiration date."
  {
    echo "expiration-date="
    echo "days-until-expiration="
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

if ! expiry_epoch="$(date -d "$expiration" +%s 2> /dev/null)"; then
  echo "::warning::The token is valid, but its expiration date '$expiration' could not be parsed."
  {
    echo "expiration-date=$expiration"
    echo "days-until-expiration="
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
echo "The token is valid and expires on $expiration ($days_left days from now)."
{
  echo "expiration-date=$expiration"
  echo "days-until-expiration=$days_left"
} >> "$GITHUB_OUTPUT"

if [ "$days_left" -lt "$warning_days" ]; then
  message="The cherry-pick token expires on $expiration ($days_left days from now). Renew the fine-grained PAT and update the secret, otherwise the cherry-pick workflows will start failing."
  [ -n "$error_hint" ] && message="$message $error_hint"
  echo "::warning::$message"
fi
