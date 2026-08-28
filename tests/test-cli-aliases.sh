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
# Stub bin/claude: echoes back the args and CLAUDE_CONFIG_DIR it was invoked
# with, so tests can verify what _ccp_launch passed through without actually
# launching claude.
# ------------------------------------------------------------
STUB_BIN="$T/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "CLAUDE_ARGS=$*"
echo "CLAUDE_CFG=${CLAUDE_CONFIG_DIR:-<unset>}"
STUB
chmod +x "$STUB_BIN/claude"

# ------------------------------------------------------------
# Case set 1: _ccp_launch points CLAUDE_CONFIG_DIR at the personal config
# dir and does not leak it back into the calling shell.
# ------------------------------------------------------------
LAUNCH_HOME="$T/launch-home"
mkdir -p "$LAUNCH_HOME"

awk '/^_ccp_launch\(\) \{/,/^}/' "$INSTALL_SH" > "$T/plaunch.sh"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$T/plaunch.sh" && pass extract-ccp-launch || bad extract-ccp-launch
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
bash -n "$T/plaunch.sh" && pass ccp-launch-syntax || bad ccp-launch-syntax
# shellcheck source=/dev/null
source "$T/plaunch.sh"

# The call to _ccp_launch below must run directly in this shell, with no
# `$(...)` command substitution or explicit `( ... )` subshell wrapped around
# it: either wrapper would itself isolate CLAUDE_CONFIG_DIR from this script,
# which would make the ccp-no-env-leak assertion structurally unable to fail.
# So HOME/PATH are changed directly here and restored by hand afterward, and
# stdout is captured via redirection to a file instead of command substitution.
saved_home="$HOME"
saved_path="$PATH"
export HOME="$LAUNCH_HOME"
export PATH="$STUB_BIN:$PATH"

cfg_before="${CLAUDE_CONFIG_DIR:-<unset>}"
_ccp_launch --permission-mode auto > "$T/ccp-out.txt"
cfg_after="${CLAUDE_CONFIG_DIR:-<unset>}"
out_p="$(cat "$T/ccp-out.txt")"

export HOME="$saved_home"
export PATH="$saved_path"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
echo "$out_p" | grep -qF "CLAUDE_CFG=$LAUNCH_HOME/.claude-personal" && pass ccp-config-dir-propagated || bad ccp-config-dir-propagated
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
echo "$out_p" | grep -qF 'CLAUDE_ARGS=--permission-mode auto' && pass ccp-forwards-args || bad ccp-forwards-args
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
[ "$cfg_before" = "$cfg_after" ] && pass ccp-no-env-leak || bad ccp-no-env-leak

# ------------------------------------------------------------
# Case set 2: abduco is gone for good, and every claude launcher alias calls
# claude directly rather than routing through a multiplexer wrapper.
# ------------------------------------------------------------
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qi 'abduco' "$INSTALL_SH" && bad no-abduco-left || pass no-abduco-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q '_cc_launch' "$INSTALL_SH" && bad no-cc-launch-left || pass no-cc-launch-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q 'CC_SESSION_TAG' "$INSTALL_SH" && bad no-session-tag-left || pass no-session-tag-left
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -q "^alias cll=" "$INSTALL_SH" && bad no-cll-alias || pass no-cll-alias

for a in cl cla clc clr clw clre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}='claude( |')" "$INSTALL_SH" && pass "alias-${a}-direct" || bad "alias-${a}-direct"
done

for a in clp clpc clpr clpw clpre; do
  # shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
  grep -qE "^alias ${a}=" "$INSTALL_SH" && pass "alias-${a}-present" || bad "alias-${a}-present"
done

# Regression guard: the managed-block sentinels must never change, or install
# leaves an orphaned block behind on the next run.
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# >>> cli-tools aliases (managed) >>>' "$INSTALL_SH" && pass sentinel-begin-unchanged || bad sentinel-begin-unchanged
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
grep -qF '# <<< cli-tools aliases (managed) <<<' "$INSTALL_SH" && pass sentinel-end-unchanged || bad sentinel-end-unchanged

exit $fail
