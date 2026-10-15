#!/usr/bin/env bash
# Tests for sync-external-skills.sh.
# Every case runs the copy of the script inside a throwaway fixture git repo,
# with HOME inside the temp dir $T and `npx` shadowed by a stub that imitates
# the skills CLI. No network, no real HOME, no real npx.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# git never reads or writes the real global/system config; HOME is moved under
# $T before the first fixture repo is built.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HOME="$T/fixture-home"
mkdir -p "$HOME"

STUB_DIR="$T/stub-bin"
STUB_NPX="$STUB_DIR/npx"
BASE_PATH="$PATH"

# ---------------------------------------------------------------------------
# npx stub: imitates `npx --yes skills add|remove ...` of the skills CLI.
# Its remove only clears the claude dir, ~/.agents/skills and the lock (what
# the sync script verifies); the real CLI also clears the same name from every
# other agent skills directory it knows about.
# Logs every call (full argv on one line) to $NPX_STUB_LOG.
# ---------------------------------------------------------------------------
write_npx_stub() {
  mkdir -p "$STUB_DIR"
  cat > "$STUB_NPX" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(readlink /proc/self/fd/0)" != /dev/null ]]; then
  printf 'STDIN_NOT_DEVNULL\n' >> "${NPX_STUB_LOG:?}"
  exit 96
fi
printf '%s\n' "$*" >> "${NPX_STUB_LOG:?}"
[[ "${1-}" == --yes && "${2-}" == skills && $# -ge 3 ]] || exit 98
sub="$3"
shift 3
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
agents_dir="$HOME/.agents/skills"
if [[ -n "${XDG_STATE_HOME:-}" ]]; then
  lock="$XDG_STATE_HOME/skills/.skill-lock.json"
else
  lock="$HOME/.agents/.skill-lock.json"
fi

# lock_edit <add|remove> <source> <name...>: update the lock's skills object.
lock_edit() {
  python3 -I - "$lock" "$@" <<'PY'
import json, os, sys
path, op, source, *names = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"version": 3, "skills": {}}
skills = data.setdefault("skills", {})
for name in names:
    if op == "add":
        skills[name] = {"source": source}
    else:
        skills.pop(name, None)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
PY
}

# take_values: collect args up to the next one starting with '-' into VALUES,
# leaving the rest in REST. Empty-array expansions below use the
# ${a[@]+"${a[@]}"} form because bash < 4.4 treats "${a[@]}" of an empty
# array as unbound under set -u.
take_values() {
  VALUES=()
  while (($#)) && [[ "$1" != -* ]]; do VALUES+=("$1"); shift; done
  REST=("$@")
}

case "$sub" in
  add)
    (($#)) || exit 98
    repo="$1"; shift
    [[ "${1-}" == -s ]] || exit 98
    shift
    take_values "$@"; skills=(${VALUES[@]+"${VALUES[@]}"}); set -- ${REST[@]+"${REST[@]}"}
    ((${#skills[@]})) || exit 98
    [[ "${1-}" == -a ]] || exit 98
    shift
    take_values "$@"; agents=(${VALUES[@]+"${VALUES[@]}"}); set -- ${REST[@]+"${REST[@]}"}
    ((${#agents[@]})) || exit 98
    [[ "$*" == "-g -y" ]] || exit 98
    if [[ "${NPX_STUB_FAIL_REPO:-}" == "$repo" ]]; then
      printf 'stub: simulated failure for %s\n' "$repo"
      exit 1
    fi
    universal=0 claude=0
    for a in "${agents[@]}"; do
      case "$a" in
        codex|opencode|antigravity-cli) universal=1 ;;
        claude-code) claude=1 ;;
      esac
    done
    added=()
    for name in "${skills[@]}"; do
      [[ "$name" == "${NPX_STUB_SKIP_SKILL:-}" ]] && continue
      if ((universal)); then
        mkdir -p "$agents_dir/$name"
        printf '# %s\n' "$name" > "$agents_dir/$name/SKILL.md"
        if ((claude)); then
          mkdir -p "$claude_dir"
          rm -rf "${claude_dir:?}/$name"
          ln -s "$(realpath -m --relative-to="$claude_dir" "$agents_dir/$name")" "$claude_dir/$name"
        fi
      elif ((claude)); then
        mkdir -p "$claude_dir/$name"
        printf '# %s\n' "$name" > "$claude_dir/$name/SKILL.md"
      fi
      added+=("$name")
      printf 'installed %s\n' "$name"
    done
    ((${#added[@]})) && lock_edit add "$repo" "${added[@]}"
    exit 0
    ;;
  remove)
    for a in "$@"; do
      if [[ "$a" == -a || "$a" == --agent ]]; then
        printf 'REMOVE_WITH_AGENT_FLAG\n' >> "$NPX_STUB_LOG"
        exit 97
      fi
    done
    take_values "$@"; names=(${VALUES[@]+"${VALUES[@]}"}); set -- ${REST[@]+"${REST[@]}"}
    ((${#names[@]})) || exit 98
    [[ "$*" == "-g -y" ]] || exit 98
    if [[ -n "${NPX_STUB_FAIL_REMOVE:-}" ]]; then
      printf 'stub: simulated remove failure\n'
      exit 1
    fi
    for name in "${names[@]}"; do
      rm -rf "${claude_dir:?}/$name" "${agents_dir:?}/$name"
      printf 'removed %s\n' "$name"
    done
    lock_edit remove - "${names[@]}"
    exit 0
    ;;
  *) exit 98 ;;
esac
STUB
  chmod +x "$STUB_NPX"
}

# ---------------------------------------------------------------------------
# Fixture repo: a throwaway git repo holding copies of the sync script and the
# plan script plus the given manifest, so each case controls the manifest.
# ---------------------------------------------------------------------------
make_fixture_repo() {
  local dir="$1" jsonc="$2"
  mkdir -p "$dir/scripts" "$dir/skills/local-skill"
  cp "$REPO/sync-external-skills.sh" "$dir/sync-external-skills.sh"
  cp "$REPO/scripts/external-skills-plan.py" "$dir/scripts/external-skills-plan.py"
  printf '%s\n' "$jsonc" > "$dir/external-skills.jsonc"
  printf '# local-skill\n' > "$dir/skills/local-skill/SKILL.md"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m fixture
}

# add_fixture_worktree <repo> <worktree path>: detached worktree of a fixture.
add_fixture_worktree() {
  git -C "$1" worktree add -q --detach "$2"
}

SMALL_JSONC='[
  {"name": "alpha", "repo": "o/r1", "description": "a"},
  {"name": "beta", "repo": "o/r1", "description": "b"},
  {"name": "teach", "repo": "o/r1", "description": "t"},
  {"name": "gamma", "repo": "https://github.com/o/r2/tree/main/x", "description": "g"},
  {"name": "solo", "repo": "o/r3", "description": "s", "platforms": ["claude"]}
]'
SMALL_GROUPS=3

# ---------------------------------------------------------------------------
# Per-case environment
# ---------------------------------------------------------------------------
# new_case <name>: fresh HOME under $T, cleared config env vars, empty npx log.
new_case() {
  CASE="$T/cases/$1"
  mkdir -p "$CASE"
  export HOME="$CASE/home"
  unset CLAUDE_CONFIG_DIR XDG_STATE_HOME XDG_CONFIG_HOME GEMINI_HOME AGENTS_HOME
  unset NPX_STUB_FAIL_REPO NPX_STUB_SKIP_SKILL NPX_STUB_FAIL_REMOVE
  mkdir -p "$HOME/.codex" "$HOME/.gemini" "$HOME/.config/opencode"
  export NPX_STUB_LOG="$CASE/npx.log"
  : > "$NPX_STUB_LOG"
  CLAUDE_SKILLS="$HOME/.claude/skills"
  AGENTS_SKILLS="$HOME/.agents/skills"
  LOCK="$HOME/.agents/.skill-lock.json"
  BRIDGE="$HOME/.gemini/config/skills"
  OLD_AG="$HOME/.gemini/antigravity-cli/skills"
  CODEX_OLD="$HOME/.codex/skills"
  RUN_PATH="$STUB_DIR:$BASE_PATH"
  EXPECT_NPX="$STUB_NPX"
  EXPECT_PYTHON3=""
  RUN_CWD="$CASE"
}

# Safety guard: abort the whole suite if HOME ever escapes $T.
assert_home_in_t() {
  if [[ "$HOME" != "$T"/* ]]; then
    printf 'FATAL HOME=%s is not under %s - aborting\n' "$HOME" "$T" >&2
    exit 1
  fi
}

# Shadow guard: under RUN_PATH, `npx` must resolve to EXPECT_NPX (the stub),
# or to nothing at all when EXPECT_NPX is empty (missing-npx sandbox). When a
# case shadows python3 too, EXPECT_PYTHON3 names the wrapper it must resolve to.
npx_shadowed() {
  local got
  got="$(PATH="$RUN_PATH" command -v npx || true)"
  if [[ "$got" != "$EXPECT_NPX" ]]; then
    printf '  npx resolves to [%s], expected [%s] - sync not run\n' "$got" "$EXPECT_NPX" >&2
    return 1
  fi
  [[ -n "$EXPECT_PYTHON3" ]] || return 0
  got="$(PATH="$RUN_PATH" command -v python3 || true)"
  [[ "$got" == "$EXPECT_PYTHON3" ]] && return 0
  printf '  python3 resolves to [%s], expected [%s] - sync not run\n' "$got" "$EXPECT_PYTHON3" >&2
  return 1
}

# write_python3_wrapper <dir>: python3 that fails silently (reads stdin, no
# output, exit 3) for the lock-reading call form `python3 -I - ...`, and runs
# the real python3 for every other call.
write_python3_wrapper() {
  local real
  real="$(PATH="$BASE_PATH" command -v python3)"
  mkdir -p "$1"
  cat > "$1/python3" <<WRAP
#!/usr/bin/env bash
if [[ "\${1-}" == -I && "\${2-}" == - ]]; then
  cat > /dev/null
  exit 3
fi
exec '$real' "\$@"
WRAP
  chmod +x "$1/python3"
}

# run_sync <mode> <case name> <repo> <args...>: run the fixture's sync script.
#   mode plain   stdin from /dev/null, controlling terminal inherited
#   mode tty:X   pseudo terminal via script(1), X + newline typed into it
#   mode notty   new session via setsid, so /dev/tty cannot be opened
# Runs from RUN_CWD. Sets OUT (combined output) and RC. Returns 1 (case marked failed) when the
# shadow guard refuses to run.
OUT="" RC=0
run_sync() {
  local mode="$1" name="$2" repo="$3" cmd
  shift 3
  assert_home_in_t
  if ! npx_shadowed; then
    bad "$name-npx-shadow"
    OUT="" RC=255
    return 1
  fi
  RC=0
  case "$mode" in
    plain)
      OUT="$(cd "$RUN_CWD" && PATH="$RUN_PATH" "$repo/sync-external-skills.sh" "$@" 2>&1 < /dev/null)" || RC=$?
      ;;
    tty:*)
      printf -v cmd '%q ' "$repo/sync-external-skills.sh" "$@"
      OUT="$(cd "$RUN_CWD" && printf '%s\n' "${mode#tty:}" | PATH="$RUN_PATH" SHELL=/usr/bin/bash script -qec "$cmd" /dev/null 2>&1)" || RC=$?
      ;;
    notty)
      OUT="$(cd "$RUN_CWD" && PATH="$RUN_PATH" setsid -w "$repo/sync-external-skills.sh" "$@" 2>&1 < /dev/null)" || RC=$?
      ;;
  esac
  return 0
}

# snapshot: every path under HOME with type and symlink target, plus the
# lock content (lock path resolved by the same rule as the script), or a fixed
# marker when there is no lock file.
snapshot() {
  local lock="$HOME/.agents/.skill-lock.json"
  [[ -z "${XDG_STATE_HOME:-}" ]] || lock="$XDG_STATE_HOME/skills/.skill-lock.json"
  find "$HOME" -printf '%p %y %l\n' | LC_ALL=C sort
  if [[ -f "$lock" ]]; then
    printf '== lock %s\n' "$lock"
    cat "$lock"
  else
    printf '== no lock file at %s\n' "$lock"
  fi
}

# sandbox_without <tool...>: PATH dir with every /usr/bin entry except tools.
sandbox_without() {
  local dir tool
  dir="$T/sandbox-$(printf '%s-' "$@")"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    ln -s /usr/bin/* "$dir"/
    for tool in "$@"; do rm -f "${dir:?}/$tool"; done
  fi
  printf '%s' "$dir"
}

# Assertion helpers on OUT / RC / the npx log. The predicates are only called
# through check's "${@:2}" dispatch, which shellcheck cannot follow.
# shellcheck disable=SC2329  # invoked indirectly via check
{
  has()      { [[ "$OUT" == *"$1"* ]]; }
  lacks()    { [[ "$OUT" != *"$1"* ]]; }
  not()      { ! "$@"; }
  absent()   { [[ ! -e "$1" && ! -L "$1" ]]; }
  real_dir() { [[ -d "$1" && ! -L "$1" ]]; }
  link_is()  { [[ -L "$1" && "$(readlink -- "$1")" == "$2" ]]; }
}
log_count() { grep -c -- "$1" "$NPX_STUB_LOG" || true; }
check()    { if "${@:2}"; then pass "$1"; else bad "$1"; printf '  rc=%s output:\n%s\n' "$RC" "$OUT" >&2; fi; }

write_npx_stub

FX="$T/fx-small"
make_fixture_repo "$FX" "$SMALL_JSONC"

# ---- usage ------------------------------------------------------------------
new_case usage
if run_sync plain usage-none "$FX"; then
  check usage-no-platform-exit2 test "$RC" -eq 2
  check usage-no-platform-usage has 'Usage:'
fi
if run_sync plain usage-unknown "$FX" --claude --bogus; then
  check usage-unknown-exit2 test "$RC" -eq 2
  check usage-unknown-message has '--bogus'
  check usage-unknown-usage has 'Usage:'
fi
for flag in -h --help; do
  if run_sync plain "usage$flag" "$FX" "$flag"; then
    check "usage$flag-exit0" test "$RC" -eq 0
    check "usage$flag-usage" has 'Usage:'
  fi
done

# ---- missing tools --------------------------------------------------------------
new_case no-npx
RUN_PATH="$(sandbox_without npx)"
EXPECT_NPX=""
if run_sync plain no-npx "$FX" --all --no-confirm; then
  check no-npx-exit test "$RC" -ne 0
  check no-npx-message has 'npx'
  check no-npx-no-call test ! -s "$NPX_STUB_LOG"
fi

new_case no-python3
# Real npx is left out too, so the only npx reachable is the stub.
RUN_PATH="$STUB_DIR:$(sandbox_without python3 npx)"
if run_sync plain no-python3 "$FX" --all --no-confirm; then
  check no-python3-exit test "$RC" -ne 0
  check no-python3-message has 'python3'
  check no-python3-no-call test ! -s "$NPX_STUB_LOG"
fi

# ---- malformed manifest -----------------------------------------------------------
new_case bad-manifest
FX_BAD="$T/fx-bad"
make_fixture_repo "$FX_BAD" '[ {"name": "alpha", "repo": "o/r1", "description": "a"}, ]'
before="$(snapshot)"
if run_sync plain bad-manifest "$FX_BAD" --all --no-confirm; then
  check bad-manifest-exit test "$RC" -ne 0
  check bad-manifest-reason has 'error: external-skills.jsonc: invalid JSON at line'
  check bad-manifest-summary has 'ERROR  external skills sync failed (1 problems):'
  check bad-manifest-no-call test ! -s "$NPX_STUB_LOG"
  check bad-manifest-unchanged test "$before" == "$(snapshot)"
fi

# ---- lock problems are precheck failures ----------------------------------------
new_case lock-unparseable
mkdir -p "$HOME/.agents"
printf '{ not json' > "$LOCK"
before="$(snapshot)"
if run_sync plain lock-unparseable "$FX" --all --no-confirm; then
  check lock-unparseable-exit test "$RC" -eq 1
  check lock-unparseable-message has '.skill-lock.json'
  check lock-unparseable-fixed-line has "  - cannot read lock file $LOCK (python3 exited 1)"
  check lock-unparseable-no-call test ! -s "$NPX_STUB_LOG"
  check lock-unparseable-unchanged test "$before" == "$(snapshot)"
fi

new_case lock-bad-name
mkdir -p "$HOME/.agents"
printf '{"version": 3, "skills": {"a*": {"source": "x"}, "b c": {"source": "x"}}}' > "$LOCK"
if run_sync plain lock-bad-name "$FX" --all --no-confirm; then
  check lock-bad-name-exit test "$RC" -eq 1
  check lock-bad-name-star has '"a*"'
  check lock-bad-name-space has '"b c"'
  check lock-bad-name-no-call test ! -s "$NPX_STUB_LOG"
fi

# S1: names the skills CLI would read as flags, or path-like names, are
# rejected before any change (allowed: ^[A-Za-z0-9][A-Za-z0-9._-]*$).
new_case lock-flag-names
mkdir -p "$CLAUDE_SKILLS/--all" "$CLAUDE_SKILLS/-a" "$HOME/.agents"
printf '{"version": 3, "skills": {"--all": {"source": "x"}, "-a": {"source": "x"}, "..": {"source": "x"}}}' > "$LOCK"
before="$(snapshot)"
if run_sync plain lock-flag-names "$FX" --claude --no-confirm; then
  check lock-flag-names-exit test "$RC" -eq 1
  check lock-flag-names-all has '"--all"'
  check lock-flag-names-a has '"-a"'
  check lock-flag-names-dotdot has '".."'
  check lock-flag-names-no-call test ! -s "$NPX_STUB_LOG"
  check lock-flag-names-unchanged test "$before" == "$(snapshot)"
fi

# S2: read_lock exits non-zero with empty stderr -> still one fixed problem.
new_case lock-silent-fail
write_python3_wrapper "$CASE/py-bin"
RUN_PATH="$CASE/py-bin:$STUB_DIR:$BASE_PATH"
EXPECT_PYTHON3="$CASE/py-bin/python3"
if run_sync plain lock-silent-fail "$FX" --claude --no-confirm; then
  check lock-silent-fail-exit1 test "$RC" -eq 1
  check lock-silent-fail-fixed-line has "cannot read lock file $LOCK (python3 exited 3)"
  check lock-silent-fail-no-call test ! -s "$NPX_STUB_LOG"
fi

# XDG_STATE_HOME moves the lock; an unparseable one there must be found.
new_case lock-xdg
export XDG_STATE_HOME="$CASE/state"
mkdir -p "$XDG_STATE_HOME/skills"
printf '[' > "$XDG_STATE_HOME/skills/.skill-lock.json"
if run_sync plain lock-xdg "$FX" --all --no-confirm; then
  check lock-xdg-exit test "$RC" -eq 1
  check lock-xdg-path has "$XDG_STATE_HOME/skills/.skill-lock.json"
fi

# ---- small manifest, all platforms: one add per group, preview, no prompt -------
new_case small-all
if run_sync plain small-all "$FX" --all --no-confirm; then
  check small-all-exit0 test "$RC" -eq 0
  check small-all-add-count test "$(log_count 'skills add')" -eq "$SMALL_GROUPS"
  check small-all-no-remove test "$(log_count 'skills remove')" -eq 0
  check preview-install-claude has '將安裝 [claude]: alpha beta teach gamma solo'
  check preview-install-codex has '將安裝 [codex]: alpha beta teach gamma'
  check preview-update-summary has '將更新 0 個既有 skill'
  check no-confirm-no-prompt lacks '[y/N]'
  check no-confirm-applied test -e "$CLAUDE_SKILLS/alpha"
  check small-all-agents-dir test -d "$AGENTS_SKILLS/gamma"
  check small-all-done-line has 'external skills sync complete'
fi

# ---- real manifest ---------------------------------------------------------------
new_case real-manifest
FX_REAL="$T/fx-real"
make_fixture_repo "$FX_REAL" "$(cat "$REPO/external-skills.jsonc")"
if run_sync plain real-manifest "$FX_REAL" --all --no-confirm; then
  check real-exit0 test "$RC" -eq 0
  check real-add-count test "$(log_count 'skills add')" -eq 6
  for d in codex-delegate agy-delegate opencode-delegate; do
    check "real-$d-claude-real-dir" real_dir "$CLAUDE_SKILLS/$d"
    check "real-$d-not-in-agents" absent "$AGENTS_SKILLS/$d"
  done
fi

# ---- remove: lock-only skill not in manifest, removed CLI-wide, not per platform
new_case remove
mkdir -p "$CLAUDE_SKILLS/stale" "$AGENTS_SKILLS/stale"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
if run_sync plain remove "$FX" --claude --no-confirm; then
  check remove-exit0 test "$RC" -eq 0
  check remove-preview has '將移除（所有平台）: stale'
  check remove-one-call test "$(log_count 'skills remove')" -eq 1
  check remove-gone-claude absent "$CLAUDE_SKILLS/stale"
  check remove-gone-agents absent "$AGENTS_SKILLS/stale"
  check remove-lock-exists test -f "$LOCK"
  check remove-gone-lock not grep -q '"stale"' "$LOCK"
fi

# A lock-only skill that is on no selected platform's location is left alone.
new_case remove-not-selected
mkdir -p "$AGENTS_SKILLS/stale"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
if run_sync plain remove-not-selected "$FX" --claude --no-confirm; then
  check remove-not-selected-exit0 test "$RC" -eq 0
  check remove-not-selected-no-call test "$(log_count 'skills remove')" -eq 0
  check remove-not-selected-kept test -d "$AGENTS_SKILLS/stale"
fi

# ---- confirmation prompt ----------------------------------------------------------
new_case answer-n
before="$(snapshot)"
if run_sync tty:n answer-n "$FX" --claude; then
  check answer-n-exit0 test "$RC" -eq 0
  check answer-n-prompt has '確定要執行嗎？[y/N]'
  check answer-n-cancelled has '已取消，未做任何變更。'
  check answer-n-unchanged test "$before" == "$(snapshot)"
  check answer-n-no-call test ! -s "$NPX_STUB_LOG"
fi

new_case answer-y
if run_sync tty:y answer-y "$FX" --claude; then
  check answer-y-exit0 test "$RC" -eq 0
  check answer-y-applied test -d "$CLAUDE_SKILLS/alpha"
  check answer-y-add-count test "$(log_count 'skills add')" -eq "$SMALL_GROUPS"
  check answer-y-stdin-devnull not grep -q STDIN_NOT_DEVNULL "$NPX_STUB_LOG"
fi

# S7: remove fails -> adds still run, verify reports stale still present.
new_case remove-fail
mkdir -p "$CLAUDE_SKILLS/stale" "$HOME/.agents"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
export NPX_STUB_FAIL_REMOVE=1
if run_sync plain remove-fail "$FX" --claude --no-confirm; then
  check remove-fail-exit1 test "$RC" -eq 1
  check remove-fail-problem has '  - remove stale: npx exited 1'
  check remove-fail-tail has '      stub: simulated remove failure'
  check remove-fail-adds-ran test "$(log_count 'skills add')" -eq "$SMALL_GROUPS"
  check remove-fail-verify-dir has 'verify: stale still present in ~/.claude/skills after remove'
  check remove-fail-verify-lock has 'verify: stale still recorded in ~/.agents/.skill-lock.json after remove'
fi

# S3: python3 runs isolated, so a json.py in the working directory is never
# imported (by the script or by the stub).
new_case python-isolated
mkdir -p "$CLAUDE_SKILLS/stale" "$HOME/.agents"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
printf '%s\n' 'import os' \
  'open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "IMPORTED"), "w").close()' \
  > "$CASE/json.py"
if run_sync plain python-isolated "$FX" --claude --no-confirm; then
  check python-isolated-exit0 test "$RC" -eq 0
  check python-isolated-not-imported test ! -e "$CASE/IMPORTED"
  check python-isolated-removed absent "$CLAUDE_SKILLS/stale"
fi

new_case no-tty
before="$(snapshot)"
if run_sync notty no-tty "$FX" --claude; then
  check no-tty-exit test "$RC" -ne 0
  check no-tty-hint has '--no-confirm'
  check no-tty-unchanged test "$before" == "$(snapshot)"
  check no-tty-no-call test ! -s "$NPX_STUB_LOG"
fi

# Second sync has only updates: it runs without a terminal and without asking.
new_case update-only
if run_sync plain update-only-first "$FX" --claude --no-confirm \
  && run_sync notty update-only "$FX" --claude; then
  check update-only-exit0 test "$RC" -eq 0
  check update-only-no-prompt lacks '[y/N]'
  check update-only-summary has '將更新 5 個既有 skill'
  check update-only-add-count test "$(log_count 'skills add')" -eq $((2 * SMALL_GROUPS))
fi

# ---- npx failure: other groups still run, verify still runs ---------------------
new_case npx-fail
export NPX_STUB_FAIL_REPO=o/r1
if run_sync plain npx-fail "$FX" --all --no-confirm; then
  check npx-fail-exit1 test "$RC" -eq 1
  check npx-fail-summary has 'ERROR  external skills sync failed ('
  check npx-fail-problem has '  - add o/r1 -> claude-code codex opencode antigravity-cli: npx exited 1'
  check npx-fail-tail has '      stub: simulated failure for o/r1'
  check npx-fail-r2-ran test "$(log_count 'skills add https://github.com/o/r2/tree/main/x ')" -eq 1
  check npx-fail-r3-ran test "$(log_count 'skills add o/r3 ')" -eq 1
  check npx-fail-verify-alpha has 'verify: alpha not found in ~/.claude/skills after install'
fi

# ---- stub skips a skill: verify reports it ----------------------------------------
new_case skip-skill
export NPX_STUB_SKIP_SKILL=gamma
if run_sync plain skip-skill "$FX" --codex --no-confirm; then
  check skip-skill-exit1 test "$RC" -eq 1
  check skip-skill-verify has '  - verify: gamma not found in ~/.agents/skills after install'
  check skip-skill-hint has '      (name misspelled in external-skills.jsonc, or removed upstream?)'
  check skip-skill-count has 'ERROR  external skills sync failed (1 problems):'
fi

# codex and opencode share ~/.agents/skills: a missing skill is reported once.
new_case verify-dedupe
export NPX_STUB_SKIP_SKILL=gamma
if run_sync plain verify-dedupe "$FX" --codex --opencode --no-confirm; then
  check verify-dedupe-once test "$(grep -c 'verify: gamma' <<< "$OUT")" -eq 1
fi

# ===========================================================================
# Symlink cleanup, dangling repo symlink replacement, Antigravity bridge,
# conflict and drift prechecks.
# ===========================================================================

# mkskill <dir>: a real skill directory with a SKILL.md.
mkskill() { mkdir -p "$1"; printf '# skill\n' > "$1/SKILL.md"; }

# ---- unmanaged items survive; repo symlinks (claude and bridge) are kept ----
new_case untouched
mkdir -p "$CLAUDE_SKILLS" "$BRIDGE"
ln -s "$FX/skills/local-skill" "$CLAUDE_SKILLS/local-skill"
mkskill "$CLAUDE_SKILLS/manual-dir"
mkskill "$CLAUDE_SKILLS/synced"
ln -s "$FX/skills/local-skill" "$BRIDGE/local-skill"
if run_sync plain untouched "$FX" --all --no-confirm; then
  check untouched-exit0 test "$RC" -eq 0
  check untouched-repo-link link_is "$CLAUDE_SKILLS/local-skill" "$FX/skills/local-skill"
  check untouched-manual-dir real_dir "$CLAUDE_SKILLS/manual-dir"
  check untouched-synced real_dir "$CLAUDE_SKILLS/synced"
  check untouched-bridge-repo-link link_is "$BRIDGE/local-skill" "$FX/skills/local-skill"
fi

# ---- alias symlink cleanup follows the selected platforms ---------------------
new_case alias
mkdir -p "$CLAUDE_SKILLS" "$AGENTS_SKILLS"
ln -s "$AGENTS_SKILLS/teach" "$AGENTS_SKILLS/teach-me"
ln -s ../../.agents/skills/teach-me "$CLAUDE_SKILLS/teach-me"
ln -s "$FX/skills/local-skill" "$CLAUDE_SKILLS/local-skill"
if run_sync plain alias-claude "$FX" --claude --no-confirm; then
  check alias-claude-exit0 test "$RC" -eq 0
  check alias-claude-preview has "將清除的 symlink: $CLAUDE_SKILLS/teach-me"
  check alias-claude-cleaned absent "$CLAUDE_SKILLS/teach-me"
  check alias-claude-agents-kept test -L "$AGENTS_SKILLS/teach-me"
  check alias-claude-repo-link-kept link_is "$CLAUDE_SKILLS/local-skill" "$FX/skills/local-skill"
fi
if run_sync plain alias-codex "$FX" --codex --no-confirm; then
  check alias-codex-exit0 test "$RC" -eq 0
  check alias-codex-cleaned absent "$AGENTS_SKILLS/teach-me"
  check alias-codex-repo-link-kept link_is "$CLAUDE_SKILLS/local-skill" "$FX/skills/local-skill"
fi

# ---- legacy dir ~/.codex/skills: scanned only when codex is selected ----------
# alpha and teach-me exist in ~/.agents/skills, so neither old link is
# dangling: teach-me goes only because codex does not want it.
new_case legacy
mkskill "$AGENTS_SKILLS/alpha"
mkskill "$AGENTS_SKILLS/teach-me"
mkdir -p "$CODEX_OLD"
ln -s "$AGENTS_SKILLS/teach-me" "$CODEX_OLD/teach-me"
ln -s "$AGENTS_SKILLS/alpha" "$CODEX_OLD/alpha"
if run_sync plain legacy-claude "$FX" --claude --no-confirm; then
  check legacy-claude-exit0 test "$RC" -eq 0
  check legacy-claude-teach-me-kept link_is "$CODEX_OLD/teach-me" "$AGENTS_SKILLS/teach-me"
  check legacy-claude-alpha-kept link_is "$CODEX_OLD/alpha" "$AGENTS_SKILLS/alpha"
fi
if run_sync plain legacy-codex "$FX" --codex --no-confirm; then
  check legacy-codex-exit0 test "$RC" -eq 0
  check legacy-codex-teach-me-cleaned absent "$CODEX_OLD/teach-me"
  check legacy-codex-alpha-kept link_is "$CODEX_OLD/alpha" "$AGENTS_SKILLS/alpha"
fi

# ---- same-name symlinks of a removed skill go everywhere ----------------------
new_case removed-links
mkskill "$AGENTS_SKILLS/stale"
mkskill "$CLAUDE_SKILLS/stale"
mkdir -p "$CODEX_OLD" "$BRIDGE"
ln -s "$AGENTS_SKILLS/stale" "$CODEX_OLD/stale"
ln -s "$AGENTS_SKILLS/stale" "$BRIDGE/stale"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
if run_sync plain removed-links "$FX" --claude --no-confirm; then
  check removed-links-exit0 test "$RC" -eq 0
  check removed-links-preview-codex has "將清除的 symlink: $CODEX_OLD/stale"
  check removed-links-preview-bridge has "將清除的 symlink: $BRIDGE/stale"
  check removed-links-agents absent "$AGENTS_SKILLS/stale"
  check removed-links-codex absent "$CODEX_OLD/stale"
  check removed-links-bridge absent "$BRIDGE/stale"
fi

# ---- dangling repo symlink with an expected name is replaced; others kept ----
new_case replace
mkdir -p "$BRIDGE" "$AGENTS_SKILLS"
ln -s "$FX/skills/alpha" "$BRIDGE/alpha"
ln -s "$FX/skills/synced" "$BRIDGE/synced"
ln -s "$FX/skills/synced" "$AGENTS_SKILLS/synced"
if run_sync plain replace "$FX" --antigravity --no-confirm; then
  check replace-exit0 test "$RC" -eq 0
  check replace-preview has "將替換失效的 repo symlink: $BRIDGE/alpha"
  check replace-bridge-alpha link_is "$BRIDGE/alpha" "$AGENTS_SKILLS/alpha"
  check replace-bridge-synced-kept link_is "$BRIDGE/synced" "$FX/skills/synced"
  check replace-agents-synced-kept link_is "$AGENTS_SKILLS/synced" "$FX/skills/synced"
fi

# ---- a link into a worktree copy counts as pointing into this repo ------------
new_case worktree-copy
WT="$T/fx-wt-bridge"
add_fixture_worktree "$FX" "$WT"
mkdir -p "$BRIDGE"
ln -s "$WT/skills/beta" "$BRIDGE/beta"
if run_sync plain worktree-copy "$FX" --antigravity --no-confirm; then
  check worktree-copy-exit0 test "$RC" -eq 0
  check worktree-copy-preview has "將替換失效的 repo symlink: $BRIDGE/beta"
  check worktree-copy-replaced link_is "$BRIDGE/beta" "$AGENTS_SKILLS/beta"
fi

# ---- bridge cleanup and rebuild ---------------------------------------------
new_case bridge
mkdir -p "$BRIDGE"
mkskill "$OLD_AG/gamma"
mkskill "$AGENTS_SKILLS/extra"
ln -s "$AGENTS_SKILLS/gone" "$BRIDGE/gone"
ln -s "$OLD_AG/gamma" "$BRIDGE/gamma"
ln -s "$AGENTS_SKILLS/extra" "$BRIDGE/extra"
if run_sync plain bridge "$FX" --antigravity --no-confirm; then
  check bridge-exit0 test "$RC" -eq 0
  check bridge-preview-gone has "將清除的 symlink: $BRIDGE/gone"
  check bridge-gone-cleaned absent "$BRIDGE/gone"
  check bridge-extra-cleaned absent "$BRIDGE/extra"
  check bridge-extra-target-kept real_dir "$AGENTS_SKILLS/extra"
  check bridge-gamma-repointed link_is "$BRIDGE/gamma" "$AGENTS_SKILLS/gamma"
  for n in alpha beta teach gamma; do
    check "bridge-$n-absolute" link_is "$BRIDGE/$n" "$AGENTS_SKILLS/$n"
  done
  check bridge-solo-not-bridged absent "$BRIDGE/solo"
fi
# Second run: bridge already correct, so only updates remain - no prompt.
if run_sync notty bridge-update-only "$FX" --antigravity; then
  check bridge-update-only-exit0 test "$RC" -eq 0
  check bridge-update-only-no-prompt lacks '[y/N]'
fi

# ---- bridge conflicts are precheck failures -----------------------------------
new_case bridge-real-dir
mkskill "$BRIDGE/alpha"
before="$(snapshot)"
if run_sync plain bridge-real-dir "$FX" --antigravity --no-confirm; then
  check bridge-real-dir-exit1 test "$RC" -eq 1
  check bridge-real-dir-names-path has "$BRIDGE/alpha"
  check bridge-real-dir-unchanged test "$before" == "$(snapshot)"
  check bridge-real-dir-no-call test ! -s "$NPX_STUB_LOG"
fi

new_case bridge-live-repo-link
mkdir -p "$BRIDGE"
ln -s "$FX/skills/local-skill" "$BRIDGE/alpha"
before="$(snapshot)"
if run_sync plain bridge-live-repo-link "$FX" --antigravity --no-confirm; then
  check bridge-live-repo-link-exit1 test "$RC" -eq 1
  check bridge-live-repo-link-names-path has "$BRIDGE/alpha"
  check bridge-live-repo-link-unchanged test "$before" == "$(snapshot)"
  check bridge-live-repo-link-no-call test ! -s "$NPX_STUB_LOG"
fi

# ---- lock name vs live repo symlink: conflict, and remove is never called -----
# (the lock-recorded name is a repo skill that install.sh linked; a remove
# would delete that link)
new_case lock-repo-conflict
mkdir -p "$CLAUDE_SKILLS" "$HOME/.agents"
ln -s "$FX/skills/local-skill" "$CLAUDE_SKILLS/local-skill"
printf '{"version": 3, "skills": {"local-skill": {"source": "o/x"}}}' > "$LOCK"
before="$(snapshot)"
if run_sync plain lock-repo-conflict "$FX" --claude --no-confirm; then
  check lock-repo-conflict-exit1 test "$RC" -eq 1
  check lock-repo-conflict-names-path has "$CLAUDE_SKILLS/local-skill"
  check lock-repo-conflict-unchanged test "$before" == "$(snapshot)"
  check lock-repo-conflict-no-remove test "$(log_count 'skills remove')" -eq 0
  check lock-repo-conflict-no-call test ! -s "$NPX_STUB_LOG"
  check lock-repo-conflict-link-kept link_is "$CLAUDE_SKILLS/local-skill" "$FX/skills/local-skill"
fi

# T1: the conflict check scans all five locations whatever is selected - the
# removal is CLI-wide and would delete the repo symlink in ~/.agents/skills.
new_case lock-repo-conflict-unselected
mkskill "$CLAUDE_SKILLS/local-skill"
mkdir -p "$AGENTS_SKILLS"
ln -s "$FX/skills/local-skill" "$AGENTS_SKILLS/local-skill"
printf '{"version": 3, "skills": {"local-skill": {"source": "o/x"}}}' > "$LOCK"
before="$(snapshot)"
if run_sync plain lock-repo-conflict-unselected "$FX" --claude --no-confirm; then
  check lock-repo-conflict-unselected-exit1 test "$RC" -eq 1
  check lock-repo-conflict-unselected-names-path has "$AGENTS_SKILLS/local-skill"
  check lock-repo-conflict-unselected-no-call test ! -s "$NPX_STUB_LOG"
  check lock-repo-conflict-unselected-unchanged test "$before" == "$(snapshot)"
fi

# T2: symlinks outside every cleanup rule's fence survive a full sync.
new_case fence
mkskill "$HOME/dev/mine"
mkskill "$HOME/dev/other"
mkskill "$HOME/.agents/skills-old/oldie"
mkdir -p "$CLAUDE_SKILLS" "$CODEX_OLD" "$BRIDGE"
ln -s "$HOME/dev/mine" "$CLAUDE_SKILLS/mine-link"
ln -s "$HOME/dev/mine" "$CODEX_OLD/mine-link"
ln -s "$HOME/dev/mine" "$BRIDGE/mine-link"
ln -s ../../.agents/skills-old/oldie "$CLAUDE_SKILLS/oldie"
mkskill "$CLAUDE_SKILLS/gone-skill"
ln -s "$HOME/dev/other" "$BRIDGE/gone-skill"
printf '{"version": 3, "skills": {"gone-skill": {"source": "o/old"}}}' > "$LOCK"
if run_sync plain fence "$FX" --all --no-confirm; then
  check fence-exit0 test "$RC" -eq 0
  check fence-removed has '將移除（所有平台）: gone-skill'
  check fence-no-cleanup-lines lacks '將清除的 symlink:'
  check fence-claude-mine link_is "$CLAUDE_SKILLS/mine-link" "$HOME/dev/mine"
  check fence-codex-mine link_is "$CODEX_OLD/mine-link" "$HOME/dev/mine"
  check fence-bridge-mine link_is "$BRIDGE/mine-link" "$HOME/dev/mine"
  check fence-claude-oldie link_is "$CLAUDE_SKILLS/oldie" ../../.agents/skills-old/oldie
  check fence-bridge-removed-name link_is "$BRIDGE/gone-skill" "$HOME/dev/other"
fi

# T3: replacement scope - claude dir yes, legacy dir no.
new_case replace-claude
mkdir -p "$CLAUDE_SKILLS"
ln -s "$FX/skills/alpha" "$CLAUDE_SKILLS/alpha"
if run_sync plain replace-claude "$FX" --claude --no-confirm; then
  check replace-claude-exit0 test "$RC" -eq 0
  check replace-claude-preview has "將替換失效的 repo symlink: $CLAUDE_SKILLS/alpha"
  check replace-claude-installed real_dir "$CLAUDE_SKILLS/alpha"
fi

new_case replace-legacy
mkdir -p "$CODEX_OLD"
ln -s "$FX/skills/alpha" "$CODEX_OLD/alpha"
if run_sync plain replace-legacy "$FX" --codex --no-confirm; then
  check replace-legacy-exit0 test "$RC" -eq 0
  check replace-legacy-no-replace lacks "將替換失效的 repo symlink: $CODEX_OLD/alpha"
  check replace-legacy-no-cleanup lacks "將清除的 symlink: $CODEX_OLD/alpha"
  check replace-legacy-kept link_is "$CODEX_OLD/alpha" "$FX/skills/alpha"
fi

# T4: a bridge link that cannot be replaced is reported, not swallowed.
# A 555 directory only blocks rm for non-root users (same guard as
# tests/test-migrate-claude-md-to-agents-md.sh), so root skips the case.
if [ "$(id -u)" -ne 0 ]; then
  new_case bridge-rm-fail
  mkskill "$HOME/elsewhere"
  mkdir -p "$BRIDGE"
  ln -s "$HOME/elsewhere" "$BRIDGE/alpha"
  chmod 555 "$BRIDGE"
  if run_sync plain bridge-rm-fail "$FX" --antigravity --no-confirm; then
    check bridge-rm-fail-exit1 test "$RC" -eq 1
    check bridge-rm-fail-problem has "  - bridge $BRIDGE/alpha: cannot replace the existing symlink"
  fi
  chmod 755 "$BRIDGE"
else
  printf 'SKIP bridge-rm-fail (running as root: a 555 directory does not block rm)\n'
fi

# ---- drift --------------------------------------------------------------------
new_case drift-agents
mkskill "$AGENTS_SKILLS/solo"
before="$(snapshot)"
if run_sync plain drift-agents "$FX" --codex --no-confirm; then
  check drift-agents-exit1 test "$RC" -eq 1
  check drift-agents-hint has 'npx skills remove solo -g -y'
  check drift-agents-unchanged test "$before" == "$(snapshot)"
  check drift-agents-no-call test ! -s "$NPX_STUB_LOG"
fi

new_case drift-claude
FX_DRIFT="$T/fx-drift"
make_fixture_repo "$FX_DRIFT" '[
  {"name": "alpha", "repo": "o/r1", "description": "a"},
  {"name": "cx", "repo": "o/r4", "description": "c", "platforms": ["codex"]}
]'
mkskill "$CLAUDE_SKILLS/cx"
before="$(snapshot)"
if run_sync plain drift-claude "$FX_DRIFT" --claude --no-confirm; then
  check drift-claude-exit1 test "$RC" -eq 1
  check drift-claude-hint has 'npx skills remove cx -g -y'
  check drift-claude-unchanged test "$before" == "$(snapshot)"
  check drift-claude-no-call test ! -s "$NPX_STUB_LOG"
fi

# ---- a failed group still gets bridge, cleanup and verify ---------------------
new_case group-fail
mkskill "$AGENTS_SKILLS/alpha"
mkdir -p "$CLAUDE_SKILLS"
ln -s ../../.agents/skills/teach-me "$CLAUDE_SKILLS/teach-me"
export NPX_STUB_FAIL_REPO=o/r1
if run_sync plain group-fail "$FX" --claude --antigravity --no-confirm; then
  check group-fail-exit1 test "$RC" -eq 1
  check group-fail-bridge-alpha link_is "$BRIDGE/alpha" "$AGENTS_SKILLS/alpha"
  check group-fail-alias-cleaned absent "$CLAUDE_SKILLS/teach-me"
  check group-fail-verify-beta has 'verify: beta not found in ~/.agents/skills after install'
  check group-fail-verify-bridge has 'verify: bridge ~/.gemini/config/skills/beta missing or unresolvable'
fi

# ---- path helpers (sourced, task 3 builds on them) -----------------------------
new_case helpers
mkdir -p "$HOME/a/b" "$HOME/target"
ln -s ../../target "$HOME/a/b/rel"
ln -s "$HOME/a/../gone" "$HOME/a/abs-dangling"
# Source the fixture copy in a subshell; its entry point is guarded, so only
# the definitions load.
# shellcheck disable=SC1091  # fixture copy of ../sync-external-skills.sh, linted on its own
helper() { (source "$FX/sync-external-skills.sh"; "$@"); }
check helper-target-relative test "$(helper link_target "$HOME/a/b/rel")" == "$HOME/target"
check helper-target-absolute test "$(helper link_target "$HOME/a/abs-dangling")" == "$HOME/gone"
check helper-not-dangling not helper is_dangling_link "$HOME/a/b/rel"
check helper-dangling helper is_dangling_link "$HOME/a/abs-dangling"
check helper-under-equal helper path_under "$HOME/target" "$HOME/a/../target/"
check helper-under-child helper path_under "$HOME/target/x" "$HOME/target"
check helper-under-prefix not helper path_under "$HOME/target2" "$HOME/target"

# ---- fixture worktree helper (used by later cases) ------------------------------
add_fixture_worktree "$FX" "$T/fx-small-wt"
check fixture-worktree test -x "$T/fx-small-wt/sync-external-skills.sh"

# ---- across every case: remove never carries -a ---------------------------------
ALL_LOGS="$T/all-npx.log"
cat "$T"/cases/*/npx.log > "$ALL_LOGS"
# shellcheck disable=SC2329  # invoked indirectly via check/not
remove_lines_have_agent_flag() { grep 'skills remove' "$ALL_LOGS" | grep -qE -- ' (-a|--agent)( |$)'; }
check remove-called-somewhere grep -q 'skills remove' "$ALL_LOGS"
check remove-no-agent-flag-marker not grep -q REMOVE_WITH_AGENT_FLAG "$ALL_LOGS"
check remove-lines-no-a not remove_lines_have_agent_flag
check npx-stdin-always-devnull not grep -q STDIN_NOT_DEVNULL "$ALL_LOGS"

exit "$fail"
