#!/usr/bin/env bash
# Tests for scripts/external-skills-plan.py (jsonc manifest -> TSV plan).
# Uses a throwaway fake repo as <repo path>; only the last two cases read the
# real external-skills.jsonc. No network, no real HOME, no npx.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN="$REPO/scripts/external-skills-plan.py"
REAL_LIST="$REPO/external-skills.jsonc"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0

pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

TAB=$'\t'
ALL4='claude-code codex opencode antigravity-cli'

# Fake repo with a skills/ dir and a nested commands/ file (flattens to sub-cmd).
FAKE="$TMP/fakerepo"
mkdir -p "$FAKE/skills/localskill" "$FAKE/commands/sub"
printf '# cmd\n' > "$FAKE/commands/sub/cmd.md"

# run_plan <args...>: run the plan script, capture OUT (stdout), ERR (stderr), RC.
OUT="" ERR="" RC=0
run_plan() {
  RC=0
  OUT="$(python3 "$PLAN" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# expect_out <name> <expected>: last run_plan must exit 0 with exactly this stdout.
expect_out() {
  if [[ "$RC" -eq 0 && "$OUT" == "$2" ]]; then
    pass "$1"
  else
    bad "$1"
    printf '  rc=%s\n  expected:\n%s\n  actual:\n%s\n  stderr: %s\n' "$RC" "$2" "$OUT" "$ERR" >&2
  fi
}

# expect_error <name> <ERE>: last run_plan must exit 1, print nothing on
# stdout, and every stderr line must start with "error:"; the stderr text
# must also match the ERE (the reason).
expect_error() {
  local ok=1 line
  [[ "$RC" -eq 1 ]] || ok=0
  [[ -z "$OUT" ]] || ok=0
  [[ -n "$ERR" ]] || ok=0
  while IFS= read -r line; do
    [[ "$line" == error:* ]] || ok=0
  done <<< "$ERR"
  [[ "$ERR" =~ $2 ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass "$1"
  else
    bad "$1"
    printf '  rc=%s stdout=[%s]\n  stderr: %s\n' "$RC" "$OUT" "$ERR" >&2
  fi
}

# expect_prefixed <name> <basename>: every stderr line of the last run_plan must
# start with "error: <basename>: " (the manifest file name, as the invalid-JSON
# message already does).
expect_prefixed() {
  local ok=1 line
  [[ -n "$ERR" ]] || ok=0
  while IFS= read -r line; do
    [[ "$line" == "error: $2: "* ]] || ok=0
  done <<< "$ERR"
  if [[ "$ok" -eq 1 ]]; then
    pass "$1"
  else
    bad "$1"
    printf '  stderr: %s\n' "$ERR" >&2
  fi
}

# expect_line <name> <ERE>: some single stderr line of the last run_plan must
# match the ERE (lets one test tie two facts, e.g. a name and its reason, to
# the same problem).
expect_line() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ $2 ]]; then
      pass "$1"
      return
    fi
  done <<< "$ERR"
  bad "$1"
  printf '  stderr: %s\n' "$ERR" >&2
}

# expect_usage <name>: last run_plan must exit 2 with a usage message on stderr
# and nothing on stdout. Requiring "usage" keeps python's own exit 2 for a
# missing script file from passing.
expect_usage() {
  if [[ "$RC" -eq 2 && -z "$OUT" && "$ERR" =~ [Uu]sage ]]; then
    pass "$1"
  else
    bad "$1"
    printf '  rc=%s stdout=[%s]\n  stderr: %s\n' "$RC" "$OUT" "$ERR" >&2
  fi
}

