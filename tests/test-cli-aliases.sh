#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO/install-cli-tools.sh"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool opencode opencode-bin ' "$INSTALL_SH" && pass opencode-install-line || bad opencode-install-line

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^ensure_tool rg +ripgrep ' "$INSTALL_SH" && pass rg-install-line || bad rg-install-line

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
# Dynamic check: every claude-launcher alias must, once actually run,
# invoke `clauth` (never `claude` directly, and never the old _ccp_launch
# config-dir wrapper — both retired in favor of clauth profiles) with the
# right profile name and the right trailing claude args.
#
# Extraction: pull the literal "## aliases for claude code" section straight
# out of install-cli-tools.sh's heredoc — the exact text ~/.zshrc ends up
# with — instead of retyping the expected alias bodies by hand. A
# hand-retyped copy would silently drift the next time an alias is edited in
# install-cli-tools.sh without this test being touched, which is exactly the
# kind of gap this test exists to catch.
# ------------------------------------------------------------
ALIAS_SRC="$T/claude-aliases.sh"
awk '/^## aliases for claude code$/,/^## aliases for lf /{ if (!/^## aliases for lf /) print }' "$INSTALL_SH" > "$ALIAS_SRC"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$ALIAS_SRC" && pass extract-claude-aliases || bad extract-claude-aliases
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
bash -n "$ALIAS_SRC" && pass claude-aliases-syntax || bad claude-aliases-syntax

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
cat > "$CLAUTH_BIN/clauth" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${CLAUTH_STUB_LOG:?}"
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

# run_alias <alias-name>: sources the extracted alias definitions into a
# throwaway bash -c, then runs the single named alias against the stub PATH,
# and prints whatever the stub `clauth` logged (empty if it was never
# invoked at all). `shopt -s expand_aliases` plus the `source` must happen
# in an earlier line of the SAME script than the alias invocation: bash
# decides whether to expand an alias at parse time, per line, so the alias
# must already be defined by the time this script's parser reaches the
# invocation line. Passing the alias name as a literal token substituted
# into the bash -c string (rather than invoking it via a shell variable at
# runtime) is what makes that possible — a variable holding the name would
# not trigger alias expansion at all, since bash never re-parses an
# already-substituted argument to check whether it names an alias.
run_alias() {
  local alias_name="$1" log="$T/clauth-out-${1}.log"
  : > "$log"
  PATH="$CLAUTH_TEST_PATH" CLAUTH_STUB_LOG="$log" bash -c "
    cd '$REPO' || exit 1
    shopt -s expand_aliases
    source '$ALIAS_SRC'
    $alias_name >/dev/null 2>&1
  "
  cat "$log" 2>/dev/null
}

# Expected argv `clauth` receives for each alias, as an anchored ERE. The
# worktree/remote-control variants include the dynamic $(...) pieces
# (basename + timestamp) that the alias definitions evaluate at run time —
# see the `literal 保留` note in install-cli-tools.sh for why those are
# quoted heredoc text rather than something this script could expand ahead
# of time.
TS_RE='[0-9]{8}-[0-9]{6}'
declare -A EXPECTED=(
  [cl]="start onramplab --"
  [cla]="start onramplab -- --permission-mode auto"
  [clc]="start onramplab -- --permission-mode auto --continue"
  [clr]="start onramplab -- --permission-mode auto --resume"
  [clw]="start onramplab -- --permission-mode auto --worktree ${EXPECTED_WT_BASENAME}/wt/${TS_RE}"
  [clre]="start onramplab -- --permission-mode auto --remote-control --name remote-control-onr-notebook-${TS_RE}"
  [clp]="start personal -- --permission-mode auto"
  [clpc]="start personal -- --permission-mode auto --continue"
  [clpr]="start personal -- --permission-mode auto --resume"
  [clpw]="start personal -- --permission-mode auto --worktree ${EXPECTED_WT_BASENAME}/wt/${TS_RE}"
  [clpre]="start personal -- --permission-mode auto --remote-control --name remote-control-personal-notebook-${TS_RE}"
)

if [ "$CLAUTH_SHADOW_OK" -eq 1 ]; then
  for alias_name in cl cla clc clr clw clre clp clpc clpr clpw clpre; do
    logged="$(run_alias "$alias_name")"
    if [[ "$logged" =~ ^${EXPECTED[$alias_name]}$ ]]; then
      pass "alias-${alias_name}-via-clauth"
    else
      bad "alias-${alias_name}-via-clauth"
      printf '     expected (ERE): %s\n     got:            %s\n' "${EXPECTED[$alias_name]}" "$logged" >&2
    fi
  done
else
  # The shadow guard above already failed and reported why; do not run a
  # single alias in that state; "clauth" (or whatever else the aliases
  # invoke) is not confirmed to resolve inside CLAUTH_BIN, so actually
  # running any of them here could reach a real, stateful binary instead of
  # the stub. Every alias check is marked failed without ever running one.
  for alias_name in cl cla clc clr clw clre clp clpc clpr clpw clpre; do
    bad "alias-${alias_name}-via-clauth"
  done
fi

# ------------------------------------------------------------
# Case set 2: abduco is gone for good, the old _ccp_launch config-dir
# wrapper is gone for good, and every claude launcher alias routes through
# clauth rather than calling claude directly or through either retired
# mechanism.
# ------------------------------------------------------------
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qi 'abduco' "$INSTALL_SH" && bad no-abduco-left || pass no-abduco-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q '_cc_launch' "$INSTALL_SH" && bad no-cc-launch-left || pass no-cc-launch-left
# Anchored to an actual function definition (not just the substring):
# install-cli-tools.sh's own alias-block comment names "_ccp_launch" by
# design, to explain what was removed and why — an unanchored grep -q here
# would stay red forever even with the function itself long gone.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qE '^_ccp_launch\(\)' "$INSTALL_SH" && bad no-ccp-launch-left || pass no-ccp-launch-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '.claude-personal' "$INSTALL_SH" && bad no-claude-personal-dir-left || pass no-claude-personal-dir-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'CC_SESSION_TAG' "$INSTALL_SH" && bad no-session-tag-left || pass no-session-tag-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q "^alias cll=" "$INSTALL_SH" && bad no-cll-alias || pass no-cll-alias

# Cheap static companion to the dynamic alias-via-clauth checks above: each
# alias's source line must literally start with `clauth start <profile>`, so
# a future edit that reverts an alias back to a bare `claude` call (or to
# the wrong profile) fails here even before the dynamic check runs.
for a in cl cla clc clr clw clre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}='clauth start onramplab" "$INSTALL_SH" && pass "alias-${a}-onramplab-line" || bad "alias-${a}-onramplab-line"
done

for a in clp clpc clpr clpw clpre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}='clauth start personal" "$INSTALL_SH" && pass "alias-${a}-personal-line" || bad "alias-${a}-personal-line"
done

# Regression guard: the managed-block sentinels must never change, or install
# leaves an orphaned block behind on the next run.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# >>> cli-tools aliases (managed) >>>' "$INSTALL_SH" && pass sentinel-begin-unchanged || bad sentinel-begin-unchanged
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# <<< cli-tools aliases (managed) <<<' "$INSTALL_SH" && pass sentinel-end-unchanged || bad sentinel-end-unchanged

exit $fail
