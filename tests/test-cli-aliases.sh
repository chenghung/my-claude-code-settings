#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO/install-cli-tools.sh"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

grep -qE '^ensure_tool opencode opencode-bin ' "$INSTALL_SH" && pass opencode-install-line || bad opencode-install-line

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ------------------------------------------------------------
# DRY extraction: pull the real _cc_prune_dead_sockets / _cc_launch function
# bodies straight out of install-cli-tools.sh (they live inside a quoted
# heredoc there, but are plain lines from awk's point of view) instead of
# maintaining a copy here that could drift from the shipped code.
# ------------------------------------------------------------
awk '/^_cc_prune_dead_sockets\(\) \{/,/^}/' "$INSTALL_SH" > "$T/prune.sh"
awk '/^_cc_launch\(\) \{/,/^}/' "$INSTALL_SH" > "$T/launch.sh"
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$T/prune.sh" && pass extract-prune || bad extract-prune
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -s "$T/launch.sh" && pass extract-launch || bad extract-launch
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
bash -n "$T/prune.sh" && pass prune-syntax || bad prune-syntax

# Sourced file is generated at runtime (extracted from install-cli-tools.sh);
# there is no static path for shellcheck to follow.
# shellcheck source=/dev/null
source "$T/prune.sh"

# ------------------------------------------------------------
# Stub bin/abduco: prints a controlled `-l` listing (session names taken
# from $CC_TEST_LIVE, one per line) and drops a marker file whenever `-l`
# is actually invoked, so tests can assert the short-circuit path never
# calls it. `-c NAME CMD ARGS...` exec's into the stubbed command so the
# optional _cc_launch test can inspect what it was asked to run.
# ------------------------------------------------------------
STUB_BIN="$T/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/abduco" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-l" ]; then
  : > "${CC_TEST_ABDUCO_L_MARKER:?}"
  echo "Name Status"
  if [ -n "${CC_TEST_LIVE:-}" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && printf 'x %s\n' "$n"
    done <<< "$CC_TEST_LIVE"
  fi
  exit 0
fi
if [ "${1:-}" = "-c" ]; then
  echo "SESSION=$2"
  shift 2
  exec "$@"
fi
exit 0
STUB
chmod +x "$STUB_BIN/abduco"
cat > "$STUB_BIN/claude" <<'STUB'
#!/usr/bin/env bash
echo "CLAUDE_ARGS=$*"
STUB
chmod +x "$STUB_BIN/claude"

# Creates a real AF_UNIX socket file at $1 (bind() leaves the inode behind
# after close(), which is exactly the artifact _cc_prune_dead_sockets scans
# for via `find -type s`).
mk_socket() {
  python3 - "$1" <<'PY'
import socket
import sys

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.close()
PY
}

# ------------------------------------------------------------
# Case set 1: the four scenarios the pruning logic must distinguish.
# ------------------------------------------------------------
ABDUCO_HOME="$T/home1"
ABDUCO_DIR="$ABDUCO_HOME/.abduco"
mkdir -p "$ABDUCO_DIR"

dead_old="$ABDUCO_DIR/dead-old@host1"        # expired, not live      -> removed
alive_old="$ABDUCO_DIR/alive-old@host1"      # expired, live          -> kept
dead_new="$ABDUCO_DIR/dead-new@host1"        # not expired, not live  -> kept
dead_old_file="$ABDUCO_DIR/dead-old-file@host1" # expired, regular file -> kept

mk_socket "$dead_old"
mk_socket "$alive_old"
mk_socket "$dead_new"
: > "$dead_old_file"

touch -d '-20 days' "$dead_old" "$alive_old" "$dead_old_file"
touch -d '-5 days' "$dead_new"

CC_TEST_LIVE="alive-old"
CC_TEST_ABDUCO_L_MARKER="$T/marker-set1"
export CC_TEST_LIVE CC_TEST_ABDUCO_L_MARKER

# HOME/PATH are intentionally scoped to this subshell only, so the rest of
# the test script keeps running under the real HOME/PATH afterward.
(
  # shellcheck disable=SC2030  # intentional: HOME is scoped to this subshell only
  export HOME="$ABDUCO_HOME"
  # shellcheck disable=SC2030  # intentional: PATH is scoped to this subshell only
  export PATH="$STUB_BIN:$PATH"
  _cc_prune_dead_sockets
) || true

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test ! -e "$dead_old"      && pass prune-removes-dead-expired-socket || bad prune-removes-dead-expired-socket
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -e "$alive_old"       && pass prune-keeps-live-expired-socket   || bad prune-keeps-live-expired-socket
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -e "$dead_new"        && pass prune-keeps-unexpired-socket      || bad prune-keeps-unexpired-socket
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -e "$dead_old_file"   && pass prune-keeps-non-socket-file       || bad prune-keeps-non-socket-file

# ------------------------------------------------------------
# Case set 2: short-circuit — no expired candidates means `abduco -l`
# must never be invoked at all.
# ------------------------------------------------------------
ABDUCO_HOME2="$T/home2"
ABDUCO_DIR2="$ABDUCO_HOME2/.abduco"
mkdir -p "$ABDUCO_DIR2"
fresh="$ABDUCO_DIR2/fresh@host1"
mk_socket "$fresh"
touch -d '-1 days' "$fresh"

CC_TEST_ABDUCO_L_MARKER="$T/marker-set2"
export CC_TEST_ABDUCO_L_MARKER
rm -f "$CC_TEST_ABDUCO_L_MARKER"

(
  # shellcheck disable=SC2030,SC2031  # intentional: HOME is scoped to this subshell only
  export HOME="$ABDUCO_HOME2"
  # shellcheck disable=SC2030,SC2031  # intentional: PATH is scoped to this subshell only
  export PATH="$STUB_BIN:$PATH"
  _cc_prune_dead_sockets
) || true

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test ! -e "$CC_TEST_ABDUCO_L_MARKER" && pass prune-skips-abduco-l-when-no-candidates || bad prune-skips-abduco-l-when-no-candidates
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
test -e "$fresh" && pass prune-keeps-fresh-socket-in-shortcircuit-case || bad prune-keeps-fresh-socket-in-shortcircuit-case

# ------------------------------------------------------------
# Case set 3 (optional/secondary): _cc_launch session naming.
# Verifies the "<repo-basename>-<timestamp>" pattern passed to `abduco -c`.
# ------------------------------------------------------------
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
bash -n "$T/launch.sh" && pass launch-syntax || bad launch-syntax
# shellcheck source=/dev/null
source "$T/launch.sh"

REPO_DIR="$T/my-test-repo"
mkdir -p "$REPO_DIR"
git -C "$REPO_DIR" init -q

LAUNCH_HOME="$T/home3"
mkdir -p "$LAUNCH_HOME"
CC_TEST_ABDUCO_L_MARKER="$T/marker-set3"
export CC_TEST_ABDUCO_L_MARKER

out="$(
  cd "$REPO_DIR"
  # shellcheck disable=SC2031  # intentional: HOME is scoped to this subshell only
  export HOME="$LAUNCH_HOME"
  # shellcheck disable=SC2031  # intentional: PATH is scoped to this subshell only
  export PATH="$STUB_BIN:$PATH"
  _cc_launch --permission-mode auto
)"

# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
echo "$out" | grep -Eq '^SESSION=my-test-repo-[0-9]{8}-[0-9]{6}$' && pass launch-session-name-pattern || bad launch-session-name-pattern
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
echo "$out" | grep -q '^CLAUDE_ARGS=--permission-mode auto$' && pass launch-forwards-args || bad launch-forwards-args

exit $fail