# Case 1: comment stripping keeps URLs, handles escapes, line/block comments
cat > "$TMP/comments.jsonc" <<'EOF'
// header comment with "quotes" and https://example.com/x
[
  /* block comment
     spanning several lines, with "quotes" and // inside */
  {
    "name": "u1", // trailing line comment
    "repo": "https://github.com/o/r/tree/main/x", /* inline block */
    "description": "has // and /* these */ inside \" escaped quote // still string"
  },
  {
    "name": "u2",
    "repo": "o/r2",
    "description": "path C:\\" // comment right after a string ending in a backslash
  }
]
EOF
run_plan "$TMP/comments.jsonc" "$FAKE" claude codex opencode antigravity
expect_out comment-strip-keeps-url \
"group${TAB}https://github.com/o/r/tree/main/x${TAB}${ALL4}${TAB}u1
group${TAB}o/r2${TAB}${ALL4}${TAB}u2
want${TAB}claude${TAB}u1
want${TAB}codex${TAB}u1
want${TAB}opencode${TAB}u1
want${TAB}antigravity${TAB}u1
want${TAB}claude${TAB}u2
want${TAB}codex${TAB}u2
want${TAB}opencode${TAB}u2
want${TAB}antigravity${TAB}u2
known${TAB}u1${TAB}claude codex opencode antigravity
known${TAB}u2${TAB}claude codex opencode antigravity"

# Case 2: unterminated /* comment is a format error
printf '[\n  /* never closed\n  {"name":"a","repo":"o/r","description":"d"}\n]\n' > "$TMP/f1.jsonc"
run_plan "$TMP/f1.jsonc" "$FAKE" claude
expect_error unterminated-block-comment 'unterminated'
expect_prefixed unterminated-block-comment-has-file-prefix f1.jsonc

# Case 3: trailing comma -> error with the line and column of the ORIGINAL file.
# The trailing comma sits on line 6, after a 3-line block comment, so a stripper
# that drops newlines would report the wrong line.
cat > "$TMP/f2.jsonc" <<'EOF'
/* line 1
   line 2
   line 3 */
[
  {"name":"a","repo":"o/r","description":"d"}
  ,{"name":"b","repo":"o/r","description":"d"},]
EOF
run_plan "$TMP/f2.jsonc" "$FAKE" claude
expect_error trailing-comma-array 'line [0-9]+,? column [0-9]+'
if [[ "$ERR" =~ line\ 6, ]]; then pass trailing-comma-line-maps-to-original; else bad trailing-comma-line-maps-to-original; printf '  stderr: %s\n' "$ERR" >&2; fi

printf '[\n  {"name":"a","repo":"o/r","description":"d",}\n]\n' > "$TMP/f3.jsonc"
run_plan "$TMP/f3.jsonc" "$FAKE" claude
expect_error trailing-comma-object 'line [0-9]+,? column [0-9]+'

# Same-line block comment before the entry, trailing comma right after it:
# "[" is column 1, "/* c */" columns 2-8, space 9, the 43-char object
# columns 10-52, so the comma is column 53 of the ORIGINAL line. Python 3.13+
# reports the comma (53); older versions report the "]" (54). Both are original
# positions; a stripper that deleted the comment would report a smaller column.
printf '%s\n' '[/* c */ {"name":"a","repo":"o/r","description":"d"},]' > "$TMP/f15.jsonc"
run_plan "$TMP/f15.jsonc" "$FAKE" claude
expect_error trailing-comma-after-inline-comment 'line 1, column (53|54):'

# Case 4: missing required fields (each one on its own)
printf '[{"repo":"o/r","description":"d"}]\n' > "$TMP/f4.jsonc"
run_plan "$TMP/f4.jsonc" "$FAKE" claude
expect_error missing-name 'name'

printf '[{"name":"a","description":"d"}]\n' > "$TMP/f5.jsonc"
run_plan "$TMP/f5.jsonc" "$FAKE" claude
expect_error missing-repo 'repo'

printf '[{"name":"a","repo":"o/r"}]\n' > "$TMP/f6.jsonc"
run_plan "$TMP/f6.jsonc" "$FAKE" claude
expect_error missing-description 'description'

printf '[{"name":"a","repo":"o/r","description":"   "}]\n' > "$TMP/f7.jsonc"
run_plan "$TMP/f7.jsonc" "$FAKE" claude
expect_error blank-description 'description'

# Case 5: other format errors
printf '[{"name":"a","repo":"o/r","description":"d","platforms":["claude","windows"]}]\n' > "$TMP/f8.jsonc"
run_plan "$TMP/f8.jsonc" "$FAKE" claude
expect_error unknown-platform-name 'windows'

