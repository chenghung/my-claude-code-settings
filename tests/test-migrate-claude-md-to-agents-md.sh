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

# ---- discovery, classification and dry-run report ----
# put <repo> <path> [content]: write a fixture file (content defaults to one line).
put() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "${3:-text}" > "$1/$2"
}

# check <name> <repo> [expected-rc]: run dry-run, assert rc and a clean tree afterwards.
check() {
  local want="${3:-0}"
  run_script "$2"
  if [ "$rc" -ne "$want" ]; then bad "$1 rc (rc=$rc want=$want out=$out err=$err)"; return 1; fi
  if [ -n "$(git -C "$2" status --porcelain)" ]; then bad "$1 changed files"; return 1; fi
  return 0
}

# has / lacks <name> <needle>: assert $out contains / does not contain a needle.
has() { if [[ "$out" == *"$2"* ]]; then pass "$1: has $2"; else bad "$1: missing '$2' in: $out"; fi; }
lacks() { if [[ "$out" != *"$2"* ]]; then pass "$1: lacks $2"; else bad "$1: unexpected '$2' in: $out"; fi; }
# before <name> <a> <b>: assert the first occurrence of a precedes that of b in $out.
before() {
  local pre="${out%%"$2"*}" rest="${out%%"$3"*}"
  if [[ "$out" == *"$2"* && "$out" == *"$3"* && ${#pre} -lt ${#rest} ]]; then pass "$1: order $2"; else bad "$1: order of '$2' / '$3' in: $out"; fi
}

r="$(make_repo c1)"; put "$r" CLAUDE.md a; printf 'b\n@AGENTS.md\n' >> "$r/CLAUDE.md"; put "$r" AGENTS.md; commit_all "$r"
if check case1 "$r"; then has case1 '[case 1] .'; has case1 'skip (already migrated)'; has case1 'dry-run: no files changed'; fi

r="$(make_repo c2)"; put "$r" CLAUDE.md; ln -s CLAUDE.md "$r/AGENTS.md"; put "$r" .claude/rules/a.md; commit_all "$r"
if check case2 "$r"; then
  for n in '[case 2] .' 'remove-symlink AGENTS.md' 'write AGENTS.md' 'rewrite CLAUDE.md' 'delete .claude/rules/a.md' 'rmdir .claude/rules'; do has case2 "$n"; done
fi

r="$(make_repo c3)"; put "$r" CLAUDE.md; put "$r" AGENTS.md; commit_all "$r"
if check case3 "$r"; then has case3 '[case 3] .'; has case3 'write AGENTS.md'; fi

r="$(make_repo c4)"; put "$r" AGENTS.md; commit_all "$r"
if check case4 "$r"; then has case4 '[case 4] .'; has case4 'skip (nothing to migrate)'; fi

r="$(make_repo c5)"; put "$r" CLAUDE.md; commit_all "$r"
if check case5 "$r"; then has case5 '[case 5] .'; fi

r="$(make_repo c5b)"; put "$r" .claude/CLAUDE.md; commit_all "$r"
if check dotclaude-only "$r"; then for n in '[case 5] .' 'create CLAUDE.md' 'delete .claude/CLAUDE.md'; do has dotclaude-only "$n"; done; fi

r="$(make_repo sub)"; put "$r" CLAUDE.md; put "$r" pkg/CLAUDE.md; put "$r" pkg/.claude/CLAUDE.md; commit_all "$r"
if check subdir "$r"; then has subdir '[case 5] .'; has subdir '[case 5] pkg'; before subdir '[case 5] .' '[case 5] pkg'; fi

r="$(make_repo scoped)"; put "$r" CLAUDE.md; mkdir -p "$r/.claude/rules"
printf -- '---\npaths:\n  - src/**\n---\nbody\n' > "$r/.claude/rules/scoped.md"; commit_all "$r"
if check scoped "$r"; then has scoped 'WARNING path-scoped rule kept: .claude/rules/scoped.md'; lacks scoped 'delete .claude/rules/scoped.md'; lacks scoped 'rmdir'; fi

r="$(make_repo bodypaths)"; put "$r" CLAUDE.md; put "$r" .claude/rules/body.md; printf 'paths: foo\n' >> "$r/.claude/rules/body.md"; commit_all "$r"
if check bodypaths "$r"; then has bodypaths 'delete .claude/rules/body.md'; lacks bodypaths WARNING; fi

r="$(make_repo indented)"; put "$r" CLAUDE.md; mkdir -p "$r/.claude/rules"
printf -- '---\nmeta:\n  paths: x\n---\nbody\n' > "$r/.claude/rules/i.md"; commit_all "$r"
if check indented "$r"; then has indented 'delete .claude/rules/i.md'; lacks indented WARNING; fi

r="$(make_repo nested)"; put "$r" CLAUDE.md; put "$r" .claude/rules/sub/b.md; commit_all "$r"
if check nested "$r"; then
  for n in 'delete .claude/rules/sub/b.md' 'rmdir .claude/rules/sub' 'rmdir .claude/rules'; do has nested "$n"; done
  before nested 'delete .claude/rules/sub/b.md' 'rmdir .claude/rules/sub'
  before nested 'rmdir .claude/rules/sub' 'rmdir .claude/rules'$'\n'
fi

r="$(make_repo conf1)"; put "$r" other.md; ln -s other.md "$r/CLAUDE.md"; commit_all "$r"
if check conflict-claude "$r" 1; then has conflict-claude 'CONFLICT .: CLAUDE.md is a symlink'; fi

r="$(make_repo conf2)"; put "$r" README.md; ln -s README.md "$r/AGENTS.md"; commit_all "$r"
if check conflict-agents "$r" 1; then has conflict-agents 'CONFLICT .: AGENTS.md is a symlink not pointing to sibling CLAUDE.md'; fi

r="$(make_repo conf3)"; put "$r" other.md; ln -s other.md "$r/CLAUDE.md"; put "$r" pkg/CLAUDE.md; commit_all "$r"
if check conflict-continues "$r" 1; then has conflict-continues '[case 5] pkg'; has conflict-continues 'dry-run: no files changed'; fi

r="$(make_repo ign)"; put "$r" CLAUDE.md; printf 'node_modules\n' > "$r/.gitignore"; commit_all "$r"
put "$r" node_modules/x/CLAUDE.md
if check ignored "$r"; then lacks ignored node_modules; fi

exit "$fail"
