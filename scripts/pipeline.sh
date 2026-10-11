#!/usr/bin/env bash
# pipeline.sh -- the PR check, shared by CI and local runs.
#
#   pipeline.sh --base DIR --merge DIR [--head DIR] [--allow-destroy] [--out DIR]
#
# Each DIR is a checkout of the repo:
#   base   the target branch as it is now; applied to an empty emulated account to stand in
#          for production state
#   merge  the PR merged into base -- what would actually land
#   head   the PR branch as pushed; optional, enables the stale-branch check
# Writes plan JSON and comment.md to --out. Exit 0 pass, 1 blocked or plan failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="" MERGE="" HEAD_DIR="" ALLOW="" OUT="$ROOT/.pr-out"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --merge) MERGE="$2"; shift 2 ;;
    --head) HEAD_DIR="$2"; shift 2 ;;
    --allow-destroy) ALLOW="--allow-destroy"; shift ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BASE" ] && [ -n "$MERGE" ] || { echo "--base and --merge are required" >&2; exit 2; }
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export TF_VAR_aws_endpoint="${TF_VAR_aws_endpoint:-http://127.0.0.1:${MOTO_PORT:-5000}}"
export TF_IN_AUTOMATION=1 TF_INPUT=0
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

log() { printf '\n==> %s\n' "$*" >&2; }

# A failed plan still gets a comment: the reviewer should see why, not just a red check.
plan_failed() {
  local which="$1" errlog="$2"
  {
    echo "<!-- terraform-pr-guardrails -->"
    echo "### Terraform plan: \`infra\` -- **PLAN FAILED** ($which)"
    echo
    echo '```'
    tail -n 40 "$errlog"
    echo '```'
  } >"$OUT/comment.md"
  cat "$OUT/comment.md"
  exit 1
}

tf() { terraform -chdir="$1/infra" "${@:2}"; }

log "reset emulated account"
"$ROOT/scripts/moto.sh" reset

log "apply base (stand-in for current production state)"
tf "$BASE" init -no-color >/dev/null 2>"$OUT/base.err" || plan_failed "base init" "$OUT/base.err"
tf "$BASE" apply -auto-approve -no-color >"$OUT/base-apply.log" 2>&1 || plan_failed "base apply" "$OUT/base-apply.log"

plan() {  # plan <name> <dir>: plan DIR against the base state, emit $OUT/<name>.json
  local name="$1" dir="$2"
  log "plan $name"
  cp "$BASE/infra/terraform.tfstate" "$dir/infra/terraform.tfstate"
  tf "$dir" init -no-color >/dev/null 2>"$OUT/$name.err" || plan_failed "$name init" "$OUT/$name.err"
  tf "$dir" plan -lock=false -no-color -out=tfplan >"$OUT/$name-plan.log" 2>&1 \
    || plan_failed "$name plan" "$OUT/$name-plan.log"
  tf "$dir" show -json tfplan >"$OUT/$name.json"
}

plan merge "$MERGE"
HEAD_ARGS=()
if [ -n "$HEAD_DIR" ]; then
  plan head "$HEAD_DIR"
  HEAD_ARGS=(--head-plan "$OUT/head.json")
fi

log "evaluate"
python3 "$ROOT/guard/plan_guard.py" --plan "$OUT/merge.json" ${HEAD_ARGS[@]+"${HEAD_ARGS[@]}"} $ALLOW --out "$OUT/comment.md"