printf '[{"name":"a","repo":"o/r","description":"d","platforms":[]}]\n' > "$TMP/f9.jsonc"
run_plan "$TMP/f9.jsonc" "$FAKE" claude
expect_error empty-platforms 'platforms'

printf '{"name":"a","repo":"o/r","description":"d"}\n' > "$TMP/f10.jsonc"
run_plan "$TMP/f10.jsonc" "$FAKE" claude
expect_error top-level-not-array 'array'

printf '["just-a-string"]\n' > "$TMP/f11.jsonc"
run_plan "$TMP/f11.jsonc" "$FAKE" claude
expect_error element-not-object 'object'

printf '[{"name":"has space","repo":"o/r","description":"d"}]\n' > "$TMP/f12.jsonc"
run_plan "$TMP/f12.jsonc" "$FAKE" claude
expect_error name-with-whitespace 'has space'

printf '[{"name":"a","repo":"o/r x","description":"d"}]\n' > "$TMP/f13.jsonc"
run_plan "$TMP/f13.jsonc" "$FAKE" claude
expect_error repo-with-whitespace 'repo'

# Skills CLI treats "*" as "all skills", so it is rejected as a name.
printf '%s\n' '[{"name":"a*b","repo":"o/r","description":"d"}]' > "$TMP/f16.jsonc"
run_plan "$TMP/f16.jsonc" "$FAKE" claude
expect_error name-with-asterisk 'a\*b'
printf '%s\n' '[{"name":"*","repo":"o/r","description":"d"}]' > "$TMP/f17.jsonc"
run_plan "$TMP/f17.jsonc" "$FAKE" claude
expect_error name-is-asterisk '\*'

# Names must match ^[A-Za-z0-9][A-Za-z0-9._-]*$: a name becomes the value of
# `skills add -s`, where a leading - is read as a flag, and a path-like name
# must not reach the skills directories.
printf '%s\n' '[{"name":"-a","repo":"o/r","description":"d"}]' > "$TMP/f30.jsonc"
run_plan "$TMP/f30.jsonc" "$FAKE" claude
expect_error name-is-dash-a '-a'
printf '%s\n' '[{"name":"--all","repo":"o/r","description":"d"}]' > "$TMP/f31.jsonc"
run_plan "$TMP/f31.jsonc" "$FAKE" claude
expect_error name-is-double-dash-all '--all'
printf '%s\n' '[{"name":"a/b","repo":"o/r","description":"d"}]' > "$TMP/f32.jsonc"
run_plan "$TMP/f32.jsonc" "$FAKE" claude
expect_error name-with-slash 'a/b'
printf '%s\n' '[{"name":"..","repo":"o/r","description":"d"}]' > "$TMP/f33.jsonc"
run_plan "$TMP/f33.jsonc" "$FAKE" claude
expect_error name-is-dotdot '\.\.'

# Control characters in a name must not break the one-error-per-line format;
# each problem here (whitespace in name) is exactly one line.
printf '%s\n' '[{"name":"a\nb","repo":"o/r","description":"d"}]' > "$TMP/f18.jsonc"
run_plan "$TMP/f18.jsonc" "$FAKE" claude
expect_error name-with-newline 'whitespace'
if [[ "$(wc -l <<< "$ERR")" -eq 1 ]]; then pass name-with-newline-is-one-line; else bad name-with-newline-is-one-line; printf '  stderr: %s\n' "$ERR" >&2; fi
printf '%s\n' '[{"name":"a\tb","repo":"o/r","description":"d"}]' > "$TMP/f19.jsonc"
run_plan "$TMP/f19.jsonc" "$FAKE" claude
expect_error name-with-tab 'whitespace'
if [[ "$(wc -l <<< "$ERR")" -eq 1 ]]; then pass name-with-tab-is-one-line; else bad name-with-tab-is-one-line; printf '  stderr: %s\n' "$ERR" >&2; fi

printf '%s\n' '[{"name":"a","repo":"o/r","description":"d","platforms":"claude"}]' > "$TMP/f20.jsonc"
run_plan "$TMP/f20.jsonc" "$FAKE" claude
expect_error platforms-not-array 'platforms'

