#!/usr/bin/env bash
# demo.sh NN|all -- build a demo PR in a throwaway clone and run the PR check against it.
#
# Each demos/NN-*/ holds make-pr.sh (creates branch `pr`, and may move main on), an expect
# file (PASS or BLOCKED), and optionally an args file passed to simulate-pr.sh. A demo
# whose result differs from expect fails, so `demo.sh all` doubles as the integration test.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/moto.sh" start >/dev/null || exit 1

run_one() {
  local dir="$1" name expect args clone rc got
  name="$(basename "$dir")"
  expect="$(tr -d '[:space:]' <"$dir/expect")"
  args="$(cat "$dir/args" 2>/dev/null || true)"
  clone="$(mktemp -d)"

  # Clone what is committed, so an uncommitted edit can't leak into a demo.
  git clone -q "$ROOT" "$clone/repo"
  git -C "$clone/repo" config user.name demo
  git -C "$clone/repo" config user.email demo@localhost
  (cd "$clone/repo" && bash -e "$dir/make-pr.sh") >/dev/null || { echo "FAIL $name: make-pr.sh errored"; rm -rf "$clone"; return 1; }

  mkdir -p "$ROOT/.pr-out/$name"
  # shellcheck disable=SC2086 # args is a flag list
  (cd "$clone/repo" && PR_OUT="$ROOT/.pr-out/$name" ./scripts/simulate-pr.sh pr $args) \
    >"$ROOT/.pr-out/$name/run.log" 2>&1
  rc=$?
  rm -rf "$clone"

  case "$rc" in 0) got=PASS ;; 1) got=BLOCKED ;; *) got="ERROR($rc)" ;; esac
  if [ "$got" = "$expect" ]; then
    printf 'ok   %-32s %s\n' "$name" "$got"
  else
    printf 'FAIL %-32s expected %s, got %s -- see .pr-out/%s/run.log\n' "$name" "$expect" "$got" "$name"
    return 1
  fi
}

target="${1:?usage: demo.sh NN|all}"
failed=0
for dir in "$ROOT"/demos/*/; do
  dir="${dir%/}"
  case "$target" in all) ;; *) case "$(basename "$dir")" in "$target"-*) ;; *) continue ;; esac ;; esac
  run_one "$dir" || failed=$((failed + 1))
  [ "$target" = all ] || cat "$ROOT/.pr-out/$(basename "$dir")/comment.md" 2>/dev/null
done
[ "$failed" -eq 0 ]
