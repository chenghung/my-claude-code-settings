#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO/install-cli-tools.sh"
CLAUTH_ZSH="$REPO/platforms/claude/clauth.zsh"
SETTINGS_FILE="$REPO/platforms/claude/settings.json"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool opencode opencode-bin ' "$INSTALL_SH" && pass opencode-install-line || bad opencode-install-line

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool rg +ripgrep ' "$INSTALL_SH" && pass rg-install-line || bad rg-install-line

# go-yq is the only official-repo package that provides /usr/bin/yq. The repo
# also ships a same-named "yq" package (kislyuk's Python jq-wrapper for
# YAML/XML/TOML, a completely different tool) that provides the identical
# path, so a package-name typo here (go-yq -> yq) would silently install the
# wrong tool instead of failing loudly - an unanchored substring check would
# not catch that, since "yq" is a substring of "go-yq" too.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool yq +go-yq +' "$INSTALL_SH" && pass yq-install-line || bad yq-install-line

# trello-cli is the AUR package providing /usr/bin/trello. AUR also has a
# same-named "trello" package (an unofficial Electron desktop GUI, unrelated
# to the CLI), so a package-name typo here (trello-cli -> trello) would
# silently install the wrong, unrelated software instead of failing loudly.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool trello +trello-cli +' "$INSTALL_SH" && pass trello-install-line || bad trello-install-line

# hackmd-cli is the only tool in this script installed via a global npm
# install rather than pacman/yay/pipx, and @hackmd/hackmd-cli is the only
# scoped package name anywhere in the script. Anchored end-to-end (not just
# on the package name) so this fails on any of: a package-name typo or
# dropped scope, a reversion back to YAY_INSTALL/PACMAN_INSTALL, or the
# quoting being changed.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool hackmd-cli "@hackmd/hackmd-cli" "\$\{NPM_INSTALL\[@\]\}"$' "$INSTALL_SH" && pass hackmd-cli-npm-install-line || bad hackmd-cli-npm-install-line

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh' "$INSTALL_SH" && pass codegraph-install-line || bad codegraph-install-line

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'https://raw.githubusercontent.com/doggy8088/TokenUsageInsights/main/scripts/get.sh' "$INSTALL_SH" && pass token-usage-insights-install-line || bad token-usage-insights-install-line

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'bash -s -- --service' "$INSTALL_SH" && pass token-usage-insights-service-flag || bad token-usage-insights-service-flag

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'https://herdr.dev/install.sh' "$INSTALL_SH" && pass herdr-install-line || bad herdr-install-line
# Anchored to the real invocation line (not just the substring): three
# comment/echo lines in this file also contain the literal text "herdr
# update", so an unanchored grep -qF here would stay green even if the real
# `if ! herdr update; then` line were deleted outright.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^[[:space:]]*if ! herdr update; then' "$INSTALL_SH" && pass herdr-update-line || bad herdr-update-line
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'https://antigravity.google/cli/install.sh' "$INSTALL_SH" && pass agy-install-line || bad agy-install-line
# agy ships its own updater; the script must never drive an agy self-update.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^[[:space:]]*agy update' "$INSTALL_SH" && bad agy-no-self-update || pass agy-no-self-update

# clauth, like agy, ships its own updater and has no update/upgrade subcommand
# at all (confirmed by hand against `clauth help`'s subcommand list) - the
# script must never try to drive a clauth self-update, since there is no
# subcommand it even could drive.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'https://raw.githubusercontent.com/uwuclxdy/clauth/mommy/install.sh' "$INSTALL_SH" && pass clauth-install-line || bad clauth-install-line
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF 'bash -s -- --nocargo' "$INSTALL_SH" && pass clauth-nocargo-flag || bad clauth-nocargo-flag
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^[[:space:]]*clauth update' "$INSTALL_SH" && bad clauth-no-self-update || pass clauth-no-self-update

# Regression guard: `codegraph install` rewrites each agent's config file in
# place, swapping the symlink this repo's install.sh created for a real file.
# Checked against both scripts — install.sh is the one that does agent
# wiring and is the most likely place for this to accidentally get added —
# with comment-only lines and inline comments stripped first, so an English
# rewrite of the explanatory prose above can never flip this red by matching
# its own guard text.
strip_comments() {
  grep -vE '^[[:space:]]*#' "$1" | sed -E 's/[[:space:]]+#.*$//'
}
assert_no_codegraph_install() {
  local file="$1" label="$2" stripped
  # Capture via command substitution (not `grep -q` on the pipeline) so the
  # upstream strip_comments pipeline always runs to completion — piping
  # straight into `grep -q` lets it exit as soon as it matches, killing sed
  # with SIGPIPE (141) and, under `set -o pipefail`, flipping this guard's
  # pass/fail result on large files instead of reporting the real match.
  stripped="$(strip_comments "$file")"
  case "$stripped" in
  *'codegraph install'*) bad "no-codegraph-install-${label}" ;;
  *) pass "no-codegraph-install-${label}" ;;
  esac
}
assert_no_codegraph_install "$INSTALL_SH" install-cli-tools
assert_no_codegraph_install "$REPO/install.sh" install

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ------------------------------------------------------------
# The clauth section lives in platforms/claude/clauth.zsh (zsh-only: it uses
# zsh's `${${(%):-%x}:A:h}` to find its own directory), so everything below
# runs it under real zsh, not bash. zsh is therefore a hard prerequisite.
# ------------------------------------------------------------
if ! command -v zsh >/dev/null 2>&1; then
  bad zsh-available
  exit 1
fi
pass zsh-available

