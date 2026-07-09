# Cherry Pick To

A reusable GitHub Action that automatically cherry-picks merged pull requests
onto release / support branches, driven by labels on the pull request.

**Why this action?**

- **No target-branch configuration**: any label of the form
  `cherry-pick-to-<branch>` works out of the box — the action discovers the
  target branches from the merged PR's labels at run time. No whitelist to
  maintain when a new release branch is created.
- **A pull request is always created** once a labeled PR is merged. If the
  cherry-pick succeeds, the PR is ready to review and merge; if it fails on
  conflicts, a PR (optionally a draft) is created anyway, listing the conflicting files
  and copy-paste instructions for resolving them manually on that same
  branch. Nothing is ever silently dropped.
- **Works with squash merges and rebase merges alike**: the whole pushed
  commit range is cherry-picked, whether that is one squashed commit or many
  commits from a rebase merge.
- **CI can run on the created PRs**: pass a fine-grained PAT and the
  cherry-pick PRs trigger your workflows like any human-created PR. (The
  zero-setup default `GITHUB_TOKEN` works too, but cannot trigger workflows —
  see [Token](#token).)
- **Meaningful token diagnostics**: expired, misconfigured, or read-only
  tokens fail with an actionable error before anything else happens, and the
  action warns ahead of time when a PAT is about to expire.

## How it works

1. A pull request gets one or more labels of the form
   `cherry-pick-to-<target-branch>` (e.g. `cherry-pick-to-support/v6.1`)
   **before it is merged**.
2. When the PR is merged and its commits are pushed to the main branch, the
   consuming workflow runs once.
3. The action looks up the merged PR the pushed commits belong to and derives
   the target branches from its `cherry-pick-to-*` labels — no pre-configured
   branch list needed.
4. For each target branch (sequentially), the action:
   - cherry-picks the pushed commit range onto a new branch
     `cherry-pick/<short-sha>/<target-branch>` created from the target branch,
   - opens a pull request against the target branch.

   A hard failure on one target (e.g. the branch does not exist) does not
   stop the remaining targets; the run fails at the end if any target had a
   hard error.

If the cherry-pick succeeds, the PR contains the cherry-picked commits and is
labeled with the success label. If it fails (conflicts), the cherry-pick is
aborted, the PR is created (optionally as a draft) with an empty placeholder
commit, labeled with the failure label, and its description lists the
conflicting files together with copy-paste instructions for resolving the
conflicts manually on the same branch.

**Forgot to add the label before merging?** The action runs on the push
created by the merge, so adding a label afterwards does not trigger it again.
However, the labels are read live when the action runs — so you can add the
label after the fact and simply **re-run the merge commit's workflow run**
from the *Actions* tab; the re-run will then pick the label up.

## Usage

Create a workflow in the consuming repository, e.g.
`.github/workflows/cherry-pick-to.yml` (see [`examples/`](examples/) for the
full file):

```yaml
name: Cherry-pick to release branches

on:
  push:
    branches: [ "main" ]

jobs:
  cherry-pick:
    runs-on: ubuntu-latest
    permissions:
      contents: write        # push the cherry-pick branches
      pull-requests: write   # create the pull requests
      issues: write          # create the success/failure labels

    steps:
      - name: Cherry-pick to labeled target branches
        uses: eclipse-ecal/cherry-pick-to@v1
```

This runs with the workflow's default `GITHUB_TOKEN` — no secret setup
needed, but it requires a one-time repository setting and **CI will not run
on the created cherry-pick PRs** (see [Token](#token)). For production use,
pass a fine-grained PAT instead:
`token: ${{ secrets.CHERRY_PICK_GITHUB_TOKEN }}` (the `permissions` block and
the repository setting are then not needed).

The action verifies the token (see
[Token expiry checking](#token-expiry-checking)) and then checks out the
repository itself with full history (`fetch-depth: 0`) and the given token —
no separate `actions/checkout` step is needed. If your workflow has to manage
the checkout itself, set `checkout: 'false'` and check out with the same
token and `fetch-depth: 0` before calling the action.

## Token

### Quick start: the default `GITHUB_TOKEN`

Without a `token` input, the action uses the workflow's `GITHUB_TOKEN`. No
secret or PAT setup is needed — only the `permissions` block shown in
[Usage](#usage) (the default workflow token is read-only) and a **one-time
repository setting**: under *Settings → Actions → General → Workflow
permissions*, enable **"Allow GitHub Actions to create and approve pull
requests"**. Creating pull requests is gated by that checkbox and *cannot*
be granted by the workflow's `permissions` block. For repositories that
belong to an organization, the checkbox may be greyed out until the same
setting is enabled in the organization settings. This is the easiest way to
try the action out, and fine for repositories that don't need CI on the
cherry-pick PRs.

**Limitation:** commits and pull requests created with `GITHUB_TOKEN` cannot
trigger other workflows, so **CI will not run on the created cherry-pick
PRs**. If branch protection requires status checks, such a PR waits for them
forever. To run CI on one anyway, close and re-open the PR (or push a commit
to it) — actions performed by a human do trigger workflows. The action prints
a notice on every run with the default token as a reminder.

### Production: a fine-grained PAT

To get CI on the cherry-pick PRs, create a **fine-grained personal access
token** (typically owned by a machine user), store it as a repository or
organization secret (e.g. `CHERRY_PICK_GITHUB_TOKEN`), and pass it via the
`token` input.

Required token permissions on the consuming repository:

| Permission    | Access         |
|---------------|----------------|
| Actions       | Read and write |
| Contents      | Read and write |
| Metadata      | Read-only      |
| Pull requests | Read and write |
| Workflows     | Read and write |

Fine-grained PATs expire and must be renewed. The action checks the token
before doing anything else, so an expired token fails the run with a clear
error message — see [Token expiry checking](#token-expiry-checking).

## Token expiry checking

The very first step of the action verifies the token against the repository,
**before** the repository is checked out:

- **Token invalid or expired** → the run fails with a meaningful error
  ("The cherry-pick token is invalid or has expired (HTTP 401). Renew the
  fine-grained PAT and update the secret ..."), instead of the cryptic
  failure an expired token otherwise produces in `actions/checkout`:

  ```
  fatal: could not read Username for 'https://github.com': terminal prompts disabled
  ```

- **Token valid but lacking access/permissions** → the run fails with a
  message listing the required permissions.

- **Token valid but expiring soon** → the run continues normally and emits a
  workflow **warning** when the token expires within
  `token-expiry-warning-days` (default: 14) days, so upcoming expiry shows up
  on every push while everything still works. (GitHub reports the expiration
  date of an expiring token in the `github-authentication-token-expiration`
  header of every API response; fine-grained PATs always have one.)

- **Token lacking write access** (e.g. a read-only default `GITHUB_TOKEN`
  without the `permissions` block) → the run fails immediately with the fix,
  instead of much later at the push step.

With the default `GITHUB_TOKEN` — which is ephemeral by design — the expiry
check is skipped; instead, a notice about the CI-trigger limitation is
printed on every run.

Use the `error-hint` input to append e.g. a link to your renewal runbook or
helpdesk ticket to these messages.

### Checking without the main action

The same check is available as a standalone sub-action. It needs no checkout
and is useful in two situations:

- **You set `checkout: 'false'`** and manage the checkout yourself: your
  checkout step then runs before the action's token check, so place the
  sub-action *before* your checkout step to keep the friendly error.
- **Scheduled checks** independent of push activity (see below).

```yaml
- name: Check cherry-pick token
  uses: eclipse-ecal/cherry-pick-to/check-token@v1
  with:
    token: ${{ secrets.CHERRY_PICK_GITHUB_TOKEN }}
    # warning-days: '14'
    # error-hint: 'Renewal runbook: https://example.com/renew-cherry-pick-token'
```

Inputs: `token` (required), `warning-days` (default `14`), `error-hint`
(optional text appended to error/warning messages). Outputs:
`expiration-date`, `days-until-expiration`.

Warnings on push-triggered runs only appear when someone pushes. For advance
notice that does not depend on push activity, add a small scheduled workflow:

```yaml
name: Check cherry-pick token

on:
  schedule:
    - cron: '0 6 * * 1'   # every Monday, 06:00 UTC
  workflow_dispatch:

jobs:
  check-token:
    runs-on: ubuntu-latest
    steps:
      - uses: eclipse-ecal/cherry-pick-to/check-token@v1
        with:
          token: ${{ secrets.CHERRY_PICK_GITHUB_TOKEN }}
          warning-days: '30'
```

Once the token has expired, this scheduled run fails — and GitHub notifies
the author of a workflow when its scheduled runs fail.

## Inputs

| Input            | Required | Default                       | Description |
|------------------|----------|-------------------------------|-------------|
| `token`          | no       | `${{ github.token }}`         | Token for checkout, pushing, and the GitHub CLI calls. The default `GITHUB_TOKEN` works but its PRs trigger no CI; use a fine-grained PAT for production (see [Token](#token)). |
| `label-prefix`   | no       | `cherry-pick-to-`             | Labels of the form `<label-prefix><branch>` on the source PR select the target branches. |
| `allowed-target-branches` | no | `''`                       | Optional space-separated glob patterns (e.g. `support/* release/*`) restricting which branches may be targeted via labels. Empty allows any branch. |
| `success-label`  | no       | `Auto cherry-pick success ✅` | Label put on a created PR when the cherry-pick succeeded. Created (green) if missing. |
| `failure-label`  | no       | `Auto cherry-pick failure ⚠️` | Label put on a created PR when the cherry-pick failed. Created (red) if missing. |
| `use-draft-pr`   | no       | `false`                       | Create failed-cherry-pick PRs as drafts. Off by default because repositories without draft PR support (e.g. private repos on free plans) would fail to create the PR. |
| `branch-prefix`  | no       | `cherry-pick`                 | Each created branch is named `<branch-prefix>/<short-sha>/<target-branch>`. |
| `before-commit`  | no       | `github.event.before`         | Start (exclusive) of the commit range to cherry-pick, as a full 40-char SHA. |
| `after-commit`   | no       | `github.event.after`          | End (inclusive) of the commit range to cherry-pick, as a full 40-char SHA. |
| `git-user-name`  | no       | pusher of the push event      | `user.name` for the cherry-picked commits. |
| `git-user-email` | no       | pusher of the push event      | `user.email` for the cherry-picked commits. |
| `checkout`       | no       | `true`                        | Whether the action checks out the repository itself (full history, using `token`). Set to `false` to manage the checkout in the calling workflow. |
| `token-expiry-warning-days` | no | `14`                     | Emit a workflow warning when the token expires within this many days. |
| `error-hint`     | no       | `''`                          | Extra text appended to token error/warning messages, e.g. a link to your renewal runbook. |

## Outputs

| Output                | Description |
|-----------------------|-------------|
| `performed`           | `true` if at least one cherry-pick PR was created. |
| `pr-urls`             | Newline-separated URLs of the created cherry-pick PRs. Empty if none. |
| `results`             | JSON array with one entry per discovered target branch: `[{"target": "...", "outcome": "...", "pr-url": "..."}]`. Outcomes: `success`, `conflict`, `skipped-branch-exists`, `skipped-nothing-to-pick`, `skipped-not-allowed`, `error`. |
| `source-pr-number`    | Number of the merged PR the pushed commits belong to. Empty if none was found. |
| `token-expiration-date` | Expiration date of the token. Empty if the token does not expire. |

Note: the *action* succeeds even when a *cherry-pick* fails with conflicts —
that case is reported through the failure-labeled PR (`conflict` outcome),
not through a red workflow run. The action only fails on real errors
(invalid inputs, missing target branch, API failures, push failures, ...),
and even then only after all other targets have been processed.

## Behavior notes

- The action expects **squash-merge or rebase-merge** workflows. Merge
  commits inside the pushed range make `git cherry-pick` fail and land on the
  failure path (conflict-style PR).
- Pushes without an associated merged PR (e.g. direct pushes) and PRs without
  a matching label are skipped silently (a notice is written to the log).
- Pushes that create a branch (`before` is all zeros) and force pushes
  (`before` no longer reachable, or not an ancestor of `after`) are skipped
  with a notice.
- If a cherry-pick branch already exists on the remote — a re-run for the
  same commits, or someone is already resolving conflicts on it — that target
  is skipped with a notice. Delete the branch to re-run the cherry-pick.
- Commits whose changes already exist on the target branch are silently
  dropped (`git cherry-pick --empty=drop`). If *all* commits are dropped, no
  pull request is created for that target.
- Targets are processed **sequentially**; a hard error on one target does not
  stop the others (the run fails at the end instead).
- Every target reports its result on the workflow run's summary page.

## Security

All externally controlled values (branch names, PR titles, labels, pusher
name/email, conflicting file names) are passed into the shell scripts as
environment variables and only used as quoted variables — they are never
interpolated into script text, so they cannot inject shell commands
([GitHub docs on script injection](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections)).
Branch names are additionally validated with `git check-ref-format` and may
not start with `-`; commit SHAs must match `^[0-9a-f]{40}$`.

Since the target branches come from labels, **anyone who can label pull
requests (triage permission and up) can direct cherry-picks at any branch**.
The result is always a pull request — nothing is merged automatically — but
if you want to bound this, set `allowed-target-branches` (e.g. `support/*`)
to restrict which branches labels may target.

## Development

`tests/run-tests.sh` tests the step scripts against local fixture
repositories and a stubbed `gh` CLI — no GitHub access needed (requires
`git`, `jq`, and `python3` with PyYAML). CI runs the tests plus `shellcheck`
and `actionlint` on every push and pull request.

## License

[MIT](LICENSE)
