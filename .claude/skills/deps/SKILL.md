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

The gate that matters most in this repo. Before merging anything beyond a trivial patch, run a plan locally against the PR branch and confirm it is a no-op:

```bash
gh pr checkout <number>
terraform init
terraform workspace select stage
terraform plan
```

- `No changes.` → safe to merge.
- Changes limited to new optional attributes defaulting in → usually safe; say what they are in the report.
- **Any `must be replaced` / `-/+` destroy-and-recreate** → stop. Report it with the resource addresses. This is the failure mode a green `terraform_test` will not catch.

If you cannot run a plan (missing credentials — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `OP_SERVICE_ACCOUNT_TOKEN` are needed for the S3 backend and the 1Password provider), **say so explicitly in the report** and mark the PR as unverified rather than merging it on CI alone.

Also check whether the PR touches `versions.tf`. It normally should not — a change to a `required_providers` constraint is Dependabot raising a floor, and is worth reading:

```bash
gh pr diff <number> --repo reckoning/infrastructure --name-only
```

#### Gate D — mergeable state

`BEHIND` needs a rebase — `@dependabot rebase`. `DIRTY` → `@dependabot recreate`. Lockfile conflicts are common when two provider PRs are open at once, since they all edit `.terraform.lock.hcl`. `UNKNOWN` → re-poll.

### 4. Merge the safe ones

```bash
gh pr merge <number> --repo reckoning/infrastructure --squash
```

`main` has a merge queue, so this enqueues rather than merging on the spot.

**Merge one at a time and watch the Stage apply before merging the next**:

```bash
gh run list --repo reckoning/infrastructure --workflow Deploy --limit 3
```

Every open PR edits `.terraform.lock.hcl`, so each merge conflicts the rest — post `@dependabot recreate` on the remainder afterwards.

Branches are not auto-deleted:

```bash
gh api -X DELETE repos/reckoning/infrastructure/git/refs/heads/<headRefName>
```

### 5. Report

```
Merged / enqueued (N)
  #12  minor  terraform  hetznercloud/hcloud 1.63.0 → 1.68.0 — plan clean

Held — needs a decision (N)
  #13  major  terraform  hashicorp/aws 5.x → 6.0.0
       Provider major — read the upgrade guide before planning.

Unverified — could not plan (N)
Rebasing (N)
```

Always state whether a plan was actually run. "CI green" alone is not a recommendation to merge in this repo.

Do not merge anything held or unverified without the user saying so.

---

## Error Handling

- **`gh` not authenticated** → tell the user to run `gh auth login` and stop.
- **`terraform init` fails on backend credentials** → do not merge on CI alone; report as unverified and ask the user to run the plan.
- **Merge rejected** → report it, leave the PR open, continue with the rest.
- **Stage apply fails after a merge** → surface the run log immediately and suggest reverting the bump; do not merge anything else until it is resolved.
