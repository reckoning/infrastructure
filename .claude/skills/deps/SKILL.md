---
name: deps
description: Triages the open Dependabot PR queue — classifies each provider bump, checks CI and the terraform plan, merges the safe ones and reports what needs a human decision
---

# Deps Skill

Works through the open Dependabot pull requests on `reckoning/infrastructure`. Merges patch and minor provider bumps whose CI is green **and whose plan is clean**, and stops with a recommendation for everything else.

## When to Use

- "triage the deps", "deal with the dependabot PRs", "merge the safe provider updates"
- Dependabot runs **weekly** (`terraform` and `github-actions`, default limit of 5 each), so the queue is small — often empty.

## Read this first — merging here applies infrastructure

This is not a library repo. A merge to `main` runs `Main`, and a successful `Main` triggers `Deploy`, whose `stage` job runs:

```
terraform init → terraform plan -out=tfplan → terraform apply tfplan
```

The `Stage` environment has **no protection rules**, so that apply is unattended. Merging a Dependabot PR here changes real infrastructure within minutes.

`Live` is safer: `live-plan` and `live-apply` only run on `workflow_dispatch` with `target: live`, so production is never touched by a merge.

The practical consequence: **a green CI check is not sufficient evidence that a bump is safe.** CI runs `terraform init -backend=false`, `validate`, and `test` — it never runs `plan` against real state. A provider bump that changes a resource's default, deprecates an attribute, or alters how an existing resource is read will pass `validate` and then show up as a change (or a replacement) in the Stage apply. Gate C exists for exactly this.

## Repo facts

- Ecosystems: `terraform` and `github-actions`. No `labels:` block in `.github/dependabot.yml`, so Dependabot applies its defaults: `dependencies` plus `terraform` or **`github_actions`** (underscore).
- Providers in use: `hetznercloud/hcloud`, `hashicorp/aws`, `hashicorp/cloudinit`, `1Password/onepassword`. The 1Password provider is what makes local plans need `OP_SERVICE_ACCOUNT_TOKEN`.
- Constraints in `versions.tf` are **floors** (`version = ">= 1.60"`), not upper bounds. Dependabot therefore bumps the locked version in `.terraform.lock.hcl` and usually leaves `versions.tf` untouched.
- **Squash, merge commit, and rebase are all allowed.** Branches are **not** deleted on merge. Prefer squash for consistency with the other repos.
- `main` is protected by the **"Main branch protection" ruleset** — the classic `branches/main/protection` API returns 404 here, which means "no *classic* protection", not "unprotected". One required check, `terraform_test`, plus a **merge queue**.
- Auto-merge is **disabled**, so `--auto` is not available.

---

## Workflow

### 1. Pull the queue

```bash
gh pr list --repo reckoning/infrastructure --label dependencies --limit 50 \
  --json number,title,mergeStateStatus \
  --jq '.[] | "\(.number)\t\(.mergeStateStatus)\t\(.title)"'
```

If the queue is empty, say so and stop.

### 2. Classify each PR

Parse `bump <provider> from <old> to <new>` out of the title, then apply the usual rules — major if the major component changed, and a changed minor on a `0.x` provider is also a major.

**Read the version out of the diff, not the title.** Dependabot rewrites the branch as new releases land, but the title can lag behind what the diff actually does:

```bash
gh pr diff <number> --repo reckoning/infrastructure | grep -E '^[-+]  version'
```

### 3. Run the safety gates

#### Gate A — bump class is patch or minor

Provider majors always go to the report. Terraform providers use the major version to signal breaking schema changes, and the blast radius is live infrastructure.

#### Gate B — CI is green

```bash
gh pr view <number> --repo reckoning/infrastructure \
  --json statusCheckRollup \
  --jq '[.statusCheckRollup[] | select(.conclusion != "SUCCESS" and .conclusion != "SKIPPED" and .conclusion != "NEUTRAL")] | map("\(.name): \(.conclusion // .status)") | .[]'
```

