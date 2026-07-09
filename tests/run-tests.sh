#!/bin/bash
#
# Test suite for the cherry-pick-to action.
#
# Runs without touching GitHub: the gh CLI is replaced by stubs and git
# operations run against local fixture repositories. Suites that need tools
# not present on the machine (git, jq) are skipped unless REQUIRE_ALL=1 is
# set (as in CI), in which case a skipped suite fails the run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

skip_suite() {
  if [ "${REQUIRE_ALL:-0}" = "1" ]; then
    fail "SKIPPED but REQUIRE_ALL=1: $1"
  else
    echo "  SKIP: $1"
  fi
}

assert_eq() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi
}

assert_contains() { # <description> <needle> <haystack>
  if grep -qF -- "$2" <<< "$3"; then pass "$1"; else fail "$1 — missing '$2' in: $3"; fi
}

assert_not_contains() { # <description> <needle> <haystack>
  if grep -qF -- "$2" <<< "$3"; then fail "$1 — unexpectedly found '$2' in: $3"; else pass "$1"; fi
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

STEPS="$WORK/steps"
mkdir -p "$STEPS"

extract_steps() {
  local id
  for id in setup pr label branch cherry-pick result describe abort push create-pr; do
    if ! python3 "$ROOT/tests/extract-step.py" "$ROOT/action.yml" "$id" > "$STEPS/$id.sh"; then
      echo "FATAL: could not extract step '$id' from action.yml" >&2
      exit 1
    fi
  done
}

run_step() { # <workdir> <step-script> [KEY=VALUE ...]; stdout+stderr combined
  local workdir="$1" script="$2"
  shift 2
  (cd "$workdir" && env "$@" bash "$script" 2>&1)
}

new_output_file() {
  mktemp -p "$WORK" github_output.XXXXXX
}

get_output() { # <output-file> <key>  (single-line outputs)
  sed -n "s/^$2=//p" "$1" | head -n 1
}

get_block_output() { # <output-file> <key>  (heredoc-style multiline outputs)
  awk -v key="$2" '
    index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); on = 1; next }
    on && $0 == delim { exit }
    on { print }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

make_stubs() {
  # gh stub for scripts/check-token.sh, driven by STUB_MODE.
  mkdir -p "$WORK/bin-token"
  cat > "$WORK/bin-token/gh" <<'SH'
#!/bin/bash
# The write-access check calls `gh api ... --jq '.permissions.push'`; answer
# it from STUB_PUSH_ALLOWED (empty means "field unavailable").
for a in "$@"; do
  if [ "$a" = "--jq" ]; then
    printf '%s' "${STUB_PUSH_ALLOWED:-}"
    exit 0
  fi
done
case "${STUB_MODE:?}" in
  expiring)
    printf 'HTTP/2.0 200 OK\r\ngithub-authentication-token-expiration: %s\r\ncontent-type: application/json\r\n\r\n{"id":1}\n' "${STUB_EXPIRY:?}"
    ;;
  no-header)
    printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n{"id":1}\n'
    ;;
  unauthorized)
    printf 'HTTP/2.0 401 Unauthorized\r\n\r\n{"message":"Bad credentials"}\n'
    echo 'gh: Bad credentials (HTTP 401)' >&2
    exit 1
    ;;
  notfound)
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  network)
    echo 'error connecting to api.github.com' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$WORK/bin-token/gh"

  # General gh stub for the action steps. Logs every invocation to
  # $STUB_STATE/log and answers from STUB_* variables; --jq expressions are
  # applied with the real jq.
  mkdir -p "$WORK/bin-gh"
  cat > "$WORK/bin-gh/gh" <<'SH'
#!/bin/bash
STATE="${STUB_STATE:?}"
{ printf 'CMD:'; printf ' %q' "$@"; echo; } >> "$STATE/log"

jq_expr=""
prev=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && jq_expr="$a"
  prev="$a"
done