# ------------------------------------------------------------
# Dynamic check: every claude-launcher alias must, once actually run,
# invoke `clauth` (never `claude` directly, and never the old _ccp_launch
# config-dir wrapper — both retired in favor of clauth profiles) with the
# right profile name, `--settings <repo settings.json>` right after the `--`
# separator, and the right trailing claude args.
#
# Extraction: pull the literal "## aliases for claude code" section straight
# out of clauth.zsh (it runs to end of file) instead of retyping the expected
# alias bodies by hand. A hand-retyped copy would silently drift the next time
# an alias is edited in clauth.zsh without this test being touched, which is
# exactly the kind of gap this test exists to catch.
# ------------------------------------------------------------
ALIAS_SRC="$T/claude-aliases.sh"
awk '/^## aliases for claude code$/ { on = 1 } on' "$CLAUTH_ZSH" > "$ALIAS_SRC"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$ALIAS_SRC" && pass extract-claude-aliases || bad extract-claude-aliases
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
zsh -n "$CLAUTH_ZSH" && pass claude-aliases-syntax || bad claude-aliases-syntax

# ------------------------------------------------------------
# Isolation: `clauth` is a real, already-installed binary on this machine
# (multi-account Claude Code launcher). Run for real it would spawn an
# actual `claude` process, mirror ~/.claude into a per-run runtime dir, and
# touch ~/.clauth/ — none of which this test may cause. CLAUTH_BIN is
# prefixed onto PATH ahead of the real one so every alias below resolves to
# the stub instead.
# ------------------------------------------------------------
CLAUTH_BIN="$T/clauth-stub-bin"
mkdir -p "$CLAUTH_BIN"
# `status --json` (used by _clauth_smart_pick, exercised further down) prints
# a per-case fixture instead of logging; everything else (the `clauth start
# ...` every alias below ends in) logs argv like before.
cat > "$CLAUTH_BIN/clauth" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "status" ] && [ "$2" = "--json" ]; then
  cat "${CLAUTH_STATUS_FIXTURE:?}"
  exit 0
fi
printf '%s\n' "$*" > "${CLAUTH_STUB_LOG:?}"
# One argv element per line, so a test can tell "one argument containing
# spaces" apart from several arguments (the $* join above cannot).
printf '%s\n' "$@" > "${CLAUTH_STUB_LOG:?}.argv"
exit 0
STUB
chmod +x "$CLAUTH_BIN/clauth"
CLAUTH_TEST_PATH="$CLAUTH_BIN:$PATH"

# ------------------------------------------------------------
# Shadow guard. The required name(s) are derived mechanically from the
# extracted alias definitions themselves (each alias's leading command
# word), not hand-typed here — deliberately NOT derived from CLAUTH_BIN's
# own directory listing: enumerating "whatever files happen to exist in the
# stub dir" has a blind spot precisely in the failure mode this guard exists
# to catch — if the stub-creation step above is ever broken so that
# CLAUTH_BIN ends up empty, a dir-listing-based guard would have nothing to
# iterate over and would report a false pass, right as PATH resolution for
# "clauth" falls through to the real, already-installed binary on this
# machine. Sourced from the alias section's own required commands instead,
# so "clauth is required but not shadowed" is exactly what gets caught.
#
# Gating, not just reporting: on any mismatch this sets CLAUTH_SHADOW_OK=0,
# and the run_alias loop further down checks that flag before invoking
# anything — a guard that only records a FAIL and lets the dangerous section
# run anyway is not a guard, since this repo-wide pass/bad idiom never
# aborts the script on its own (that is what makes it safe to layer many
# cheap assertions in one file without one early failure hiding the rest).
#
# Fail-closed on extraction itself, not just on the names it produces: a
# `for name in "$@"` loop given zero names runs zero iterations, leaves
# all_ok at its initial value of 1, and reports a PASS — so if REQUIRED_CMDS
# ever ends up empty (extraction regex stops matching any alias line, e.g.
# every RHS quote style changes from single to double), the guard used to
# rubber-stamp a shadow it never actually checked, and run_alias below would
# have gone on to invoke the real, already-installed clauth on this machine.
# Two independent checks close that gap: the count of extracted leading
# command words is asserted equal to the count of alias definitions in
# ALIAS_SRC (catching partial extraction failures too, not only total ones),
# and assert_path_shadowed_by separately refuses to report a bare PASS when
# handed zero names, so neither the caller-side nor the callee-side check
# depends on the other for safety.
# ------------------------------------------------------------
ALIAS_DEFINITION_COUNT="$(grep -cE "^alias [a-zA-Z0-9_]+='" "$ALIAS_SRC" || true)"
REQUIRED_CMDS_RAW_COUNT="$(grep -oE "^alias [a-zA-Z0-9_]+='[a-zA-Z0-9_.-]+" "$ALIAS_SRC" | wc -l | tr -d '[:space:]' || true)"
REQUIRED_CMDS="$(grep -oE "^alias [a-zA-Z0-9_]+='[a-zA-Z0-9_.-]+" "$ALIAS_SRC" | sed -E "s/^alias [a-zA-Z0-9_]+='//" | sort -u || true)"
CLAUTH_SHADOW_OK=1
assert_path_shadowed_by() {
  local stub_dir="$1" test_path="$2" label="$3"
  shift 3
  if [ "$#" -eq 0 ]; then
    # Defense in depth: even if the caller-side extraction-count check below
    # is ever bypassed by a future edit, this function does not report a
    # PASS for a shadow check it was never actually asked to perform.
    bad "${label}-shadow-guard-no-names"
    CLAUTH_SHADOW_OK=0
    return
  fi
  local name resolved expected all_ok=1
  for name in "$@"; do
    expected="${stub_dir}/${name}"
    resolved="$(PATH="$test_path" command -v "$name" 2>/dev/null || true)"
    if [ "$resolved" != "$expected" ]; then
      bad "${label}-${name}-shadowed"
      all_ok=0
      CLAUTH_SHADOW_OK=0
    fi
  done
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  [ "$all_ok" -eq 1 ] && pass "${label}-shadow-guard" || true
}
if [ "$ALIAS_DEFINITION_COUNT" -eq 0 ] || [ "$REQUIRED_CMDS_RAW_COUNT" -ne "$ALIAS_DEFINITION_COUNT" ]; then
  bad claude-alias-required-cmds-extraction
  CLAUTH_SHADOW_OK=0