Empty output means green. Remember what `terraform_test` does and does not cover — see the warning above.

#### Gate C — the plan is clean

The gate that matters most in this repo. Run a plan locally against **every** PR branch — patch bumps included — and confirm it is a no-op. There is no bump small enough to skip this; a patch release is exactly where a silently changed default shows up.

Setup has to be verified before the plan runs, not assumed. A `plan` whose checkout or workspace selection silently failed reports on the *previous* branch and workspace — and a `No changes.` from the wrong workspace (or, worse, from `live`) looks exactly like a passing gate. Abort on any setup failure and assert the state you expect:

```bash
set -euo pipefail
gh pr checkout <number> --repo reckoning/infrastructure
terraform init
terraform workspace select stage

branch=$(gh pr view <number> --repo reckoning/infrastructure --json headRefName --jq .headRefName)
[ "$(git rev-parse --abbrev-ref HEAD)" = "$branch" ] || { echo "HALT: not on $branch"; exit 1; }
[ "$(terraform workspace show)" = "stage" ] || { echo "HALT: workspace is $(terraform workspace show)"; exit 1; }

echo "PLANNED SHA: $(git rev-parse HEAD)"
terraform plan
```

`set -euo pipefail` is what stops a failed `terraform init` or `workspace select` from falling through to the plan, and the two assertions catch the case where a command "succeeded" but left the tree somewhere unexpected. `gh pr checkout` fails on a dirty working tree — commit or stash first rather than working around it. If either `HALT` fires, the PR is unverified, not clean.

**Copy the printed `PLANNED SHA` into your notes and paste it literally into the merge in step 4.** Do not put it in a shell variable and expect it to survive: each command you run is a fresh shell, so a `$planned_sha` set here expands to empty later — and `--match-head-commit ""` disables the guard without complaining. A literal 40-character SHA on the merge command line is the only form that actually binds.

This matters because a clean plan is evidence about one commit, not about the PR. Dependabot force-pushes the branch whenever a newer release lands — the same behavior that makes the title unreliable in step 2 — so the head can move between Gate C and step 4, and the merge would then apply a provider revision that was never planned.

- `No changes.` → gate passes, safe to merge.
- **Anything else — any `+`, `~`, `-`, or `-/+`** → gate fails. Do not merge. Report the plan output with the resource addresses and let the user decide. Note that `~` in-place changes are not automatically benign: a re-read attribute and a destructive rewrite look the same at this level of summary, and `must be replaced` is only the most obvious case. This is the failure mode a green `terraform_test` will not catch.

A failed Gate C can only be cleared by the user explicitly saying to merge that PR. "Plan showed only additions, so I merged it" is never correct.

If you cannot run a plan (missing credentials — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `OP_SERVICE_ACCOUNT_TOKEN` are needed for the S3 backend and the 1Password provider), **say so explicitly in the report** and mark the PR as unverified rather than merging it on CI alone.

Also check whether the PR touches `versions.tf`. It normally should not — a change to a `required_providers` constraint is Dependabot raising a floor, and is worth reading:

```bash
gh pr diff <number> --repo reckoning/infrastructure --name-only
```

#### Gate D — mergeable state

`BEHIND` needs a rebase — `@dependabot rebase`. `DIRTY` → `@dependabot recreate`. Lockfile conflicts are common when two provider PRs are open at once, since they all edit `.terraform.lock.hcl`. `UNKNOWN` → re-poll.

### 4. Merge the safe ones

Merge the exact commit Gate C planned, never just "the PR":

```bash
gh pr merge <number> --repo reckoning/infrastructure --squash \
  --match-head-commit 3f9a1c04e2b7d8615a0f4c93b2e7d1a8c6045f9e   # the PLANNED SHA, pasted literally
```