case "${1:-} ${2:-}" in
  "api "*)
    if [ -n "$jq_expr" ]; then printf '%s' "${STUB_API_JSON:?}" | jq -r "$jq_expr"; else printf '%s' "${STUB_API_JSON:?}"; fi
    ;;
  "pr view")
    if [ -n "$jq_expr" ]; then printf '%s' "${STUB_PR_JSON:?}" | jq -r "$jq_expr"; else printf '%s' "${STUB_PR_JSON:?}"; fi
    ;;
  "pr create")
    echo "https://github.com/acme/widgets/pull/99"
    ;;
  "label list")
    n=0
    [ -f "$STATE/label_list_count" ] && n="$(cat "$STATE/label_list_count")"
    n=$((n + 1))
    echo "$n" > "$STATE/label_list_count"
    if [ "$n" -ge 2 ] && [ -n "${STUB_LABELS_SECOND+x}" ]; then
      printf '%s' "$STUB_LABELS_SECOND"
    else
      printf '%s' "${STUB_LABELS:-}"
    fi
    ;;
  "label create")
    exit "${STUB_LABEL_CREATE_RC:-0}"
    ;;
  *)
    echo "gh stub: unhandled command: $*" >&2
    exit 64
    ;;
esac
SH
  chmod +x "$WORK/bin-gh/gh"
}

new_stub_state() {
  local state
  state="$(mktemp -d -p "$WORK" stub_state.XXXXXX)"
  : > "$state/log"
  echo "$state"
}

# ---------------------------------------------------------------------------
# Fixture repositories
# ---------------------------------------------------------------------------

FIX_BASE=""
FIX_AFTER=""

commit_file() { # <clone> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -qm "$4"
}

make_repo() { # <dir>; creates <dir>/origin.git and <dir>/clone
  mkdir -p "$1"
  git init -q --bare --initial-branch=main "$1/origin.git"
  git clone -q "$1/origin.git" "$1/clone" 2> /dev/null
  git -C "$1/clone" config user.name "Fixture"
  git -C "$1/clone" config user.email "fixture@example.com"
}

make_standard_fixture() { # <dir>: main = base + 2 commits, support/v1.0 = base
  local c="$1/clone"
  make_repo "$1"
  commit_file "$c" file.txt "base" "base"
  git -C "$c" branch support/v1.0
  commit_file "$c" file.txt "change 1" "change 1"
  commit_file "$c" other.txt "other" "change 2"
  git -C "$c" push -q origin main support/v1.0
  FIX_BASE="$(git -C "$c" rev-parse main~2)"
  FIX_AFTER="$(git -C "$c" rev-parse main)"
}

make_conflict_fixture() { # standard fixture + conflicting commit on support/v1.0
  make_standard_fixture "$1"
  local c="$1/clone"
  git -C "$c" switch -q support/v1.0
  commit_file "$c" file.txt "conflicting change on support" "conflicting change"
  git -C "$c" push -q origin support/v1.0
  git -C "$c" switch -q main
}

make_dropped_fixture() { # the single pushed commit already exists on support/v1.0
  local c="$1/clone"
  make_repo "$1"
  commit_file "$c" file.txt "base" "base"
  git -C "$c" branch support/v1.0
  commit_file "$c" file.txt "same change everywhere" "the change"
  git -C "$c" switch -q support/v1.0
  commit_file "$c" file.txt "same change everywhere" "the same change, applied manually"
  git -C "$c" switch -q main
  git -C "$c" push -q origin main support/v1.0
  FIX_BASE="$(git -C "$c" rev-parse main~1)"
  FIX_AFTER="$(git -C "$c" rev-parse main)"
}

run_setup() { # <clone> <output-file> <target-branch> <before> <after>
  run_step "$1" "$STEPS/setup.sh" \
    TARGET_BRANCH="$3" BRANCH_PREFIX="cherry-pick" \
    INPUT_BEFORE="" INPUT_AFTER="" \
    EVENT_BEFORE="$4" EVENT_AFTER="$5" \
    GITHUB_OUTPUT="$2"
}

# ---------------------------------------------------------------------------
# Suite: YAML validity, script syntax, step wiring
# ---------------------------------------------------------------------------