else
  # shellcheck disable=SC2086  # intentional word-splitting: REQUIRED_CMDS is a newline-separated list of bare command names
  assert_path_shadowed_by "$CLAUTH_BIN" "$CLAUTH_TEST_PATH" claude-alias $REQUIRED_CMDS
fi

# Computed once, the same way `clw`/`clpw` compute it when actually run, so
# the worktree-path assertions below can pattern-match against a value that
# is correct for wherever this checkout happens to live rather than a
# hand-typed guess.
EXPECTED_WT_BASENAME="$(basename "$(cd "$REPO" && git rev-parse --show-toplevel)")"

# run_alias <alias-name> [clauth.zsh path]: sources clauth.zsh (the whole
# file, not just the extracted section: _CLAUTH_SETTINGS_FILE is derived at
# source time from the file's own location) into a throwaway `zsh -fc`
# (-f: no user rc files), then runs the single named alias against the stub
# PATH, and prints whatever the stub `clauth` logged (empty if it was never
# invoked at all). The alias is invoked through `eval`: zsh parses the whole
# -c string before executing any of it, so a bare `$alias_name` on a later
# line would be parsed before `source` had defined the alias and fail with
# "command not found"; `eval` parses its argument only when it runs. The
# real settings.json path in the log is masked to @SETTINGS@ so the
# expectations below stay independent of where this checkout lives; the
# stub's one-arg-per-line log is left at "<log>.argv" for exact-argument
# assertions.
run_alias() {
  local alias_name="$1" zsh_file="${2:-$CLAUTH_ZSH}" log="$T/clauth-out-${1}.log" logged
  : > "$log"
  : > "${log}.argv"
  PATH="$CLAUTH_TEST_PATH" CLAUTH_STUB_LOG="$log" ZSH_FILE="$zsh_file" REPO_CD="$REPO" zsh -fc '
    cd "$REPO_CD" || exit 1
    source "$ZSH_FILE"
    eval '"$alias_name"' >/dev/null 2>&1
  ' || true  # a failed launch is reported by the assertions on its log, not by aborting under set -e
  logged="$(cat "$log" 2>/dev/null)"
  printf '%s' "${logged//"$SETTINGS_FILE"/@SETTINGS@}"
}

# Expected argv `clauth` receives for each alias, as an anchored ERE. The
# worktree/remote-control variants include the dynamic $(...) pieces
# (basename + timestamp) that the alias definitions evaluate at run time —
# they stay unexpanded text in clauth.zsh because they are alias bodies
# evaluated per invocation, not something this script could expand ahead of
# time. Every entry carries `--settings @SETTINGS@` immediately after `--`.
TS_RE='[0-9]{8}-[0-9]{6}'
declare -A EXPECTED=(
  [cl]="start onramplab -- --settings @SETTINGS@"
  [cla]="start onramplab -- --settings @SETTINGS@ --permission-mode auto"
  [clc]="start onramplab -- --settings @SETTINGS@ --permission-mode auto --continue"
  [clr]="start onramplab -- --settings @SETTINGS@ --permission-mode auto --resume"
  [clw]="start onramplab -- --settings @SETTINGS@ --permission-mode auto --worktree ${EXPECTED_WT_BASENAME}/wt/${TS_RE}"
  [clre]="start onramplab -- --settings @SETTINGS@ --permission-mode auto --remote-control --name remote-control-onr-notebook-${TS_RE}"
  [clp]="start personal -- --settings @SETTINGS@ --permission-mode auto"
  [clpc]="start personal -- --settings @SETTINGS@ --permission-mode auto --continue"
  [clpr]="start personal -- --settings @SETTINGS@ --permission-mode auto --resume"
  [clpw]="start personal -- --settings @SETTINGS@ --permission-mode auto --worktree ${EXPECTED_WT_BASENAME}/wt/${TS_RE}"
  [clpre]="start personal -- --settings @SETTINGS@ --permission-mode auto --remote-control --name remote-control-personal-notebook-${TS_RE}"
)

# settings_argv_ok <argv log>: the argument right after `--` is `--settings`
# and the one after that is exactly the repo settings.json path (compared
# as a whole line, so a path split on whitespace cannot pass).
settings_argv_ok() {
  awk -v s="$SETTINGS_FILE" '
    $0 == "--" && !d { d = NR; next }
    d && NR == d + 1 { a = ($0 == "--settings") }
    d && NR == d + 2 { b = ($0 == s) }
    END { exit !(a && b) }
  ' "$1"
}

if [ "$CLAUTH_SHADOW_OK" -eq 1 ]; then
  for alias_name in cl cla clc clr clw clre clp clpc clpr clpw clpre; do
    logged="$(run_alias "$alias_name")"
    if [[ "$logged" =~ ^${EXPECTED[$alias_name]}$ ]]; then
      pass "alias-${alias_name}-via-clauth"
    else
      bad "alias-${alias_name}-via-clauth"
      printf '     expected (ERE): %s\n     got:            %s\n' "${EXPECTED[$alias_name]}" "$logged" >&2
    fi
    # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
    settings_argv_ok "$T/clauth-out-${alias_name}.log.argv" && pass "alias-${alias_name}-settings-after-separator" || bad "alias-${alias_name}-settings-after-separator"
  done