`--match-head-commit` makes the merge fail rather than silently enqueue a newer head. If it rejects, Dependabot rewrote the branch after your plan: **re-run Gate C against the new head** and only merge once that plan is clean too. Never drop the flag to get past a rejection — that converts a caught race into an unplanned Stage apply.

If you no longer have the SHA Gate C printed, you do not have a valid plan for this PR. Re-run Gate C; do not merge from memory of "it was clean earlier".

`main` has a merge queue, so this enqueues rather than merging on the spot.

**Merge one at a time, and block until that bump's Stage apply has actually succeeded before merging the next.** This means waiting through three hops — merge queue → `Main` → `Deploy` — not glancing at a run list.

First wait for the queue to land the merge and capture the resulting commit:

```bash
until [ "$(gh pr view <number> --repo reckoning/infrastructure --json state --jq .state)" != "OPEN" ]; do sleep 30; done
gh pr view <number> --repo reckoning/infrastructure --json state,mergeCommit \
  --jq '"\(.state) \(.mergeCommit.oid // "none")"'
```

If the state came back `CLOSED` rather than `MERGED`, the queue ejected the PR — usually a lockfile conflict. Report it and move on; there is no deploy to wait for.

With the merge commit SHA, wait on `Main` and then on `Deploy`, both filtered to that SHA so you are never watching a run from someone else's push. `Deploy` is triggered by `workflow_run`, so it does not exist until `Main` finishes — poll for it:

```bash
SHA=<mergeCommit.oid>
for wf in Main Deploy; do
  until id=$(gh run list --repo reckoning/infrastructure --workflow "$wf" -c "$SHA" \
               --limit 1 --json databaseId --jq '.[0].databaseId // empty'); [ -n "$id" ]; do sleep 20; done
  if ! gh run watch "$id" --repo reckoning/infrastructure --exit-status; then
    echo "HALT: $wf failed for $SHA"
    gh run view "$id" --repo reckoning/infrastructure --log-failed
    exit 1
  fi
done
echo "OK: Stage apply succeeded for $SHA"
```

The `exit 1` matters — it is what makes the failure visible instead of falling out of a loop quietly. **A non-zero exit here ends the entire triage, not just the wait:** stop, report the failed run, and merge nothing else until the user has resolved it. Do not proceed to the next PR, and do not treat a failed `Main` as "Deploy never ran, so nothing was applied" — read the log before concluding anything.

Only the final `OK:` line confirms the Stage apply went through. If you did not see it, the bump is unverified against real state and the next merge stays blocked.

Every open PR edits `.terraform.lock.hcl`, so each merge conflicts the rest — post `@dependabot recreate` on the remainder afterwards.

Branches are not auto-deleted:

```bash
gh api -X DELETE repos/reckoning/infrastructure/git/refs/heads/<headRefName>
```

### 5. Report

```
Merged — Stage apply succeeded (N)
  #12  minor  terraform  hetznercloud/hcloud 1.63.0 → 1.68.0 — plan clean, Deploy green

Held — needs a decision (N)
  #13  major  terraform  hashicorp/aws 5.x → 6.0.0
       Provider major — read the upgrade guide before planning.
  #14  patch  terraform  1Password/onepassword 2.1.0 → 2.1.2
       Plan not clean: ~ hcloud_server.stage (user_data). Needs your call.

Unverified — could not plan (N)
Rebasing (N)
```

Always state whether a plan was actually run and whether the Stage apply finished. "CI green" alone is not a recommendation to merge in this repo, and an enqueued PR is not a completed deploy.

Do not merge anything held or unverified without the user saying so.

---

## Error Handling

- **`gh` not authenticated** → tell the user to run `gh auth login` and stop.
- **`terraform init` fails on backend credentials** → do not merge on CI alone; report as unverified and ask the user to run the plan.
- **Merge rejected** → report it, leave the PR open, continue with the rest.
- **Stage apply fails after a merge** → surface the run log immediately and suggest reverting the bump; do not merge anything else until it is resolved.