suite_syntax() {
  echo "== syntax and step wiring =="
  local out
  if out="$(python3 - "$ROOT" <<'PY' 2>&1
import subprocess
import sys

import yaml

root = sys.argv[1]

files = [
    "action.yml",
    "check-token/action.yml",
    "examples/cherry-pick-to.yml",
    "examples/quick-start.yml",
    ".github/workflows/ci.yml",
]
for f in files:
    doc = yaml.safe_load(open(f"{root}/{f}"))
    for step in (doc.get("runs", {}).get("steps") or []):
        if step.get("run"):
            r = subprocess.run(["bash", "-n"], input=step["run"],
                               text=True, capture_output=True)
            assert r.returncode == 0, f"{f} / {step.get('name')}: {r.stderr}"

doc = yaml.safe_load(open(f"{root}/action.yml"))
steps = doc["runs"]["steps"]
ids = [s.get("id") for s in steps]
expected = ["check-token", None, "setup", "pr", "label", "branch",
            "cherry-pick", "result", "describe", "abort", "push", "create-pr"]
assert ids == expected, f"unexpected step chain: {ids}"

checkout = steps[1]
assert checkout["uses"].startswith("actions/checkout@")
assert checkout["if"] == "inputs.checkout == 'true'"
assert checkout["with"]["fetch-depth"] == 0
assert checkout["with"]["token"] == "${{ inputs.token }}"

assert steps[7]["if"] == "steps.label.outputs.continue == 'true'"      # result
assert steps[8]["if"] == "steps.result.outputs.continue == 'true'"     # describe
assert "steps.result.outputs.continue == 'true'" in steps[9]["if"]     # abort
assert "steps.cherry-pick.outcome == 'failure'" in steps[9]["if"]
assert steps[10]["if"] == "steps.result.outputs.continue == 'true'"    # push
assert steps[11]["if"] == "steps.result.outputs.continue == 'true'"    # create-pr

token = doc["inputs"]["token"]
assert token["required"] is False
assert token["default"] == "${{ github.token }}"

example = open(f"{root}/examples/cherry-pick-to.yml").read()
assert "actions/checkout" not in example
assert example.count("uses:") == 1

qs = yaml.safe_load(open(f"{root}/examples/quick-start.yml"))
qs_job = next(iter(qs["jobs"].values()))
perms = qs_job["permissions"]
assert perms["contents"] == "write"
assert perms["pull-requests"] == "write"
assert perms["issues"] == "write"
qs_with = qs_job["steps"][-1].get("with", {})
assert "token" not in qs_with, "quick-start must not pass a token"

print("all checks passed")
PY
  )"; then
    pass "YAML parses, scripts are valid bash, step wiring is correct"
  else
    fail "syntax/wiring: $out"
  fi

  local script
  for script in "$ROOT/scripts/check-token.sh" "$ROOT/tests/run-tests.sh"; do
    if bash -n "$script" 2> /dev/null; then
      pass "bash -n $(basename "$script")"
    else
      fail "bash -n $(basename "$script")"
    fi
  done
}

# ---------------------------------------------------------------------------
# Suite: scripts/check-token.sh
# ---------------------------------------------------------------------------

CT_RC=0
CT_OUT=""
CT_OUTPUTS=""

run_check_token() { # [KEY=VALUE ...]
  CT_OUTPUTS="$(new_output_file)"
  CT_OUT="$(env PATH="$WORK/bin-token:$PATH" GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets \
    GITHUB_OUTPUT="$CT_OUTPUTS" "$@" bash "$ROOT/scripts/check-token.sh" 2>&1)"
  CT_RC=$?
}