else
  # The shadow guard above already failed and reported why; do not run a
  # single alias in that state; "clauth" (or whatever else the aliases
  # invoke) is not confirmed to resolve inside CLAUTH_BIN, so actually
  # running any of them here could reach a real, stateful binary instead of
  # the stub. Every alias check is marked failed without ever running one.
  for alias_name in cl cla clc clr clw clre clp clpc clpr clpw clpre; do
    bad "alias-${alias_name}-via-clauth"
    bad "alias-${alias_name}-settings-after-separator"
  done
fi

# ------------------------------------------------------------
# Case set 2: abduco is gone for good, the old _ccp_launch config-dir
# wrapper is gone for good, and every claude launcher alias routes through
# clauth rather than calling claude directly or through either retired
# mechanism.
# ------------------------------------------------------------
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qi 'abduco' "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-abduco-left || pass no-abduco-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q '_cc_launch' "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-cc-launch-left || pass no-cc-launch-left
# Anchored to an actual function definition (not just the substring):
# clauth.zsh's own alias-section comment names "_ccp_launch" by
# design, to explain what was removed and why — an unanchored grep -q here
# would stay red forever even with the function itself long gone.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^_ccp_launch\(\)' "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-ccp-launch-left || pass no-ccp-launch-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '.claude-personal' "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-claude-personal-dir-left || pass no-claude-personal-dir-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'CC_SESSION_TAG' "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-session-tag-left || pass no-session-tag-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q "^alias cll=" "$INSTALL_SH" "$CLAUTH_ZSH" && bad no-cll-alias || pass no-cll-alias

# The launch args every entry point must carry right after `--`: the repo's
# settings.json passed by variable (expanded and quoted at run time, so a
# path with spaces survives), as an ERE fragment for the static line checks.
# shellcheck disable=SC2016  # literal $ for the ERE: this must NOT expand
SETTINGS_REF_RE='-- --settings "\$_CLAUTH_SETTINGS_FILE"'
# Cheap static companion to the dynamic alias-via-clauth checks above: each
# alias's source line must literally start with `clauth start <profile>`, so
# a future edit that reverts an alias back to a bare `claude` call (or to
# the wrong profile) fails here even before the dynamic check runs.
for a in cl cla clc clr clw clre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}='clauth start onramplab ${SETTINGS_REF_RE}" "$CLAUTH_ZSH" && pass "alias-${a}-onramplab-line" || bad "alias-${a}-onramplab-line"
done

for a in clp clpc clpr clpw clpre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}='clauth start personal ${SETTINGS_REF_RE}" "$CLAUTH_ZSH" && pass "alias-${a}-personal-line" || bad "alias-${a}-personal-line"
done

# clauto (what the `claude` alias runs) launches clauth too, so it needs the
# same `-- --settings "$_CLAUTH_SETTINGS_FILE"` after the profile.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE "^clauto\(\) \{.*clauth start \"\\\$profile\" ${SETTINGS_REF_RE} " "$CLAUTH_ZSH" && pass clauto-settings-line || bad clauto-settings-line

# Regression guard: the managed-block sentinels must never change, or install
# leaves an orphaned block behind on the next run.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# >>> cli-tools aliases (managed) >>>' "$INSTALL_SH" && pass sentinel-begin-unchanged || bad sentinel-begin-unchanged
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# <<< cli-tools aliases (managed) <<<' "$INSTALL_SH" && pass sentinel-end-unchanged || bad sentinel-end-unchanged

# ------------------------------------------------------------
# Case set 3: _clauth_smart_pick's selection algorithm.
#
# Extraction: pull the literal `_clauth_smart_pick() { ... } / clauto() {
# ... } / alias claude='clauto'` trio straight out of clauth.zsh (anchored on
# the exact function-open and alias lines) to check it is still present and
# parses, instead of retyping the jq algorithm here - a hand-retyped copy
# would silently drift from the real algorithm. The behavioural cases below
# source the whole clauth.zsh (not just this trio) because clauto needs
# _CLAUTH_SETTINGS_FILE, which the file derives from its own location.
# ------------------------------------------------------------
SMART_PICK_SRC="$T/clauth-smart-pick.sh"
awk '/^_clauth_smart_pick\(\) \{$/,/^alias claude=.clauto.$/' "$CLAUTH_ZSH" > "$SMART_PICK_SRC"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$SMART_PICK_SRC" && pass extract-smart-pick || bad extract-smart-pick
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
zsh -n "$SMART_PICK_SRC" && pass smart-pick-syntax || bad smart-pick-syntax

# Shadow note: this section's only external command is `clauth` (called both
# by `_clauth_smart_pick`'s `clauth status --json` and by `clauto`'s `clauth
# start ...`), the exact same name the per-name shadow guard above already
# derived from the cl/cla/.../clpre aliases, proved, and gated
# CLAUTH_SHADOW_OK on - reused here as-is via the same $CLAUTH_BIN/clauth
# stub (already extended with a `status --json` branch, see its definition
# above) rather than re-deriving or re-proving a second copy of the same
# single-name list. `jq` is deliberately left unstubbed and unguarded: it is
# a pure, deterministic, side-effect-free text transform with no cost, no
# wall-clock dependency and no state outside the test, which is exactly the
# exemption the stub-guard requirement itself carves out.

