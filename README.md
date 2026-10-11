# terraform-pr-guardrails

A pull-request check for Terraform that blocks the changes that look harmless in review and
destroy data in production: a forced replacement hidden in a one-word rename, a module rename
without a `moved` block, a `count` list that shifts under you, and a stale branch whose plan
quietly reverts work merged after it was opened.

It runs entirely locally against [Moto](https://github.com/getmoto/moto), an AWS emulator, so
every failure mode below is reproducible with no AWS account and nothing to clean up.

```
$ make setup && make demos
ok   00-safe-change                   PASS
ok   01-forced-replacement            BLOCKED
ok   02-allow-destroy-label           PASS
ok   03-module-rename                 BLOCKED
ok   04-module-rename-with-moved      PASS
ok   05-count-index-shift             BLOCKED
ok   06-stale-branch                  BLOCKED
```

## What it catches

Each demo is a small, plausible PR built by `demos/NN-*/make-pr.sh`.

| Demo | The PR | Why it is dangerous | Verdict |
|---|---|---|---|
| [00](demos/00-safe-change/make-pr.sh) | Tag the lock table | Nothing: an in-place update | PASS |
| [01](demos/01-forced-replacement/make-pr.sh) | Rename a bucket | S3 bucket names are immutable; the provider replaces the bucket and its objects are gone | BLOCKED |
| [02](demos/02-allow-destroy-label/make-pr.sh) | Same, with the `allow-destroy` label | The destroy is intended and acknowledged | PASS, with warnings |
| [03](demos/03-module-rename/make-pr.sh) | Rename a module | Every address inside it changes; Terraform destroys the old resources and creates new ones | BLOCKED |
| [04](demos/04-module-rename-with-moved/make-pr.sh) | Same, with a `moved` block | State-only move; nothing recreated | PASS |
| [05](demos/05-count-index-shift/make-pr.sh) | Remove the first tenant from a `count` list | Every later tenant shifts down an index; their buckets are replaced | BLOCKED |
| [06](demos/06-stale-branch/make-pr.sh) | Edit a KMS key description, on a branch opened before `main` added a bucket | The branch diff is one clean line, but its plan against current state deletes the bucket it never had | BLOCKED |

What a blocked PR gets as a comment (demo 01):

> ### Terraform plan: `infra` -- **BLOCKED**
>
> `-/+3` replace
>
> #### Blocking: destroys stateful resources
> - `module.logs.aws_s3_bucket.this` will be **replaced** -- forced by `bucket`. `aws_s3_bucket` holds data; add the `allow-destroy` label if this is intended.
>
> #### Warnings
> - `module.logs.aws_s3_bucket_public_access_block.this` will be **replaced** -- forced by `bucket`.
> - `module.logs.aws_s3_bucket_versioning.this` will be **replaced** -- forced by `bucket`.

## How it works

```
             PR opened / pushed / labeled
                         |
     refs/pull/N/merge (PR merged into base, as of now)
           /             |                \
     parent 1          merge            parent 2
       base            result             head
         |               |                  |
   apply to Moto    plan against      plan against
  (stand-in for     base state        base state
   production)           |                  |
         \_______________|__________________/
                         |
             guard/plan_guard.py
   - destroy/replace of a protected type  -> block (unless labeled)
   - head plan != merge plan              -> block (branch is stale)
   - moves, other replacements            -> reported
                         |
          one PR comment, updated in place
```

1. **Plan what would land, not what was pushed.** The plan that matters is the PR merged into
   the current base. CI checks out GitHub's merge ref, and its two parents give a base and a
   head from the same instant, so the three checkouts can't disagree about what `main` was.
2. **Judge the plan, not the diff.** The guard reads `terraform show -json`, so it sees forced
   replacements (`replace_paths`), moves (`previous_address`) and index shifts that a textual
   diff of `.tf` files hides.
3. **Protect by resource type.** `guard/policy.json` lists the types that hold data (buckets,
   tables, keys, databases, queues). Destroying or replacing one blocks the PR; the
   `allow-destroy` label turns that into a warning, so the escape hatch is explicit and
   visible in the PR history.
4. **Catch stale branches.** The head of the branch is planned too. Anything the branch would
   change that the merged result would not is work the branch would revert if applied from
   the branch (as Atlantis-style workflows do) or trusted by a reviewer reading its plan.
5. **The base judges the PR.** CI runs the base branch's copy of the pipeline and guard, so a
   PR cannot weaken the check that evaluates it. Changes to `guard/` are covered by the unit
   tests until they merge.

## Running it

Requires Terraform >= 1.6, Python 3.10+, git, and curl. Works on macOS and Linux.

```bash
make setup             # .venv with the Moto server
make test              # unit tests for the guard, no Terraform needed
make demos             # every demo, asserting each verdict (~4 min: real init/apply/plan)
make demo N=06         # one demo, printing the PR comment
```

To check a branch of your own: `./scripts/moto.sh start`, then
`./scripts/simulate-pr.sh <branch> [--allow-destroy]`. It builds the same base, merge and head
checkouts as CI in throwaway worktrees; your working copy is not touched.

## Layout

```
infra/                    the Terraform under guard (S3, DynamoDB, KMS, IAM)
guard/plan_guard.py       plan JSON -> verdict + PR comment (stdlib only)
guard/policy.json         protected resource types, override label
scripts/pipeline.sh       the check itself, shared by CI and local runs
scripts/simulate-pr.sh    local stand-in for GitHub's merge ref
scripts/demo.sh           builds each demo PR in a throwaway clone and checks the verdict
demos/NN-*/               one failure mode each
tests/                    unit tests over real plans captured from the demos
.github/workflows/        the PR workflow
```

## Limits

- **An emulator is not AWS.** Moto models the APIs, not every behaviour. One visible gap: it
  drops S3 bucket tags, so `default_tags` would plan as a change on every run and is left out.
  Use it to rehearse plan logic, not to certify an apply.
- **State is rebuilt per run** by applying the base branch to an empty emulated account. A real
  deployment would plan against the remote state backend instead; the guard is unchanged.
- **The stale check is deliberately strict.** Any difference between the head and merged plans
  blocks, including harmless ones. Updating the branch clears it.
- **Fork PRs** get a read-only token, so the comment step cannot post; the job summary still
  carries the result.
- **Applying** after merge is out of scope: that is the part that needs real credentials.