suite_check_token() {
  echo "== scripts/check-token.sh =="

  run_check_token STUB_MODE=expiring STUB_EXPIRY="$(date -ud '+5 days 1 hour' '+%Y-%m-%d %H:%M:%S UTC')" \
    WARNING_DAYS=14 ERROR_HINT='See ticket https://example.com/7432'
  assert_eq "expiring soon: exit code" "0" "$CT_RC"
  assert_eq "expiring soon: days output" "5" "$(get_output "$CT_OUTPUTS" days-until-expiration)"
  assert_contains "expiring soon: warning emitted" "::warning::" "$CT_OUT"
  assert_contains "expiring soon: hint included" "https://example.com/7432" "$CT_OUT"

  run_check_token STUB_MODE=expiring STUB_EXPIRY="$(date -ud '+300 days 1 hour' '+%Y-%m-%d %H:%M:%S UTC')" \
    WARNING_DAYS=14
  assert_eq "far future: exit code" "0" "$CT_RC"
  assert_eq "far future: days output" "300" "$(get_output "$CT_OUTPUTS" days-until-expiration)"
  assert_not_contains "far future: no warning" "::warning::" "$CT_OUT"

  run_check_token STUB_MODE=no-header
  assert_eq "no expiry header: exit code" "0" "$CT_RC"
  assert_eq "no expiry header: valid output" "true" "$(get_output "$CT_OUTPUTS" valid)"
  assert_eq "no expiry header: empty date" "" "$(get_output "$CT_OUTPUTS" expiration-date)"
  assert_not_contains "no expiry header: no warning" "::warning::" "$CT_OUT"

  run_check_token STUB_MODE=expiring STUB_EXPIRY="not-a-date at all"
  assert_eq "unparseable date: exit code" "0" "$CT_RC"
  assert_contains "unparseable date: warning" "could not be parsed" "$CT_OUT"

  run_check_token STUB_MODE=unauthorized ERROR_HINT='Renewal: https://example.com/renew'
  assert_eq "401: exit code" "1" "$CT_RC"
  assert_contains "401: friendly error" "invalid or has expired (HTTP 401)" "$CT_OUT"
  assert_contains "401: hint included" "https://example.com/renew" "$CT_OUT"
  assert_eq "401: valid output" "false" "$(get_output "$CT_OUTPUTS" valid)"

  run_check_token STUB_MODE=notfound
  assert_eq "404: exit code" "1" "$CT_RC"
  assert_contains "404: permissions listed" "Required permissions" "$CT_OUT"

  run_check_token STUB_MODE=network
  assert_eq "network error: exit code" "1" "$CT_RC"
  assert_contains "network error: generic message" "Could not verify the cherry-pick token" "$CT_OUT"

  run_check_token STUB_MODE=unauthorized ERROR_HINT="\$(touch $WORK/hint-pwned) \`evil\` \"; rm -rf /"
  assert_eq "hostile hint: exit code" "1" "$CT_RC"
  if [ -e "$WORK/hint-pwned" ]; then
    fail "hostile hint: command injection executed"
  else
    pass "hostile hint: stays inert"
  fi

  run_check_token STUB_MODE=no-header WARNING_DAYS='14; rm -rf /'
  assert_eq "invalid warning-days: exit code" "1" "$CT_RC"
  assert_contains "invalid warning-days: rejected" "non-negative integer" "$CT_OUT"

  # Default GITHUB_TOKEN (ghs_ prefix): ephemeral, so no expiry warning even
  # though the API reports a near-term expiration; CI-trigger notice instead.
  run_check_token GH_TOKEN=ghs_test STUB_MODE=expiring \
    STUB_EXPIRY="$(date -ud '+2 hours' '+%Y-%m-%d %H:%M:%S UTC')" WARNING_DAYS=14
  assert_eq "GITHUB_TOKEN: exit code" "0" "$CT_RC"
  assert_not_contains "GITHUB_TOKEN: no expiry warning" "::warning::" "$CT_OUT"
  assert_contains "GITHUB_TOKEN: CI-trigger notice" "will not trigger other workflows" "$CT_OUT"
  assert_eq "GITHUB_TOKEN: empty days output" "" "$(get_output "$CT_OUTPUTS" days-until-expiration)"
  assert_eq "GITHUB_TOKEN: valid output" "true" "$(get_output "$CT_OUTPUTS" valid)"

  run_check_token GH_TOKEN=ghs_test STUB_MODE=notfound
  assert_eq "GITHUB_TOKEN 404: exit code" "1" "$CT_RC"
  assert_contains "GITHUB_TOKEN 404: permissions block advice" "permissions: { contents: write" "$CT_OUT"
  assert_not_contains "GITHUB_TOKEN 404: no PAT advice" "fine-grained PAT Contents" "$CT_OUT"

  run_check_token GH_TOKEN=github_pat_test STUB_MODE=notfound
  assert_eq "PAT 404: exit code" "1" "$CT_RC"
  assert_contains "PAT 404: PAT permission list" "Required permissions: Actions" "$CT_OUT"

  # Write-access check via .permissions.push
  run_check_token GH_TOKEN=ghs_test STUB_MODE=no-header STUB_PUSH_ALLOWED=false
  assert_eq "read-only GITHUB_TOKEN: exit code" "1" "$CT_RC"
  assert_contains "read-only GITHUB_TOKEN: permissions block advice" \
    "permissions: { contents: write" "$CT_OUT"
  assert_eq "read-only GITHUB_TOKEN: valid output" "false" "$(get_output "$CT_OUTPUTS" valid)"

  run_check_token GH_TOKEN=github_pat_test STUB_MODE=no-header STUB_PUSH_ALLOWED=false
  assert_eq "read-only PAT: exit code" "1" "$CT_RC"
  assert_contains "read-only PAT: Contents advice" "Contents (read/write)" "$CT_OUT"

  run_check_token STUB_MODE=no-header STUB_PUSH_ALLOWED=true
  assert_eq "writable token: exit code" "0" "$CT_RC"

  run_check_token STUB_MODE=no-header
  assert_eq "permissions field unavailable: exit code" "0" "$CT_RC"
}

