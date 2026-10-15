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

STUB_DIR="$T/stub-bin"
STUB_NPX="$STUB_DIR/npx"
BASE_PATH="$PATH"

# ---------------------------------------------------------------------------
# npx stub: imitates `npx --yes skills add|remove ...` of the skills CLI.
# Logs every call (full argv on one line) to $NPX_STUB_LOG.
# ---------------------------------------------------------------------------
write_npx_stub() {
  mkdir -p "$STUB_DIR"
  cat > "$STUB_NPX" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
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
  python3 - "$lock" "$@" <<'PY'
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
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -q -m fixture
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
  unset NPX_STUB_FAIL_REPO NPX_STUB_SKIP_SKILL
  mkdir -p "$HOME/.codex" "$HOME/.gemini" "$HOME/.config/opencode"
  export NPX_STUB_LOG="$CASE/npx.log"
  : > "$NPX_STUB_LOG"
  CLAUDE_SKILLS="$HOME/.claude/skills"
  AGENTS_SKILLS="$HOME/.agents/skills"
  LOCK="$HOME/.agents/.skill-lock.json"
  RUN_PATH="$STUB_DIR:$BASE_PATH"
  EXPECT_NPX="$STUB_NPX"
}

# Safety guard: abort the whole suite if HOME ever escapes $T.
assert_home_in_t() {
  if [[ "$HOME" != "$T"/* ]]; then
    printf 'FATAL HOME=%s is not under %s - aborting\n' "$HOME" "$T" >&2
    exit 1
  fi
}

# Shadow guard: under RUN_PATH, `npx` must resolve to EXPECT_NPX (the stub),
# or to nothing at all when EXPECT_NPX is empty (missing-npx sandbox).
npx_shadowed() {
  local got
  got="$(PATH="$RUN_PATH" command -v npx || true)"
  [[ "$got" == "$EXPECT_NPX" ]] && return 0
  printf '  npx resolves to [%s], expected [%s] - sync not run\n' "$got" "$EXPECT_NPX" >&2
  return 1
}

# run_sync <mode> <case name> <repo> <args...>: run the fixture's sync script.
#   mode plain   stdin from /dev/null, controlling terminal inherited
#   mode tty:X   pseudo terminal via script(1), X + newline typed into it
#   mode notty   new session via setsid, so /dev/tty cannot be opened
# Sets OUT (combined output) and RC. Returns 1 (case marked failed) when the
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
      OUT="$(PATH="$RUN_PATH" "$repo/sync-external-skills.sh" "$@" 2>&1 < /dev/null)" || RC=$?
      ;;
    tty:*)
      printf -v cmd '%q ' "$repo/sync-external-skills.sh" "$@"
      OUT="$(printf '%s\n' "${mode#tty:}" | PATH="$RUN_PATH" SHELL=/usr/bin/bash script -qec "$cmd" /dev/null 2>&1)" || RC=$?
      ;;
    notty)
      OUT="$(PATH="$RUN_PATH" setsid -w "$repo/sync-external-skills.sh" "$@" 2>&1 < /dev/null)" || RC=$?
      ;;
  esac
  return 0
}

# snapshot: every path under HOME with type and symlink target, plus the lock.
snapshot() {
  find "$HOME" -printf '%p %y %l\n' | LC_ALL=C sort
  [[ -n "${XDG_STATE_HOME:-}" ]] && cat "$XDG_STATE_HOME/skills/.skill-lock.json" 2>/dev/null
  return 0
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

# ---- remove: lock-only skill not in manifest, removed on all platforms ----------
new_case remove
mkdir -p "$CLAUDE_SKILLS/stale" "$AGENTS_SKILLS/stale"
printf '{"version": 3, "skills": {"stale": {"source": "o/old"}}}' > "$LOCK"
if run_sync plain remove "$FX" --claude --no-confirm; then
  check remove-exit0 test "$RC" -eq 0
  check remove-preview has '將移除（所有平台）: stale'
  check remove-one-call test "$(log_count 'skills remove')" -eq 1
  check remove-gone-claude absent "$CLAUDE_SKILLS/stale"
  check remove-gone-agents absent "$AGENTS_SKILLS/stale"
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

exit "$fail"