# Non-UTF-8 bytes: one clean error line with the file prefix, no traceback.
printf '[{"name":"a\377","repo":"o/r","description":"d"}]\n' > "$TMP/f21.jsonc"
run_plan "$TMP/f21.jsonc" "$FAKE" claude
expect_error non-utf8-manifest 'error: f21\.jsonc: '
expect_prefixed non-utf8-manifest-has-file-prefix f21.jsonc
if [[ "$ERR" != *Traceback* ]]; then pass non-utf8-manifest-no-traceback; else bad non-utf8-manifest-no-traceback; fi

# Unreadable manifest (missing file) is reported with the same file prefix.
run_plan "$TMP/f22-missing.jsonc" "$FAKE" claude
expect_error missing-manifest-file 'cannot read'
expect_prefixed missing-manifest-file-has-file-prefix f22-missing.jsonc

# Case 6: duplicate name across the whole list (even with different repos)
cat > "$TMP/dup.jsonc" <<'EOF'
[
  {"name":"dupname","repo":"o/r1","description":"d"},
  {"name":"other","repo":"o/r1","description":"d"},
  {"name":"dupname","repo":"o/r2","description":"d","platforms":["codex"]}
]
EOF
run_plan "$TMP/dup.jsonc" "$FAKE" claude codex
expect_error duplicate-name 'dupname'

# Case 7: collision with fake repo skills/ directory name
printf '[{"name":"localskill","repo":"o/r","description":"d"}]\n' > "$TMP/skills-collide.jsonc"
run_plan "$TMP/skills-collide.jsonc" "$FAKE" claude
expect_error collides-with-skills-dir 'localskill'

# Case 8: collision with flattened commands/ name (commands/sub/cmd.md -> sub-cmd)
printf '[{"name":"sub-cmd","repo":"o/r","description":"d"}]\n' > "$TMP/cmd-collide.jsonc"
run_plan "$TMP/cmd-collide.jsonc" "$FAKE" claude
expect_error collides-with-flattened-command 'sub-cmd'

# Case 9: every problem is reported, not just the first one. Each problem comes
# from its own fully specified entry, so no reason can be satisfied by another
# entry's text: skills/ collision, flattened-command collision, unknown
# platform, missing description, duplicate name.
cat > "$TMP/f14.jsonc" <<'EOF'
[
  {"name":"localskill","repo":"o/r","description":"d"},
  {"name":"sub-cmd","repo":"o/r","description":"d"},
  {"name":"okname","repo":"o/r","description":"d","platforms":["nope"]},
  {"name":"nodoc","repo":"o/r"},
  {"name":"okname","repo":"o/r","description":"d"}
]
EOF
run_plan "$TMP/f14.jsonc" "$FAKE" claude
expect_error multi-error-first 'localskill'
expect_line multi-error-skills-collision 'localskill.*collides'
expect_line multi-error-command-collision 'sub-cmd.*collides'
expect_line multi-error-unknown-platform 'nope'
expect_line multi-error-missing-description 'nodoc.*description'
expect_line multi-error-duplicate-name 'duplicate.*okname'
if [[ "$(wc -l <<< "$ERR")" -ge 5 ]]; then
  pass multi-error-line-count
else
  bad multi-error-line-count
  printf '  stderr: %s\n' "$ERR" >&2
fi

# Case 10: usage errors exit 2
printf '[{"name":"a","repo":"o/r","description":"d"}]\n' > "$TMP/ok1.jsonc"
run_plan
expect_usage usage-no-args
run_plan "$TMP/ok1.jsonc" "$FAKE"
expect_usage usage-no-platform
run_plan "$TMP/ok1.jsonc" "$FAKE" claude gemini
expect_usage usage-unknown-platform-arg

# Shared fixture for filtering / mapping / grouping / want / known.
# alpha, eps: all platforms; beta: codex only; gamma: claude only;
# delta: opencode+claude with a duplicated claude (listed out of order).
cat > "$TMP/main.jsonc" <<'EOF'
[
  {"name":"alpha","repo":"o/r1","description":"d"},
  {"name":"beta","repo":"o/r2","description":"d","platforms":["codex"]},
  {"name":"gamma","repo":"o/r1","description":"d","platforms":["claude"]},
  {"name":"delta","repo":"o/r2","description":"d","platforms":["opencode","claude","claude"]},
  {"name":"eps","repo":"o/r1","description":"d"}
]
EOF