# ---------------------------------------------------------------------------
# Suite: pr + label steps (gh stub with real jq)
# ---------------------------------------------------------------------------

suite_pr_label() {
  echo "== pr and label steps =="

  local state out of
  state="$(new_stub_state)"

  of="$(new_output_file)"
  run_step "$WORK" "$STEPS/pr.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    AFTER=2222222222222222222222222222222222222222 \
    STUB_API_JSON='[{"number":7,"merged_at":null},{"number":42,"merged_at":"2026-01-01T00:00:00Z"}]' > /dev/null
  assert_eq "pr step: picks the merged PR" "42" "$(get_output "$of" pr_number)"
  assert_eq "pr step: continue" "true" "$(get_output "$of" continue)"

  of="$(new_output_file)"
  run_step "$WORK" "$STEPS/pr.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    AFTER=2222222222222222222222222222222222222222 \
    STUB_API_JSON='[]' > /dev/null
  assert_eq "pr step: no merged PR -> skip" "false" "$(get_output "$of" continue)"

  local labels_json='{"labels":[{"name":"cherry-pick-to-support/v6.13"},{"name":"bug"}]}'
  of="$(new_output_file)"
  out="$(run_step "$WORK" "$STEPS/label.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 LABEL_PREFIX=cherry-pick-to- TARGET_BRANCH=support/v6.1 \
    STUB_PR_JSON="$labels_json")"
  assert_eq "label step: near-miss label does not match" "false" "$(get_output "$of" continue)"
  assert_contains "label step: skip notice" "::notice::" "$out"

  labels_json='{"labels":[{"name":"cherry-pick-to-support/v6.1"},{"name":"bug"}]}'
  of="$(new_output_file)"
  run_step "$WORK" "$STEPS/label.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 LABEL_PREFIX=cherry-pick-to- TARGET_BRANCH=support/v6.1 \
    STUB_PR_JSON="$labels_json" > /dev/null
  assert_eq "label step: exact label matches" "true" "$(get_output "$of" continue)"
}

# ---------------------------------------------------------------------------
# Suite: setup step against fixture repositories
# ---------------------------------------------------------------------------