# Fixed "now" instants from the brief, each labeled with its Taipei weekday
# and clock time so the per-case comments below can refer to them by name.
WED="$(date -u -d '2026-09-23T03:24:00Z' +%s)"         # Wed 11:24 Taipei
SAT="$(date -u -d '2026-09-26T03:00:00Z' +%s)"         # Sat 11:00 Taipei
WED1730="$(date -u -d '2026-09-23T09:30:00Z' +%s)"     # Wed 17:30 Taipei

# iso_at <base epoch> <hours offset, may be fractional> [date format]: builds
# a resets_at string in the same shape real `clauth status --json` output
# uses by default (fractional seconds + explicit +00:00), so the fixtures
# below exercise the same sub()-based parsing the picker runs against
# production data. The hour offsets used by every case in this suite
# multiply out to whole seconds. The optional 3rd arg overrides the date
# format, used by the plain-"Z"-suffix regression case further down.
iso_at() {
  local base="$1" hours="$2" fmt="${3:-%Y-%m-%dT%H:%M:%S.123456+00:00}" offset_sec
  offset_sec="$(awk -v h="$hours" 'BEGIN { printf "%d", h*3600 }')"
  date -u -d "@$((base + offset_sec))" +"$fmt"
}

# build_fixture <out file> <now epoch> <active profile> <onr w T r5 t5> <per w T r5 t5>
# Mirrors the real `clauth status --json` shape given in the brief, including
# a "7d fable" window on each profile that the picker must ignore.
build_fixture() {
  local out="$1" now="$2" active="$3"
  local onr_w="$4" onr_T="$5" onr_r5="$6" onr_t5="$7"
  local per_w="$8" per_T="$9" per_r5="${10}" per_t5="${11}"
  cat >"$out" <<JSON
{
  "schema": 2,
  "active_profile": "$active",
  "profiles": [
    {"name": "onramplab", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": $((100 - onr_r5)), "resets_at": "$(iso_at "$now" "$onr_t5")"},
      {"label": "7d", "utilization_pct": $((100 - onr_w)), "resets_at": "$(iso_at "$now" "$onr_T")"},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]},
    {"name": "personal", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": $((100 - per_r5)), "resets_at": "$(iso_at "$now" "$per_t5")"},
      {"label": "7d", "utilization_pct": $((100 - per_w)), "resets_at": "$(iso_at "$now" "$per_T")"},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]}
  ]
}
JSON
}

# run_claude_pick <now epoch> <fixture path>: sources clauth.zsh into a
# throwaway `zsh -fc` and invokes the `claude` alias (via eval, same reason
# as run_alias above) against the stubbed PATH, returning whatever `clauth
# start ...` logged, with the real settings.json path masked to @SETTINGS@.
run_claude_pick() {
  local now="$1" fixture="$2" log="$T/clauth-pick-out.log" logged
  : >"$log"
  PATH="$CLAUTH_TEST_PATH" CLAUTH_STUB_LOG="$log" CLAUTH_PICK_NOW="$now" CLAUTH_STATUS_FIXTURE="$fixture" ZSH_FILE="$CLAUTH_ZSH" zsh -fc '
    source "$ZSH_FILE"
    eval claude >/dev/null 2>&1
  ' || true  # same: report via the assertion, never abort
  logged="$(cat "$log" 2>/dev/null)"
  printf '%s' "${logged//"$SETTINGS_FILE"/@SETTINGS@}"
}

# run_case <label> <now> <expected profile> <active profile> <onr w T r5 t5> <per w T r5 t5>
run_case() {
  local label="$1" now="$2" expected="$3" active="$4"
  local fixture="$T/fixture-${label}.json"
  build_fixture "$fixture" "$now" "$active" "${@:5}"
  local got
  got="$(run_claude_pick "$now" "$fixture")"
  if [ "$got" = "start ${expected} -- --settings @SETTINGS@ --permission-mode auto" ]; then
    pass "smart-pick-${label}"
  else
    bad "smart-pick-${label}"
    printf '     expected: start %s -- --settings @SETTINGS@ --permission-mode auto\n     got:      %s\n' "$expected" "$got" >&2
  fi
}

