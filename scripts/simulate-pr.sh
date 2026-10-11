#!/usr/bin/env bash
# simulate-pr.sh BRANCH [--base main] [--allow-destroy] -- run the PR check locally.
#
# Builds the same three checkouts CI gets (base, branch merged into base, branch head) as
# throwaway worktrees, so the repo you run it from is left untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRANCH="${1:?usage: simulate-pr.sh BRANCH [--base main] [--allow-destroy]}"; shift
BASE_REF=main EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2 ;;
    --allow-destroy) EXTRA+=(--allow-destroy); shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO="$(git rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
cleanup() {
  for d in base merge head; do git -C "$REPO" worktree remove --force "$WORK/$d" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

git -C "$REPO" worktree add -q --detach "$WORK/base" "$BASE_REF"
git -C "$REPO" worktree add -q --detach "$WORK/head" "$BRANCH"
git -C "$REPO" worktree add -q --detach "$WORK/merge" "$BASE_REF"
# The same merge GitHub builds for refs/pull/N/merge. It lands on a detached HEAD in a
# throwaway worktree, so no branch in the repo moves.
if ! git -C "$WORK/merge" -c user.name=pr-sim -c user.email=pr-sim@localhost \
     merge -q --no-ff --no-edit "$BRANCH" >/dev/null 2>&1; then
  echo "merge of $BRANCH into $BASE_REF conflicts -- resolve before the plan can run" >&2
  exit 1
fi

"$ROOT/scripts/pipeline.sh" --base "$WORK/base" --merge "$WORK/merge" --head "$WORK/head" \
  --out "${PR_OUT:-$REPO/.pr-out}" ${EXTRA[@]+"${EXTRA[@]}"}