suite_setup() {
  echo "== setup step =="

  local d="$WORK/fix-setup" clone of out rc
  make_standard_fixture "$d"
  clone="$d/clone"

  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER" > /dev/null
  assert_eq "valid range: continue" "true" "$(get_output "$of" continue)"
  assert_eq "valid range: branch name" "cherry-pick/${FIX_AFTER:0:7}/support/v1.0" \
    "$(get_output "$of" cherry_pick_branch)"

  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" support/does-not-exist "$FIX_BASE" "$FIX_AFTER")"
  rc=$?
  assert_eq "missing target branch: exit code" "1" "$rc"
  assert_contains "missing target branch: error" "does not exist on origin" "$out"

  git -C "$clone" push -q origin "main:refs/heads/cherry-pick/${FIX_AFTER:0:7}/support/v1.0"
  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER")"
  assert_eq "pre-existing cherry-pick branch: skip" "false" "$(get_output "$of" continue)"
  assert_contains "pre-existing cherry-pick branch: notice" "already exists on origin" "$out"
  git -C "$clone" push -q origin ":refs/heads/cherry-pick/${FIX_AFTER:0:7}/support/v1.0"

  git -C "$clone" switch -qc side "$FIX_BASE"
  commit_file "$clone" side.txt "side" "side commit"
  local side_sha
  side_sha="$(git -C "$clone" rev-parse side)"
  git -C "$clone" switch -q main
  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" support/v1.0 "$side_sha" "$FIX_AFTER")"
  assert_eq "non-ancestor range (force push): skip" "false" "$(get_output "$of" continue)"
  assert_contains "non-ancestor range: notice" "not an ancestor" "$out"

  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" support/v1.0 \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$FIX_AFTER")"
  assert_eq "unknown commit in full clone: skip" "false" "$(get_output "$of" continue)"
  assert_contains "unknown commit: force-push notice" "not reachable anymore" "$out"

  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" support/v1.0 \
    "0000000000000000000000000000000000000000" "$FIX_AFTER")"
  assert_eq "new-branch push: skip" "false" "$(get_output "$of" continue)"

  local bad
  for bad in "-evil" "a..b" "a b" 'a[b]'; do
    of="$(new_output_file)"
    run_setup "$clone" "$of" "$bad" "$FIX_BASE" "$FIX_AFTER" > /dev/null
    assert_eq "invalid branch name '$bad': exit code" "1" "$?"
  done

  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 '$(evil)' "$FIX_AFTER" > /dev/null
  assert_eq "invalid SHA: exit code" "1" "$?"

  mkdir -p "$WORK/empty"
  of="$(new_output_file)"
  out="$(run_setup "$WORK/empty" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER")"
  rc=$?
  assert_eq "no repository: exit code" "1" "$rc"
  assert_contains "no repository: error" "No git repository found" "$out"
}

# ---------------------------------------------------------------------------
# Suite: full flow on fixture repositories
# ---------------------------------------------------------------------------

HOSTILE_TITLE='Fix `rm -rf` handling; $(touch PWNED) '"'"';--draft'