# Case 11: platform filter (select claude only: beta, codex-only, vanishes
# from group and want but stays in known)
run_plan "$TMP/main.jsonc" "$FAKE" claude
expect_out filter-claude-only \
"group${TAB}o/r1${TAB}claude-code${TAB}alpha gamma eps
group${TAB}o/r2${TAB}claude-code${TAB}delta
want${TAB}claude${TAB}alpha
want${TAB}claude${TAB}gamma
want${TAB}claude${TAB}delta
want${TAB}claude${TAB}eps
known${TAB}alpha${TAB}claude codex opencode antigravity
known${TAB}beta${TAB}codex
known${TAB}gamma${TAB}claude
known${TAB}delta${TAB}claude opencode
known${TAB}eps${TAB}claude codex opencode antigravity"
if [[ "$RC" -eq 0 && -n "$OUT" ]] && ! grep -q "^group.*beta" <<< "$OUT" && ! grep -q "^want${TAB}.*${TAB}beta$" <<< "$OUT"; then
  pass filter-excludes-unselected-from-group-and-want
else
  bad filter-excludes-unselected-from-group-and-want
fi

# Case 12: platform -> agent id mapping, one platform at a time
printf '[{"name":"a","repo":"o/r","description":"d"}]\n' > "$TMP/one.jsonc"
for pair in claude:claude-code codex:codex opencode:opencode antigravity:antigravity-cli; do
  run_plan "$TMP/one.jsonc" "$FAKE" "${pair%%:*}"
  if [[ "$RC" -eq 0 && "$OUT" == *"group${TAB}o/r${TAB}${pair##*:}${TAB}a"* ]]; then
    pass "agent-id-${pair%%:*}"
  else
    bad "agent-id-${pair%%:*}"
    printf '  rc=%s\n  actual: %s\n  stderr: %s\n' "$RC" "$OUT" "$ERR" >&2
  fi
done

# Case 13: grouping by repo + agent set, groups ordered by first appearance;
# same repo with different platforms splits into two groups (o/r1 and o/r2
# each appear twice); the full output also pins record order group/want/known
# and that want follows platform order, not selection order.
run_plan "$TMP/main.jsonc" "$FAKE" claude codex
expect_out group-want-known-claude-codex \
"group${TAB}o/r1${TAB}claude-code codex${TAB}alpha eps
group${TAB}o/r2${TAB}codex${TAB}beta
group${TAB}o/r1${TAB}claude-code${TAB}gamma
group${TAB}o/r2${TAB}claude-code${TAB}delta
want${TAB}claude${TAB}alpha
want${TAB}codex${TAB}alpha
want${TAB}codex${TAB}beta
want${TAB}claude${TAB}gamma
want${TAB}claude${TAB}delta
want${TAB}claude${TAB}eps
want${TAB}codex${TAB}eps
known${TAB}alpha${TAB}claude codex opencode antigravity
known${TAB}beta${TAB}codex
known${TAB}gamma${TAB}claude
known${TAB}delta${TAB}claude opencode
known${TAB}eps${TAB}claude codex opencode antigravity"