if [ "$CLAUTH_SHADOW_OK" -eq 1 ]; then
  run_case case1  "$WED"     personal  onramplab 22 62.6 65 3.75 99 154.6 97 3.6
  run_case case2  "$WED"     onramplab onramplab 40 10   70 2    80 100   90 3
  run_case case3  "$WED"     personal  onramplab 40 10   8  4    80 100   90 3
  run_case case4  "$WED"     onramplab onramplab 40 10   8  0.3  80 100   90 3
  run_case case5  "$WED"     onramplab onramplab 40 10   10 4    80 100   5  4.5
  run_case case6  "$WED"     onramplab onramplab 4  30   80 2    50 120   60 2
  run_case case8  "$WED"     onramplab onramplab 30 50   50 2    1  20    90 2
  run_case case9a "$WED"     personal  onramplab 40 10   22 4    80 100   90 3
  run_case case9b "$SAT"     onramplab onramplab 40 10   22 4    80 100   90 3
  run_case case10 "$WED1730" onramplab onramplab 40 10   60 4    80 100   90 3
  run_case case11 "$WED"     personal  personal  1  30   80 2    50 120   1  2

  # Regression: a resets_at already ending in plain "Z" (no fraction, no
  # +00:00 - a shape real `clauth status --json` can emit) must parse without
  # doubling the "Z". personal's windows use this format; onramplab keeps the
  # usual fractional+offset format. Expected pick is personal - deliberately
  # NOT onramplab, the function's own fallback default - so a regression that
  # makes parse_epoch error (jq exits, target stays empty) is caught by a
  # wrong pick rather than being masked by a fallback that happens to match.
  FIXTURE_Z="$T/fixture-case-z-suffix.json"
  cat >"$FIXTURE_Z" <<JSON
{
  "schema": 2,
  "active_profile": "onramplab",
  "profiles": [
    {"name": "onramplab", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": $((100 - 22)), "resets_at": "$(iso_at "$WED" 4)"},
      {"label": "7d", "utilization_pct": $((100 - 40)), "resets_at": "$(iso_at "$WED" 10)"},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]},
    {"name": "personal", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": $((100 - 90)), "resets_at": "$(iso_at "$WED" 3 '%Y-%m-%dT%H:%M:%SZ')"},
      {"label": "7d", "utilization_pct": $((100 - 80)), "resets_at": "$(iso_at "$WED" 100 '%Y-%m-%dT%H:%M:%SZ')"},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]}
  ]
}
JSON
  got="$(run_claude_pick "$WED" "$FIXTURE_Z")"
  if [ "$got" = "start personal -- --settings @SETTINGS@ --permission-mode auto" ]; then
    pass smart-pick-z-suffix
  else
    bad smart-pick-z-suffix
    printf '     expected: start personal -- --settings @SETTINGS@ --permission-mode auto\n     got:      %s\n' "$got" >&2
  fi

  # Regression: a window whose resets_at is JSON null (present window, no
  # reset timestamp) must be treated like a missing reset - 7d: T floors to
  # 0.25; 5h: t5=0, E=0 - not fed straight into parse_epoch, which errors on
  # a null input. onramplab gets null resets_at on both windows; personal is
  # a normal, stronger profile. Expected pick is personal, again deliberately
  # not the onramplab fallback default, for the same masking reason as above.
  FIXTURE_NULL="$T/fixture-case-null-resets.json"
  cat >"$FIXTURE_NULL" <<JSON
{
  "schema": 2,
  "active_profile": "onramplab",
  "profiles": [
    {"name": "onramplab", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": 50, "resets_at": null},
      {"label": "7d", "utilization_pct": 94, "resets_at": null},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]},
    {"name": "personal", "auth_status": "ok", "stale": false, "windows": [
      {"label": "5h", "utilization_pct": $((100 - 95)), "resets_at": "$(iso_at "$WED" 1)"},
      {"label": "7d", "utilization_pct": $((100 - 90)), "resets_at": "$(iso_at "$WED" 2)"},
      {"label": "7d fable", "utilization_pct": 0, "resets_at": "2099-01-01T00:00:00+00:00"}
    ]}
  ]
}
JSON
  got="$(run_claude_pick "$WED" "$FIXTURE_NULL")"
  if [ "$got" = "start personal -- --settings @SETTINGS@ --permission-mode auto" ]; then
    pass smart-pick-null-resets
  else
    bad smart-pick-null-resets
    printf '     expected: start personal -- --settings @SETTINGS@ --permission-mode auto\n     got:      %s\n' "$got" >&2
  fi
else
  for c in case1 case2 case3 case4 case5 case6 case8 case9a case9b case10 case11 z-suffix null-resets; do
    bad "smart-pick-${c}"
  done
fi

# ------------------------------------------------------------
# Outside-block warning: install-cli-tools.sh must warn to stderr when a
# stray `_clauth_smart_pick()` definition sits outside the BEGIN..END
# managed range (it would silently override the managed copy at zsh load
# time), and stay silent when nothing sits outside the block.
#
# Extraction: the exact post-sync warning snippet, anchored on its own
# `OUTSIDE_SMART_PICK=` assignment through the closing `fi` of its `if`, run
# standalone against a synthetic ZSHRC under $T - never the real ~/.zshrc.
# BEGIN_MARK/END_MARK are likewise pulled from install-cli-tools.sh's own
# constants rather than retyped, so a sentinel-text change can't silently
# desync this test from the script it is checking.
# ------------------------------------------------------------
OUTSIDE_CHECK_SRC="$T/outside-check.sh"
awk '/^OUTSIDE_SMART_PICK=/,/^fi$/' "$INSTALL_SH" > "$OUTSIDE_CHECK_SRC"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$OUTSIDE_CHECK_SRC" && pass extract-outside-check || bad extract-outside-check
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
bash -n "$OUTSIDE_CHECK_SRC" && pass outside-check-syntax || bad outside-check-syntax

