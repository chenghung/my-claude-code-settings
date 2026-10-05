#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO/scripts/migrate-claude-md-to-agents-md.sh"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# make_repo <name>: create an empty git repo under $T and echo its path.
make_repo() {
  local dir="$T/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '%s\n' "$dir"
}

# commit_all <repo>: stage and commit everything without a global identity.
commit_all() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t commit -q -m fixture
}

# run_script <args...>: run the script, capturing $out, $err and $rc.
run_script() {
  rc=0
  "$SCRIPT" "$@" > "$T/out" 2> "$T/err" || rc=$?
  out="$(cat "$T/out")"
  err="$(cat "$T/err")"
}

# expect_fail <name> <phrase> <args...>: exit 2 and stderr contains phrase.
expect_fail() {
  local name="$1" phrase="$2"
  shift 2
  run_script "$@"
  if [ "$rc" -eq 2 ] && [[ "$err" == *"$phrase"* ]]; then pass "$name"; else bad "$name (rc=$rc err=$err)"; fi
}

# ---- argument parsing ----
expect_fail no-args 'usage:'
r1="$(make_repo a1)"
r2="$(make_repo a2)"
expect_fail two-positionals 'usage:' "$r1" "$r2"
expect_fail unknown-flag 'usage:' "$r1" --force

# ---- repo root check ----
mkdir -p "$T/plain"
expect_fail non-git-dir 'not a git repository root' "$T/plain"
sub="$(make_repo withsub)"
mkdir -p "$sub/sub"
printf 'x\n' > "$sub/sub/f"
commit_all "$sub"
expect_fail git-subdir 'not a git repository root' "$sub/sub"

# ---- settings repo guard ----
expect_fail settings-repo 'refusing to migrate the settings repository' "$REPO"

# ---- clean tree ----
dirty="$(make_repo dirty-untracked)"
printf 'a\n' > "$dirty/CLAUDE.md"
commit_all "$dirty"
printf 'u\n' > "$dirty/untracked"
expect_fail untracked-file 'working tree is not clean' "$dirty"

mod="$(make_repo dirty-modified)"
printf 'a\n' > "$mod/CLAUDE.md"
commit_all "$mod"
printf 'b\n' >> "$mod/CLAUDE.md"
expect_fail modified-file 'working tree is not clean' "$mod"

# ---- success path ----
ok="$(make_repo clean)"
printf 'a\n' > "$ok/CLAUDE.md"
commit_all "$ok"
run_script "$ok"
if [ "$rc" -eq 0 ] && [[ "$out" == *'dry-run: no files changed'* ]]; then pass clean-dry-run; else bad "clean-dry-run (rc=$rc out=$out err=$err)"; fi
# --apply may precede the positional argument
run_script --apply "$ok"
if [ "$rc" -eq 0 ]; then pass apply-flag-any-position; else bad "apply-flag-any-position (rc=$rc err=$err)"; fi

exit "$fail"