# Case 14: group order follows first appearance (not alphabetical), agent ids
# follow the fixed order and platform args are de-duplicated / order-free.
cat > "$TMP/order.jsonc" <<'EOF'
[
  {"name":"z1","repo":"z/z","description":"d"},
  {"name":"a1","repo":"a/a","description":"d"},
  {"name":"z2","repo":"z/z","description":"d"},
  {"name":"m1","repo":"m/m","description":"d","platforms":["antigravity"]}
]
EOF
run_plan "$TMP/order.jsonc" "$FAKE" antigravity opencode codex claude claude
expect_out group-order-first-appearance \
"group${TAB}z/z${TAB}${ALL4}${TAB}z1 z2
group${TAB}a/a${TAB}${ALL4}${TAB}a1
group${TAB}m/m${TAB}antigravity-cli${TAB}m1
want${TAB}claude${TAB}z1
want${TAB}codex${TAB}z1
want${TAB}opencode${TAB}z1
want${TAB}antigravity${TAB}z1
want${TAB}claude${TAB}a1
want${TAB}codex${TAB}a1
want${TAB}opencode${TAB}a1
want${TAB}antigravity${TAB}a1
want${TAB}claude${TAB}z2
want${TAB}codex${TAB}z2
want${TAB}opencode${TAB}z2
want${TAB}antigravity${TAB}z2
want${TAB}antigravity${TAB}m1
known${TAB}z1${TAB}claude codex opencode antigravity
known${TAB}a1${TAB}claude codex opencode antigravity
known${TAB}z2${TAB}claude codex opencode antigravity
known${TAB}m1${TAB}antigravity"

# Case 15: want records contain only selected platforms
run_plan "$TMP/main.jsonc" "$FAKE" opencode
expect_out want-only-selected-platforms \
"group${TAB}o/r1${TAB}opencode${TAB}alpha eps
group${TAB}o/r2${TAB}opencode${TAB}delta
want${TAB}opencode${TAB}alpha
want${TAB}opencode${TAB}delta
want${TAB}opencode${TAB}eps
known${TAB}alpha${TAB}claude codex opencode antigravity
known${TAB}beta${TAB}codex
known${TAB}gamma${TAB}claude
known${TAB}delta${TAB}claude opencode
known${TAB}eps${TAB}claude codex opencode antigravity"

# Case 16: known covers the whole list even when the selection matches nothing
# for an entry; unset platforms list all four; duplicates collapse, fixed order.
run_plan "$TMP/main.jsonc" "$FAKE" antigravity
expect_out known-covers-unselected \
"group${TAB}o/r1${TAB}antigravity-cli${TAB}alpha eps
want${TAB}antigravity${TAB}alpha
want${TAB}antigravity${TAB}eps
known${TAB}alpha${TAB}claude codex opencode antigravity
known${TAB}beta${TAB}codex
known${TAB}gamma${TAB}claude
known${TAB}delta${TAB}claude opencode
known${TAB}eps${TAB}claude codex opencode antigravity"

# Case 17: real manifest, all four platforms -> exit 0 and 7 group records
run_plan "$REAL_LIST" "$REPO" claude codex opencode antigravity
real_groups="$(grep -c '^group'"${TAB}" <<< "$OUT" || true)"
if [[ "$RC" -eq 0 && "$real_groups" -eq 7 ]]; then
  pass real-list-seven-groups
else
  bad real-list-seven-groups
  printf '  rc=%s groups=%s\n  stderr: %s\n' "$RC" "$real_groups" "$ERR" >&2
fi
if [[ "$OUT" == *"group${TAB}amElnagdy/delegate-skills${TAB}claude-code${TAB}codex-delegate agy-delegate opencode-delegate"* ]]; then
  pass real-list-delegate-claude-only
else
  bad real-list-delegate-claude-only
fi

# Case 18: herdr pin. Runs its own plan so it does not depend on Case 17.
# Every entry is selected under all four platforms, so the
# group records list every entry; herdrdev/herdr must have exactly one entry
# (the pinned "herdr"), never the repo-wide install. Judged from plan output,
# not by text-matching the jsonc.
run_plan "$REAL_LIST" "$REPO" claude codex opencode antigravity
herdr_groups="$(grep -c "^group${TAB}herdrdev/herdr${TAB}" <<< "$OUT" || true)"
herdr_skills="$(awk -F'\t' '$1=="group" && $2=="herdrdev/herdr" {print $4}' <<< "$OUT")"
if [[ "$RC" -eq 0 && "$herdr_groups" -eq 1 && "$herdr_skills" == "herdr" ]]; then
  pass herdr-pinned-to-single-skill
else
  bad herdr-pinned-to-single-skill
  printf '  rc=%s groups=%s skills=[%s]\n' "$RC" "$herdr_groups" "$herdr_skills" >&2
fi

exit $fail