suite_flow_happy() {
  echo "== flow: successful cherry-pick =="

  local d="$WORK/fix-happy" clone of rc out state cpb
  make_standard_fixture "$d"
  clone="$d/clone"
  state="$(new_stub_state)"

  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER" > /dev/null
  cpb="$(get_output "$of" cherry_pick_branch)"

  run_step "$clone" "$STEPS/branch.sh" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH="$cpb" \
    INPUT_USER_NAME="" INPUT_USER_EMAIL="" \
    PUSHER_NAME="Push Er" PUSHER_EMAIL="pusher@example.com" > /dev/null
  assert_eq "branch step: on cherry-pick branch" "$cpb" \
    "$(git -C "$clone" rev-parse --abbrev-ref HEAD)"
  assert_eq "branch step: pusher identity" "Push Er" "$(git -C "$clone" config user.name)"

  run_step "$clone" "$STEPS/cherry-pick.sh" BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" > /dev/null
  assert_eq "cherry-pick step: exit code" "0" "$?"
  assert_eq "cherry-pick step: file content picked" "change 1" "$(cat "$clone/file.txt")"

  of="$(new_output_file)"
  run_step "$clone" "$STEPS/result.sh" GITHUB_OUTPUT="$of" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_OUTCOME=success > /dev/null
  assert_eq "result step: continue after real pick" "true" "$(get_output "$of" continue)"

  of="$(new_output_file)"
  run_step "$clone" "$STEPS/describe.sh" \
    PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH="$cpb" \
    BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" CHERRY_PICK_OUTCOME=success \
    SUCCESS_LABEL="Auto cherry-pick success" FAILURE_LABEL="Auto cherry-pick failure" \
    STUB_PR_JSON="{\"title\": \"$HOSTILE_TITLE\"}" > /dev/null
  assert_eq "describe step: hostile title passed through as data" \
    "[CP #42 > support/v1.0] $HOSTILE_TITLE" "$(get_block_output "$of" pr_title)"
  assert_contains "describe step: success body" "**successful**" "$(get_block_output "$of" pr_body)"
  assert_eq "describe step: success label" "Auto cherry-pick success" "$(get_block_output "$of" pr_label)"
  if [ -e "$clone/PWNED" ] || [ -e "PWNED" ]; then
    fail "describe step: hostile title executed a command"
  else
    pass "describe step: no injection side effects"
  fi

  run_step "$clone" "$STEPS/push.sh" CHERRY_PICK_BRANCH="$cpb" > /dev/null
  assert_eq "push step: exit code" "0" "$?"
  if git -C "$d/origin.git" rev-parse -q --verify "refs/heads/$cpb" > /dev/null; then
    pass "push step: branch exists on origin"
  else
    fail "push step: branch missing on origin"
  fi

  # A re-run of setup must now skip because the branch exists remotely.
  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER" > /dev/null
  assert_eq "setup re-run after push: skip" "false" "$(get_output "$of" continue)"
}

suite_flow_conflict() {
  echo "== flow: conflicting cherry-pick =="

  local d="$WORK/fix-conflict" clone of rc state cpb body
  make_conflict_fixture "$d"
  clone="$d/clone"
  state="$(new_stub_state)"

  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER" > /dev/null
  cpb="$(get_output "$of" cherry_pick_branch)"

  run_step "$clone" "$STEPS/branch.sh" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH="$cpb" \
    INPUT_USER_NAME="" INPUT_USER_EMAIL="" \
    PUSHER_NAME="Push Er" PUSHER_EMAIL="pusher@example.com" > /dev/null

  run_step "$clone" "$STEPS/cherry-pick.sh" BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" > /dev/null
  rc=$?
  if [ "$rc" -ne 0 ]; then pass "cherry-pick step: fails on conflict"; else fail "cherry-pick step: expected conflict failure"; fi

  of="$(new_output_file)"
  run_step "$clone" "$STEPS/result.sh" GITHUB_OUTPUT="$of" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_OUTCOME=failure > /dev/null
  assert_eq "result step: continue on failure" "true" "$(get_output "$of" continue)"

  of="$(new_output_file)"
  run_step "$clone" "$STEPS/describe.sh" \
    PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH="$cpb" \
    BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" CHERRY_PICK_OUTCOME=failure \
    SUCCESS_LABEL="ok" FAILURE_LABEL="Auto cherry-pick failure" \
    STUB_PR_JSON='{"title": "some feature"}' > /dev/null
  body="$(get_block_output "$of" pr_body)"
  assert_contains "describe step: conflict file listed" "file.txt" "$body"
  assert_contains "describe step: resolve instructions" "git cherry-pick $FIX_BASE..$FIX_AFTER" "$body"
  assert_eq "describe step: failure label" "Auto cherry-pick failure" "$(get_block_output "$of" pr_label)"

  run_step "$clone" "$STEPS/abort.sh" BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" > /dev/null
  assert_eq "abort step: exit code" "0" "$?"
  assert_contains "abort step: placeholder commit" "failed" \
    "$(git -C "$clone" log -1 --format=%s)"
  assert_eq "abort step: clean working tree" "" "$(git -C "$clone" status --porcelain)"

  run_step "$clone" "$STEPS/push.sh" CHERRY_PICK_BRANCH="$cpb" > /dev/null
  assert_eq "push step after conflict: exit code" "0" "$?"
}

suite_flow_dropped() {
  echo "== flow: all commits dropped =="

  local d="$WORK/fix-dropped" clone of out cpb
  make_dropped_fixture "$d"
  clone="$d/clone"

  of="$(new_output_file)"
  run_setup "$clone" "$of" support/v1.0 "$FIX_BASE" "$FIX_AFTER" > /dev/null
  cpb="$(get_output "$of" cherry_pick_branch)"

  run_step "$clone" "$STEPS/branch.sh" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH="$cpb" \
    INPUT_USER_NAME="" INPUT_USER_EMAIL="" \
    PUSHER_NAME="Push Er" PUSHER_EMAIL="pusher@example.com" > /dev/null

  run_step "$clone" "$STEPS/cherry-pick.sh" BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" > /dev/null
  assert_eq "cherry-pick step: succeeds by dropping" "0" "$?"

  of="$(new_output_file)"
  out="$(run_step "$clone" "$STEPS/result.sh" GITHUB_OUTPUT="$of" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_OUTCOME=success)"
  assert_eq "result step: skip when nothing picked" "false" "$(get_output "$of" continue)"
  assert_contains "result step: notice" "already exist" "$out"
}

# ---------------------------------------------------------------------------
# Suite: create-pr step (gh stub, no git needed)
# ---------------------------------------------------------------------------

run_create_pr() { # <state> <output-file> <summary-file> [KEY=VALUE ...]
  local state="$1" of="$2" summary="$3"
  shift 3
  run_step "$WORK" "$STEPS/create-pr.sh" \
    PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets \
    GITHUB_OUTPUT="$of" GITHUB_STEP_SUMMARY="$summary" \
    TARGET_BRANCH=support/v1.0 CHERRY_PICK_BRANCH=cherry-pick/abc1234/support/v1.0 \
    PR_TITLE="[CP #42 > support/v1.0] some feature" \
    PR_BODY="body" PR_LABEL="Auto label" \
    "$@"
}

suite_create_pr() {
  echo "== create-pr step =="

  local state of summary rc log

  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=success USE_DRAFT_PR=true > /dev/null
  rc=$?
  log="$(cat "$state/log")"
  assert_eq "success: exit code" "0" "$rc"
  assert_eq "success: pr_url output" "https://github.com/acme/widgets/pull/99" "$(get_output "$of" pr_url)"
  assert_eq "success: performed output" "true" "$(get_output "$of" performed)"
  assert_not_contains "success: no --draft" "--draft" "$log"
  assert_contains "success: green label color" "0e8a16" "$log"
  assert_contains "success: step summary written" "pull/99" "$(cat "$summary")"

  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=failure USE_DRAFT_PR=true > /dev/null
  log="$(cat "$state/log")"
  assert_contains "failure: --draft used" "--draft" "$log"
  assert_contains "failure: red label color" "d93f0b" "$log"

  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=failure USE_DRAFT_PR=false > /dev/null
  assert_not_contains "failure without draft input: no --draft" "--draft" "$(grep 'pr create' "$state/log")"

  # Label already exists: no create call.
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=success USE_DRAFT_PR=true \
    STUB_LABELS=$'Auto label\n' > /dev/null
  assert_not_contains "existing label: no label create" "label create" "$(cat "$state/log")"

  # Race: create fails, but a parallel job created the label in the meantime.
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=success USE_DRAFT_PR=true \
    STUB_LABEL_CREATE_RC=1 STUB_LABELS_SECOND=$'Auto label\n' > /dev/null
  assert_eq "label race: run still succeeds" "0" "$?"
  assert_eq "label race: PR created" "true" "$(get_output "$of" performed)"

  # Create fails and the label is really missing: hard error.
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_create_pr "$state" "$of" "$summary" CHERRY_PICK_OUTCOME=success USE_DRAFT_PR=true \
    STUB_LABEL_CREATE_RC=1 > /dev/null
  assert_eq "label create failure: exit code" "1" "$?"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  extract_steps
  make_stubs

  suite_syntax
  suite_check_token
  suite_create_pr

  if command -v jq > /dev/null; then
    suite_pr_label
  else
    skip_suite "pr/label step suite (jq not available)"
  fi

  if command -v git > /dev/null && command -v jq > /dev/null; then
    suite_setup
    suite_flow_happy
    suite_flow_conflict
    suite_flow_dropped
  else
    skip_suite "fixture suites (git and jq required)"
  fi

  echo
  echo "passed: $PASS, failed: $FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
