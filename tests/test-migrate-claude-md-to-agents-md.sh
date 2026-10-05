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

# snap <repo>: print every path outside .git (including gitignored ones) with its type,
# symlink link text, or file content, so two snapshots compare byte for byte.
snap() {
  (cd "$1" && find . -path ./.git -prune -o \
    -type l -printf 'L %p -> %l\n' -o \
    -type f -printf 'F %p\n' -exec cat {} \; -o \
    -type d -printf 'D %p\n')
}

# check <name> <repo> [expected-rc] [extra-arg]: run the script, assert rc, a clean
# porcelain status, and an identical before/after snapshot (porcelain misses ignored files).
check() {
  local want="${3:-0}" before_snap after_snap
  before_snap="$(snap "$2")"
  run_script "$2" ${4:+"$4"}
  after_snap="$(snap "$2")"
  if [ "$rc" -ne "$want" ]; then bad "$1 rc (rc=$rc want=$want out=$out err=$err)"; return 1; fi
  if [ -n "$(git -C "$2" status --porcelain)" ]; then bad "$1 changed files"; return 1; fi
  if [ "$before_snap" != "$after_snap" ]; then bad "$1 contents changed"; return 1; fi
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

# gitignored rule file: never mentioned, never deleted, keeps .claude/rules from rmdir
r="$(make_repo ignrule)"; put "$r" CLAUDE.md; put "$r" .claude/rules/a.md; printf '.claude/rules/local.md\n' > "$r/.gitignore"; commit_all "$r"
put "$r" .claude/rules/local.md
if check ignored-rule "$r"; then
  has ignored-rule 'delete .claude/rules/a.md'; lacks ignored-rule local.md; lacks ignored-rule 'rmdir .claude/rules'
fi

# gitignored CLAUDE.md next to a tracked AGENTS.md is a conflict
r="$(make_repo ignclaude)"; put "$r" AGENTS.md; printf 'CLAUDE.md\n' > "$r/.gitignore"; commit_all "$r"
put "$r" CLAUDE.md
if check ignored-claude "$r" 1; then has ignored-claude 'CONFLICT .: CLAUDE.md exists but is not tracked by git'; fi

# --apply must not change any file in this task (fixture has only case 1 / 4 / CONFLICT dirs)
r="$(make_repo applynoop)"; put "$r" AGENTS.md; put "$r" CLAUDE.md a; printf '@AGENTS.md\n' >> "$r/CLAUDE.md"
put "$r" p4/AGENTS.md; put "$r" pc/AGENTS.md; printf 'pc/CLAUDE.md\n' > "$r/.gitignore"; commit_all "$r"
put "$r" pc/CLAUDE.md
if check apply-noop "$r" 1 --apply; then has apply-noop '[case 1] .'; has apply-noop '[case 4] p4'; has apply-noop 'CONFLICT pc: CLAUDE.md exists but is not tracked by git'; fi

# ---- apply mode ----
# eq <name> <file> <expected-string>: assert exact file content via cmp.
eq() {
  printf '%s' "$3" > "$T/expected"
  if cmp -s "$T/expected" "$2"; then pass "$1"; else bad "$1 (content differs)"; fi
}
# gone / kept <name> <path>: assert a path no longer exists / still exists.
gone() { if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass "$1: gone"; else bad "$1: still exists $2"; fi; }
kept() { if [ -e "$2" ]; then pass "$1: kept"; else bad "$1: missing $2"; fi; }
ends_applied() { if [ "${out##*$'\n'}" = applied ]; then pass "$1: ends applied"; else bad "$1: summary in: $out"; fi; }

r="$(make_repo ap5)"; put "$r" CLAUDE.md 'root rules'; put "$r" .claude/CLAUDE.md 'dot claude'
mkdir -p "$r/.claude/rules"
printf -- '---\ndescription: x\n---\n\n\nrule a\n\n\n' > "$r/.claude/rules/a.md"
put "$r" .claude/rules/sub/b.md 'rule b'; commit_all "$r"
run_script "$r" --apply
if [ "$rc" -eq 0 ]; then pass apply5-rc; else bad "apply5-rc ($rc $err)"; fi
eq apply5-agents "$r/AGENTS.md" $'root rules\n\n---\n\ndot claude\n\n---\n\nrule a\n\n---\n\nrule b\n'
if [ -f "$r/AGENTS.md" ] && ! grep -q 'description: x' "$r/AGENTS.md"; then pass apply5-no-frontmatter; else bad apply5-no-frontmatter; fi
eq apply5-claude "$r/CLAUDE.md" $'@AGENTS.md\n'
for n in .claude/CLAUDE.md .claude/rules/a.md .claude/rules/sub .claude/rules; do gone apply5 "$r/$n"; done
ends_applied apply5

r="$(make_repo ap2)"; put "$r" CLAUDE.md 'old claude'; ln -s CLAUDE.md "$r/AGENTS.md"; commit_all "$r"
run_script "$r" --apply
if [ "$rc" -eq 0 ] && [ -f "$r/AGENTS.md" ] && [ ! -L "$r/AGENTS.md" ]; then pass apply2-regular; else bad "apply2-regular ($rc $err)"; fi
eq apply2-agents "$r/AGENTS.md" $'old claude\n'
eq apply2-claude "$r/CLAUDE.md" $'@AGENTS.md\n'

r="$(make_repo ap3)"; put "$r" AGENTS.md 'existing agents'; put "$r" CLAUDE.md 'claude text'; commit_all "$r"
run_script "$r" --apply
eq apply3-agents "$r/AGENTS.md" $'existing agents\n\n---\n\nclaude text\n'

r="$(make_repo apscoped)"; put "$r" CLAUDE.md; mkdir -p "$r/.claude/rules"
printf -- '---\npaths:\n  - src/**\n---\nbody\n' > "$r/.claude/rules/scoped.md"; commit_all "$r"
cp "$r/.claude/rules/scoped.md" "$T/scoped.orig"
run_script "$r" --apply
if cmp -s "$T/scoped.orig" "$r/.claude/rules/scoped.md"; then pass apply-scoped-identical; else bad apply-scoped-identical; fi
kept apply-scoped "$r/.claude/rules"

# CLAUDE.local.md is gitignored (ignore file committed first so the tree is clean)
r="$(make_repo aplocal)"; put "$r" CLAUDE.md; printf 'CLAUDE.local.md\n' > "$r/.gitignore"; commit_all "$r"
put "$r" CLAUDE.local.md 'private'
run_script "$r" --apply
eq apply-local "$r/CLAUDE.local.md" $'private\n'

r="$(make_repo apidem)"; put "$r" CLAUDE.md 'one'; put "$r" .claude/rules/a.md 'rule a'; commit_all "$r"
run_script "$r" --apply; commit_all "$r"
run_script "$r" --apply
if [ "$rc" -eq 0 ] && [ -z "$(git -C "$r" status --porcelain)" ] \
  && [ "$out" = $'[case 1] .\n  skip (already migrated)\napplied' ]; then pass apply-idempotent; else bad "apply-idempotent ($rc $out)"; fi

r="$(make_repo apign)"; put "$r" CLAUDE.md; put "$r" .claude/rules/a.md; printf '.claude/rules/local.md\n' > "$r/.gitignore"; commit_all "$r"
put "$r" .claude/rules/local.md 'mine'
run_script "$r" --apply
eq apply-ignored-rule "$r/.claude/rules/local.md" $'mine\n'
kept apply-ignored-rule "$r/.claude/rules"
gone apply-ignored-rule "$r/.claude/rules/a.md"

r="$(make_repo apconf)"; put "$r" other.md; ln -s other.md "$r/CLAUDE.md"; put "$r" pkg/CLAUDE.md 'pkg text'; commit_all "$r"
run_script "$r" --apply
if [ "$rc" -eq 1 ] && [ -L "$r/CLAUDE.md" ] && [ "$(readlink "$r/CLAUDE.md")" = other.md ]; then pass apply-conflict-untouched; else bad "apply-conflict-untouched ($rc)"; fi
eq apply-conflict-pkg-agents "$r/pkg/AGENTS.md" $'pkg text\n'
eq apply-conflict-pkg-claude "$r/pkg/CLAUDE.md" $'@AGENTS.md\n'
ends_applied apply-conflict

exit "$fail"