TEST_BEGIN_MARK="$(grep -oE '^BEGIN_MARK="[^"]+"' "$INSTALL_SH" | sed -E 's/^BEGIN_MARK="(.*)"$/\1/')"
TEST_END_MARK="$(grep -oE '^END_MARK="[^"]+"' "$INSTALL_SH" | sed -E 's/^END_MARK="(.*)"$/\1/')"

run_outside_check() { # $1 = synthetic zshrc path; prints whatever it wrote to stderr
  # shellcheck disable=SC2069  # intentional fd-swap idiom to capture only stderr (verified: stdout is discarded, stderr is what $() captures), not the "wanted both merged" mistake this check usually flags
  ZSHRC="$1" BEGIN_MARK="$TEST_BEGIN_MARK" END_MARK="$TEST_END_MARK" bash "$OUTSIDE_CHECK_SRC" 2>&1 1>/dev/null
}

ZSHRC_CLEAN="$T/zshrc-clean"
cat >"$ZSHRC_CLEAN" <<EOF
# a normal, unrelated zshrc line
$TEST_BEGIN_MARK
some managed content, no stray definition anywhere
$TEST_END_MARK
EOF
out="$(run_outside_check "$ZSHRC_CLEAN")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ -z "$out" ] && pass outside-check-silent-when-clean || bad outside-check-silent-when-clean

ZSHRC_STRAY="$T/zshrc-stray"
cat >"$ZSHRC_STRAY" <<EOF
_clauth_smart_pick() { echo old-hand-copied-version; }
$TEST_BEGIN_MARK
some managed content
$TEST_END_MARK
EOF
out="$(run_outside_check "$ZSHRC_STRAY")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$out" | grep -qF '_clauth_smart_pick' && pass outside-check-warns-on-stray || bad outside-check-warns-on-stray

# Same stray-definition scenario, but using the bash/zsh `function` keyword
# declaration form (no parens) instead of the POSIX `name() { ... }` form -
# both are valid ways to define a function outside the managed block, and
# the check must catch either.
ZSHRC_STRAY_FN="$T/zshrc-stray-fn"
cat >"$ZSHRC_STRAY_FN" <<EOF
function _clauth_smart_pick { echo old-hand-copied-version; }
$TEST_BEGIN_MARK
some managed content
$TEST_END_MARK
EOF
out="$(run_outside_check "$ZSHRC_STRAY_FN")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
printf '%s' "$out" | grep -qF '_clauth_smart_pick' && pass outside-check-warns-on-stray-function-form || bad outside-check-warns-on-stray-function-form


# ------------------------------------------------------------
# Managed block: the clauth section must no longer be inlined in
# install-cli-tools.sh's heredoc; the block must instead `source` the repo's
# clauth.zsh by absolute path, while the unrelated aliases stay inline.
#
# Extraction: the exact block-generation snippet (from `NEW_BLOCK=$(mktemp)`
# through the closing `} >"$NEW_BLOCK"`), run standalone in its own bash with
# a synthetic CLAUTH_ZSH, so install-cli-tools.sh itself (sudo package
# installs, the real ~/.zshrc) is never executed. CLAUTH_ZSH is set to a
# path containing a space AND a single quote to prove the generated line
# quotes correctly end to end under zsh.
# ------------------------------------------------------------
BLOCK_GEN_SRC="$T/block-gen.sh"
{
  awk '/^NEW_BLOCK="\$\(mktemp\)"$/,/^} >"\$NEW_BLOCK"$/' "$INSTALL_SH"
  # shellcheck disable=SC2016  # literal text appended to the generated script: expands there, not here
  printf 'cat "$NEW_BLOCK"\n'
} > "$BLOCK_GEN_SRC"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q '^NEW_BLOCK=' "$BLOCK_GEN_SRC" && bash -n "$BLOCK_GEN_SRC" && pass extract-block-gen || bad extract-block-gen

FAKE_REPO="$T/fake repo/it's here"
mkdir -p "$FAKE_REPO/platforms/claude"
cp "$CLAUTH_ZSH" "$SETTINGS_FILE" "$FAKE_REPO/platforms/claude/"
FAKE_CLAUTH_ZSH="$FAKE_REPO/platforms/claude/clauth.zsh"
BLOCK_OUT="$T/managed-block.zsh"
BEGIN_MARK="$TEST_BEGIN_MARK" END_MARK="$TEST_END_MARK" CLAUTH_ZSH="$FAKE_CLAUTH_ZSH" bash "$BLOCK_GEN_SRC" > "$BLOCK_OUT"

# Exactly one guarded source line: source when readable, else warn on stderr
# naming the path. The expected text is built here with sed for the quote
# escaping (' -> '\''), independent of the script's own bash substitution.
ESC_FAKE_PATH="$(printf '%s' "$FAKE_CLAUTH_ZSH" | sed "s/'/'\\\\''/g")"
EXPECTED_SOURCE_LINE="if [ -r '${ESC_FAKE_PATH}' ]; then source '${ESC_FAKE_PATH}'; else print -ru2 -- 'cli-tools: clauth.zsh not found, claude/cl* aliases unavailable (re-run install-cli-tools.sh): ${ESC_FAKE_PATH}'; fi"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(grep -cxF "$EXPECTED_SOURCE_LINE" "$BLOCK_OUT")" -eq 1 ] && pass block-sources-clauth-zsh || bad block-sources-clauth-zsh
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$(grep -c 'clauth\.zsh' "$BLOCK_OUT")" -eq 1 ] && pass block-single-clauth-zsh-line || bad block-single-clauth-zsh-line

# The clauth section is no longer inlined...
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '_clauth_smart_pick|^clauto\(|^alias (claude|cl[a-z]*)=' "$BLOCK_OUT" && bad block-has-no-inlined-clauth || pass block-has-no-inlined-clauth
# ...and the unrelated aliases stay in the heredoc, inside the sentinels.
for needle in 'alias cat="bat"' 'alias csv=' 'lfcd()' "alias f='lfcd'" 'alias skills=' "alias sk="; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qF "$needle" "$BLOCK_OUT" && pass "block-keeps-${needle%%[=(]*}" || bad "block-keeps-${needle%%[=(]*}"
done
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
{ [ "$(head -1 "$BLOCK_OUT")" = "$TEST_BEGIN_MARK" ] && [ "$(tail -1 "$BLOCK_OUT")" = "$TEST_END_MARK" ]; } && pass block-sentinels-wrap-content || bad block-sentinels-wrap-content

# Missing clauth.zsh (repo moved / worktree deleted after install): loading
# the block must not error out, must name the missing path on stderr, and
# must leave the block's other aliases working.
MISSING_ZSH="$T/gone dir/it's/platforms/claude/clauth.zsh"
MISSING_BLOCK="$T/managed-block-missing.zsh"
BEGIN_MARK="$TEST_BEGIN_MARK" END_MARK="$TEST_END_MARK" CLAUTH_ZSH="$MISSING_ZSH" bash "$BLOCK_GEN_SRC" > "$MISSING_BLOCK"
missing_err="$T/missing.err"
missing_rc=0
BLOCK_OUT="$MISSING_BLOCK" zsh -fc 'source "$BLOCK_OUT"; whence -w sk >&2' >/dev/null 2>"$missing_err" || missing_rc=$?
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$missing_rc" -eq 0 ] && grep -qF "$MISSING_ZSH" "$missing_err" && grep -qF 'cli-tools: clauth.zsh not found' "$missing_err" && pass block-missing-clauth-zsh-warns-by-path || bad block-missing-clauth-zsh-warns-by-path
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'sk: alias' "$missing_err" && pass block-missing-clauth-zsh-keeps-other-aliases || bad block-missing-clauth-zsh-keeps-other-aliases

# Linked-worktree warning: extract the CLAUTH_REPO_DIR..fi snippet and run it
# from a copy placed inside (a) a plain repo and (b) a linked worktree of it.
# Only (b) may warn on stderr; both must keep CLAUTH_ZSH under their own dir.
WT_SNIP="$T/wt-snippet.sh"
# shellcheck disable=SC2016  # literal text appended to the generated script: expands there, not here
{ awk '/^CLAUTH_REPO_DIR=/,/^fi$/' "$INSTALL_SH"; printf 'echo "CLAUTH_ZSH=$CLAUTH_ZSH"\n'; } > "$WT_SNIP"
WT_MAIN="$T/wt-main"
WT_LINKED="$T/wt-linked"
git init -q "$WT_MAIN"
git -C "$WT_MAIN" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$WT_MAIN" worktree add -q "$WT_LINKED" -b wt-test
cp "$WT_SNIP" "$WT_MAIN/snip.sh"
cp "$WT_SNIP" "$WT_LINKED/snip.sh"
main_out="$(ZSHRC=/x/.zshrc bash "$WT_MAIN/snip.sh" 2>"$T/wt-main.err")"
linked_out="$(ZSHRC=/x/.zshrc bash "$WT_LINKED/snip.sh" 2>"$T/wt-linked.err")"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ ! -s "$T/wt-main.err" ] && pass worktree-warning-silent-in-main-checkout || bad worktree-warning-silent-in-main-checkout
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF "$WT_LINKED" "$T/wt-linked.err" && grep -qF 'worktree' "$T/wt-linked.err" && pass worktree-warning-in-linked-worktree || bad worktree-warning-in-linked-worktree
# the chosen path is NOT changed by the warning
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
{ [ "$main_out" = "CLAUTH_ZSH=$WT_MAIN/platforms/claude/clauth.zsh" ] && [ "$linked_out" = "CLAUTH_ZSH=$WT_LINKED/platforms/claude/clauth.zsh" ]; } && pass worktree-warning-keeps-path || bad worktree-warning-keeps-path

# Reached through a symlinked repo directory: _CLAUTH_SETTINGS_FILE must be
# the resolved real path (:A resolves symlinks), not the symlink path.
LINK_REPO="$T/link-to-fake-repo"
ln -s "$FAKE_REPO" "$LINK_REPO"
REAL_FAKE_SETTINGS="$(cd -P "$FAKE_REPO" && pwd)/platforms/claude/settings.json"
via_link="$(LINK_ZSH="$LINK_REPO/platforms/claude/clauth.zsh" zsh -fc 'source "$LINK_ZSH"; print -r -- "$_CLAUTH_SETTINGS_FILE"' 2>/dev/null || true)"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$via_link" = "$REAL_FAKE_SETTINGS" ] && pass settings-path-resolved-through-symlinked-repo || bad settings-path-resolved-through-symlinked-repo

# End to end under zsh: load the generated block (not the repo's clauth.zsh
# directly) and launch via an alias. Requires the shadow guard from above,
# since this runs the stub-backed aliases again.
if [ "$CLAUTH_SHADOW_OK" -eq 1 ]; then
  e2e_log="$T/clauth-e2e.log"
  : > "$e2e_log"; : > "${e2e_log}.argv"
  PATH="$CLAUTH_TEST_PATH" CLAUTH_STUB_LOG="$e2e_log" BLOCK_OUT="$BLOCK_OUT" zsh -fc '
    source "$BLOCK_OUT"
    eval cla >/dev/null 2>&1
  ' || true  # same: report via the assertion, never abort
  # The settings path must come from the sourced file's own location (the
  # fake repo copy, containing a space and a quote), as ONE argument.
  EXPECTED_FAKE_SETTINGS="$FAKE_REPO/platforms/claude/settings.json"
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  awk -v s="$EXPECTED_FAKE_SETTINGS" '
    $0 == "--" && !d { d = NR; next }
    d && NR == d + 1 { a = ($0 == "--settings") }
    d && NR == d + 2 { b = ($0 == s) }
    END { exit !(a && b) }
  ' "${e2e_log}.argv" && pass block-e2e-settings-path-from-own-location || bad block-e2e-settings-path-from-own-location

  # A relative source path must resolve to the same absolute file.
  rel_log="$T/clauth-rel.log"
  : > "$rel_log"; : > "${rel_log}.argv"
  PATH="$CLAUTH_TEST_PATH" CLAUTH_STUB_LOG="$rel_log" FAKE_DIR="$FAKE_REPO/platforms/claude" zsh -fc '
    cd "$FAKE_DIR/.." || exit 1
    source claude/clauth.zsh
    eval cl >/dev/null 2>&1
  ' || true  # same: report via the assertion, never abort
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qxF "$EXPECTED_FAKE_SETTINGS" "${rel_log}.argv" && pass settings-path-absolute-from-relative-source || bad settings-path-absolute-from-relative-source
else
  bad block-e2e-settings-path-from-own-location
  bad settings-path-absolute-from-relative-source
fi

exit $fail
