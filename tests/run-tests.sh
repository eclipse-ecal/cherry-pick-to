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
  for id in setup pr targets; do
    if ! python3 "$ROOT/tests/extract-step.py" "$ROOT/action.yml" "$id" > "$STEPS/$id.sh"; then
      echo "FATAL: could not extract step '$id' from action.yml" >&2
      exit 1
    fi
  done
}

run_step() { # <workdir> <script> [KEY=VALUE ...]; stdout+stderr combined
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

get_pr_arg() { # <state-dir> <flag>  (value of a flag in the last gh pr create)
  awk -v flag="$2" 'found { print; exit } $0 == flag { found = 1 }' "$1/pr_create_args"
}

assert_pr_flag() { # <description> <present|absent> <state-dir> <flag>
  # The flag must be its own argument (own line in the dump); a PR title
  # merely containing the flag text must not count.
  local found=absent
  if grep -Fxq -- "$4" "$3/pr_create_args"; then
    found=present
  fi
  if [ "$found" = "$2" ]; then
    pass "$1"
  else
    fail "$1 — flag '$4' $found in gh pr create args, expected $2"
  fi
}

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------

make_stubs() {
  # gh stub for scripts/check-token.sh, driven by STUB_MODE.
  mkdir -p "$WORK/bin-token"
  cat > "$WORK/bin-token/gh" <<'SH'
#!/bin/bash
# The write-access check probes `POST .../git/refs` with the all-zeros SHA;
# answer it from STUB_WRITE: "denied" -> 403, "error" -> inconclusive,
# default -> 422 (write access proven).
case "$*" in
  *git/refs*)
    case "${STUB_WRITE:-ok}" in
      denied) echo 'gh: Resource not accessible by integration (HTTP 403)' >&2 ;;
      error)  echo 'error connecting to api.github.com' >&2 ;;
      *)      echo 'gh: Validation Failed (HTTP 422)' >&2 ;;
    esac
    exit 1
    ;;
esac
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
    printf '%s\n' "$@" > "$STATE/pr_create_args"
    if [ "${STUB_PR_CREATE:-ok}" = "denied" ]; then
      echo 'pull request create failed: GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)' >&2
      exit 1
    fi
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

make_multi_fixture() { # standard fixture + conflicting branch support/v2.0
  make_standard_fixture "$1"
  local c="$1/clone"
  git -C "$c" switch -qc support/v2.0 "$FIX_BASE"
  commit_file "$c" file.txt "conflicting change on v2.0" "conflicting change"
  git -C "$c" push -q origin support/v2.0
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

run_setup() { # <workdir> <output-file> <before> <after>
  run_step "$1" "$STEPS/setup.sh" \
    INPUT_BEFORE="" INPUT_AFTER="" \
    EVENT_BEFORE="$3" EVENT_AFTER="$4" \
    GITHUB_OUTPUT="$2"
}

# shellcheck disable=SC2016 # deliberately NOT expanded: hostile input fixture
HOSTILE_TITLE='Fix `rm -rf` handling; $(touch PWNED) '"'"';--draft'
HOSTILE_TITLE_JSON="{\"title\": \"$HOSTILE_TITLE\"}"

run_targets() { # <clone> <state> <output-file> <summary-file> <targets> [KEY=VALUE ...]
  local clone="$1" state="$2" of="$3" summary="$4" targets="$5"
  shift 5
  run_step "$clone" "$ROOT/scripts/cherry-pick-targets.sh" \
    PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets \
    GITHUB_OUTPUT="$of" GITHUB_STEP_SUMMARY="$summary" \
    TARGETS="$targets" BEFORE="$FIX_BASE" AFTER="$FIX_AFTER" \
    PR_NUMBER=42 LABEL_PREFIX=cherry-pick-to- BRANCH_PREFIX=cherry-pick \
    SUCCESS_LABEL="Auto success" FAILURE_LABEL="Auto failure" \
    USE_DRAFT_PR=false ALLOWED_TARGET_BRANCHES="" \
    INPUT_USER_NAME="" INPUT_USER_EMAIL="" \
    PUSHER_NAME="Push Er" PUSHER_EMAIL="pusher@example.com" \
    STUB_PR_JSON="$HOSTILE_TITLE_JSON" \
    "$@"
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
expected = ["check-token", None, "setup", "pr", "targets", "run"]
assert ids == expected, f"unexpected step chain: {ids}"

checkout = steps[1]
assert checkout["uses"].startswith("actions/checkout@")
assert checkout["if"] == "inputs.checkout == 'true'"
assert checkout["with"]["fetch-depth"] == 0
assert checkout["with"]["token"] == "${{ inputs.token }}"

assert steps[3]["if"] == "steps.setup.outputs.continue == 'true'"    # pr
assert steps[4]["if"] == "steps.pr.outputs.continue == 'true'"       # targets
assert steps[5]["if"] == "steps.targets.outputs.continue == 'true'"  # run

inputs = doc["inputs"]
assert "target-branch" not in inputs, "target-branch input must be gone"
assert inputs["allowed-target-branches"]["default"] == ""
assert inputs["token"]["required"] is False
assert inputs["token"]["default"] == "${{ github.token }}"

for f in ["examples/cherry-pick-to.yml", "examples/quick-start.yml"]:
    text = open(f"{root}/{f}").read()
    assert "matrix" not in text, f"{f} must not use a matrix"
    assert "target-branch:" not in text, f"{f} must not configure target branches"
    assert "actions/checkout" not in text

qs = yaml.safe_load(open(f"{root}/examples/quick-start.yml"))
qs_job = next(iter(qs["jobs"].values()))
perms = qs_job["permissions"]
assert perms["contents"] == "write"
assert perms["pull-requests"] == "write"
assert perms["issues"] == "write"
qs_with = qs_job["steps"][-1].get("with") or {}
assert "token" not in qs_with, "quick-start must not pass a token"

print("all checks passed")
PY
  )"; then
    pass "YAML parses, scripts are valid bash, step wiring is correct"
  else
    fail "syntax/wiring: $out"
  fi

  local script
  for script in "$ROOT"/scripts/*.sh "$ROOT/tests/run-tests.sh"; do
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

  # Write-access probe (POST git/refs with all-zeros SHA): 403 = no write,
  # 422 = write access proven, anything else = inconclusive (no false alarm).
  run_check_token GH_TOKEN=ghs_test STUB_MODE=no-header STUB_WRITE=denied
  assert_eq "read-only GITHUB_TOKEN: exit code" "1" "$CT_RC"
  assert_contains "read-only GITHUB_TOKEN: permissions block advice" \
    "permissions: { contents: write" "$CT_OUT"
  assert_eq "read-only GITHUB_TOKEN: valid output" "false" "$(get_output "$CT_OUTPUTS" valid)"

  run_check_token GH_TOKEN=github_pat_test STUB_MODE=no-header STUB_WRITE=denied
  assert_eq "read-only PAT: exit code" "1" "$CT_RC"
  assert_contains "read-only PAT: Contents advice" "Contents (read/write)" "$CT_OUT"

  run_check_token STUB_MODE=no-header
  assert_eq "writable token (422 probe): exit code" "0" "$CT_RC"

  run_check_token STUB_MODE=no-header STUB_WRITE=error
  assert_eq "inconclusive probe: exit code" "0" "$CT_RC"
}

# ---------------------------------------------------------------------------
# Suite: pr + targets steps (gh stub with real jq)
# ---------------------------------------------------------------------------

suite_pr_targets() {
  echo "== pr and targets steps =="

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

  local labels_json='{"labels":[{"name":"cherry-pick-to-support/v6.1"},{"name":"bug"},{"name":"cherry-pick-to-foo"},{"name":"not-cherry-pick-to-bar"}]}'
  of="$(new_output_file)"
  run_step "$WORK" "$STEPS/targets.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 LABEL_PREFIX=cherry-pick-to- \
    STUB_PR_JSON="$labels_json" > /dev/null
  assert_eq "targets step: extracts all prefixed labels" \
    "support/v6.1
foo" "$(get_block_output "$of" targets)"
  assert_eq "targets step: continue" "true" "$(get_output "$of" continue)"

  labels_json='{"labels":[{"name":"bug"},{"name":"enhancement"}]}'
  of="$(new_output_file)"
  out="$(run_step "$WORK" "$STEPS/targets.sh" PATH="$WORK/bin-gh:$PATH" STUB_STATE="$state" \
    GH_TOKEN=dummy GITHUB_REPOSITORY=acme/widgets GITHUB_OUTPUT="$of" \
    PR_NUMBER=42 LABEL_PREFIX=cherry-pick-to- \
    STUB_PR_JSON="$labels_json")"
  assert_eq "targets step: no matching label -> skip" "false" "$(get_output "$of" continue)"
  assert_contains "targets step: skip notice" "::notice::" "$out"
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
  run_setup "$clone" "$of" "$FIX_BASE" "$FIX_AFTER" > /dev/null
  assert_eq "valid range: continue" "true" "$(get_output "$of" continue)"
  assert_eq "valid range: before output" "$FIX_BASE" "$(get_output "$of" before)"
  assert_eq "valid range: after output" "$FIX_AFTER" "$(get_output "$of" after)"

  git -C "$clone" switch -qc side "$FIX_BASE"
  commit_file "$clone" side.txt "side" "side commit"
  local side_sha
  side_sha="$(git -C "$clone" rev-parse side)"
  git -C "$clone" switch -q main
  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" "$side_sha" "$FIX_AFTER")"
  assert_eq "non-ancestor range (force push): skip" "false" "$(get_output "$of" continue)"
  assert_contains "non-ancestor range: notice" "not an ancestor" "$out"

  of="$(new_output_file)"
  out="$(run_setup "$clone" "$of" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$FIX_AFTER")"
  assert_eq "unknown commit in full clone: skip" "false" "$(get_output "$of" continue)"
  assert_contains "unknown commit: force-push notice" "not reachable anymore" "$out"

  of="$(new_output_file)"
  run_setup "$clone" "$of" "0000000000000000000000000000000000000000" "$FIX_AFTER" > /dev/null
  assert_eq "new-branch push: skip" "false" "$(get_output "$of" continue)"

  of="$(new_output_file)"
  # shellcheck disable=SC2016 # deliberately NOT expanded: hostile input fixture
  run_setup "$clone" "$of" '$(evil)' "$FIX_AFTER" > /dev/null
  assert_eq "invalid SHA: exit code" "1" "$?"

  mkdir -p "$WORK/empty"
  of="$(new_output_file)"
  out="$(run_setup "$WORK/empty" "$of" "$FIX_BASE" "$FIX_AFTER")"
  rc=$?
  assert_eq "no repository: exit code" "1" "$rc"
  assert_contains "no repository: error" "No git repository found" "$out"
}

# ---------------------------------------------------------------------------
# Suite: scripts/cherry-pick-targets.sh against fixture repositories
# ---------------------------------------------------------------------------

suite_cherry_pick_targets() {
  echo "== cherry-pick-targets.sh =="

  local d clone state of summary out rc cpb short

  # --- single clean target ---
  d="$WORK/fix-happy"
  make_standard_fixture "$d"
  clone="$d/clone"
  short="${FIX_AFTER:0:7}"
  cpb="cherry-pick/$short/support/v1.0"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$clone" "$state" "$of" "$summary" $'support/v1.0\n')"
  rc=$?
  assert_eq "happy: exit code" "0" "$rc"
  assert_eq "happy: performed" "true" "$(get_output "$of" performed)"
  assert_contains "happy: pr-urls" "pull/99" "$(get_block_output "$of" pr-urls)"
  assert_contains "happy: results JSON" \
    '{"target":"support/v1.0","outcome":"success","pr-url":"https://github.com/acme/widgets/pull/99"}' \
    "$(get_output "$of" results)"
  if git -C "$d/origin.git" rev-parse -q --verify "refs/heads/$cpb" > /dev/null; then
    pass "happy: branch pushed to origin"
  else
    fail "happy: branch missing on origin"
  fi
  assert_eq "happy: picked file content" "change 1" \
    "$(git -C "$d/origin.git" show "refs/heads/$cpb:file.txt" | tr -d '\n')"
  assert_eq "happy: hostile title as one argument" \
    "[CP #42 > support/v1.0] $HOSTILE_TITLE" "$(get_pr_arg "$state" --title)"
  assert_pr_flag "happy: no --draft" absent "$state" --draft
  assert_contains "happy: green label color" "0e8a16" "$(cat "$state/log")"
  assert_contains "happy: summary line" "support/v1.0" "$(cat "$summary")"
  if [ -e "$clone/PWNED" ] || [ -e "PWNED" ]; then
    fail "happy: hostile title executed a command"
  else
    pass "happy: no injection side effects"
  fi

  # --- re-run on the same fixture: remote branch exists -> skip ---
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$clone" "$state" "$of" "$summary" $'support/v1.0\n')"
  rc=$?
  assert_eq "re-run: exit code" "0" "$rc"
  assert_eq "re-run: performed" "false" "$(get_output "$of" performed)"
  assert_contains "re-run: skipped outcome" '"outcome":"skipped-branch-exists"' "$(get_output "$of" results)"

  # --- conflicting target, draft on ---
  d="$WORK/fix-conflict"
  make_conflict_fixture "$d"
  clone="$d/clone"
  short="${FIX_AFTER:0:7}"
  cpb="cherry-pick/$short/support/v1.0"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$clone" "$state" "$of" "$summary" $'support/v1.0\n' USE_DRAFT_PR=true)"
  rc=$?
  assert_eq "conflict: exit code" "0" "$rc"
  assert_contains "conflict: outcome" '"outcome":"conflict"' "$(get_output "$of" results)"
  assert_pr_flag "conflict: --draft used" present "$state" --draft
  assert_contains "conflict: red label color" "d93f0b" "$(cat "$state/log")"
  assert_contains "conflict: conflicting file listed" "file.txt" "$(cat "$state/pr_create_args")"
  assert_contains "conflict: placeholder commit" "failed" \
    "$(git -C "$d/origin.git" log -1 --format=%s "refs/heads/$cpb")"
  assert_eq "conflict: clean working tree afterwards" "" "$(git -C "$clone" status --porcelain)"

  # --- conflicting target, draft off (default) ---
  d="$WORK/fix-conflict2"
  make_conflict_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_targets "$d/clone" "$state" "$of" "$summary" $'support/v1.0\n' > /dev/null
  assert_pr_flag "conflict without draft: no --draft" absent "$state" --draft

  # --- all commits dropped (needs git >= 2.45 for cherry-pick --empty) ---
  # `git <cmd> -h` exits 129 even on success; grep the captured text.
  if grep -q -- '--empty' <<< "$(git cherry-pick -h 2>&1 || true)"; then
    d="$WORK/fix-dropped"
    make_dropped_fixture "$d"
    state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
    out="$(run_targets "$d/clone" "$state" "$of" "$summary" $'support/v1.0\n')"
    rc=$?
    assert_eq "dropped: exit code" "0" "$rc"
    assert_eq "dropped: performed" "false" "$(get_output "$of" performed)"
    assert_contains "dropped: outcome" '"outcome":"skipped-nothing-to-pick"' "$(get_output "$of" results)"
    assert_not_contains "dropped: no PR created" "pr create" "$(cat "$state/log")"
  else
    skip_suite "dropped-commits scenario (git >= 2.45 required)"
  fi

  # --- multiple targets: clean + conflict + missing branch ---
  d="$WORK/fix-multi"
  make_multi_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$d/clone" "$state" "$of" "$summary" \
    $'support/v1.0\nsupport/v2.0\nsupport/nope\n')"
  rc=$?
  assert_eq "multi: exit code (hard error present)" "1" "$rc"
  local results
  results="$(get_output "$of" results)"
  assert_contains "multi: v1.0 success" '{"target":"support/v1.0","outcome":"success"' "$results"
  assert_contains "multi: v2.0 conflict" '{"target":"support/v2.0","outcome":"conflict"' "$results"
  assert_contains "multi: nope error" '{"target":"support/nope","outcome":"error"' "$results"
  assert_eq "multi: two PRs created" "2" "$(grep -c 'pr create' "$state/log")"
  assert_eq "multi: performed" "true" "$(get_output "$of" performed)"
  assert_eq "multi: two pr-urls" "2" "$(get_block_output "$of" pr-urls | grep -c 'pull/99')"
  assert_contains "multi: missing-branch error message" "does not exist on origin" "$out"

  # --- invalid label suffix does not stop a valid target ---
  d="$WORK/fix-invalid"
  make_standard_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$d/clone" "$state" "$of" "$summary" $'-evil\nsupport/v1.0\n')"
  rc=$?
  assert_eq "invalid target: exit code" "1" "$rc"
  assert_contains "invalid target: error outcome" '{"target":"-evil","outcome":"error"' "$(get_output "$of" results)"
  assert_contains "invalid target: valid target still succeeds" \
    '{"target":"support/v1.0","outcome":"success"' "$(get_output "$of" results)"

  # --- allowed-target-branches filter ---
  d="$WORK/fix-allowed"
  make_standard_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$d/clone" "$state" "$of" "$summary" $'foo\nsupport/v1.0\n' \
    ALLOWED_TARGET_BRANCHES='support/*')"
  rc=$?
  assert_eq "allowlist: exit code" "0" "$rc"
  assert_contains "allowlist: foo filtered" '{"target":"foo","outcome":"skipped-not-allowed"' "$(get_output "$of" results)"
  assert_contains "allowlist: support allowed" '{"target":"support/v1.0","outcome":"success"' "$(get_output "$of" results)"

  # --- PR creation blocked by the repository's Actions settings ---
  d="$WORK/fix-pr-denied"
  make_standard_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  out="$(run_targets "$d/clone" "$state" "$of" "$summary" $'support/v1.0\n' STUB_PR_CREATE=denied)"
  rc=$?
  assert_eq "pr-create denied: exit code" "1" "$rc"
  assert_contains "pr-create denied: settings hint" \
    "Allow GitHub Actions to create and approve pull requests" "$out"
  assert_contains "pr-create denied: error outcome" '"outcome":"error"' "$(get_output "$of" results)"

  # --- label-creation race: create fails but label appears on re-list ---
  d="$WORK/fix-race"
  make_standard_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_targets "$d/clone" "$state" "$of" "$summary" $'support/v1.0\n' \
    STUB_LABEL_CREATE_RC=1 STUB_LABELS_SECOND=$'Auto success\n' > /dev/null
  assert_eq "label race: exit code" "0" "$?"
  assert_contains "label race: PR still created" '"outcome":"success"' "$(get_output "$of" results)"

  # --- label creation fails for real ---
  d="$WORK/fix-race2"
  make_standard_fixture "$d"
  state="$(new_stub_state)"; of="$(new_output_file)"; summary="$(new_output_file)"
  run_targets "$d/clone" "$state" "$of" "$summary" $'support/v1.0\n' \
    STUB_LABEL_CREATE_RC=1 > /dev/null
  assert_eq "label failure: exit code" "1" "$?"
  assert_contains "label failure: error outcome" '"outcome":"error"' "$(get_output "$of" results)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  extract_steps
  make_stubs

  suite_syntax
  suite_check_token

  if command -v jq > /dev/null; then
    suite_pr_targets
  else
    skip_suite "pr/targets step suite (jq not available)"
  fi

  if command -v git > /dev/null && command -v jq > /dev/null; then
    suite_setup
    suite_cherry_pick_targets
  else
    skip_suite "fixture suites (git and jq required)"
  fi

  echo
  echo "passed: $PASS, failed: $FAIL"
  [ "$FAIL" -eq 0 ]
}

main "$@"
