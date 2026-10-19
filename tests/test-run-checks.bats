#!/usr/bin/env bats
# Tests for scripts/run-checks.sh — the single local/CI entry point that runs
# the linter and the repo's tests.
#
# Pure bats (no bats-assert): CI installs only the `bats` package.
# Each test builds a throwaway git repo under BATS_TEST_TMPDIR holding a copy of
# the script, fake test files, and stub `shellcheck`/`bats` executables.
#
# PATH isolation: the script runs with PATH set to a private bin dir that holds
# ONLY symlinks to the few real tools it needs plus the stubs. The real
# linter and bats are therefore unreachable, not shadowed: a missing stub
# makes the tool "not found" (loud failure) and can never silently fall through
# to the real program. Hence no stub-shadowing guard is needed here.

bats_require_minimum_version 1.5.0

REAL_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/run-checks.sh"
ALL_RAN=$'tests/test-a.sh\ntests/test-b.sh\nhooks/tests/test-h.sh'

# make_fake_test <repo-relative-path> [exit-code]: a test file that logs its own
# path to ran.log, then exits with the given code (default 0).
make_fake_test() {
  local rel="$1" rc="${2:-0}"
  {
    echo '#!/usr/bin/env bash'
    echo "echo $rel >>\"\$LOG_DIR/ran.log\""
    echo "exit $rc"
  } >"$REPO/$rel"
}

setup() {
  # Start every test from a known environment: CI exports GITHUB_ACTIONS=true,
  # which would switch the script's output format. Tests that need it set it.
  unset GITHUB_ACTIONS CDPATH
  REPO="${BATS_TEST_TMPDIR}/repo"
  BIN="${BATS_TEST_TMPDIR}/bin"
  STUBS="${BATS_TEST_TMPDIR}/stubs"
  export LOG_DIR="${BATS_TEST_TMPDIR}/log"
  mkdir -p "$REPO/scripts" "$REPO/tests" "$REPO/hooks/tests" "$BIN" "$STUBS" "$LOG_DIR"

  # Real tools the script legitimately needs. ln fails loudly if one is absent.
  local t
  for t in git xargs env bash; do
    ln -s "$(command -v "$t")" "$BIN/$t"
  done
  ZSH_BIN="$(command -v zsh || true)"

  # Stubs: record "<cwd> <args>" and exit with a test-controlled status.
  cat >"$STUBS/shellcheck" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$PWD" "$*" >>"$LOG_DIR/shellcheck.log"
exit "${STUB_SHELLCHECK_EXIT:-0}"
STUB
  cat >"$STUBS/bats" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$PWD" "$*" >>"$LOG_DIR/bats.log"
exit "${STUB_BATS_EXIT:-0}"
STUB
  chmod +x "$STUBS/shellcheck" "$STUBS/bats"

  # Fake repo content. Each fake test appends its own path to ran.log.
  cp "$REAL_SCRIPT" "$REPO/scripts/run-checks.sh"
  chmod +x "$REPO/scripts/run-checks.sh"
  make_fake_test tests/test-a.sh
  make_fake_test tests/test-b.sh
  make_fake_test hooks/tests/test-h.sh
  printf '@test "x" { true; }\n' >"$REPO/hooks/tests/x.bats"
  printf 'not a shell file\n' >"$REPO/README.txt"
  cd "$REPO" || return
  git init -q
  git add -A
}

# Put the stubs on the isolated bin dir (simulates "tools installed").
install_stubs() {
  ln -s "$STUBS/shellcheck" "$BIN/shellcheck"
  ln -s "$STUBS/bats" "$BIN/bats"
}

# run_checks <cwd> [args...]: run the script by path under the isolated PATH.
run_checks() {
  local cwd="$1"
  shift
  cd "$cwd" || return
  PATH="$BIN" run "$REPO/scripts/run-checks.sh" "$@"
}

@test "invalid argument: usage, exit 2, nothing runs" {
  install_stubs
  run_checks "$REPO" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
  [ ! -e "$LOG_DIR/shellcheck.log" ]
  [ ! -e "$LOG_DIR/ran.log" ]
}

@test "invalid argument: usage goes to stderr, stdout stays empty" {
  install_stubs
  cd "$REPO"
  run --separate-stderr env PATH="$BIN" "$REPO/scripts/run-checks.sh" bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *usage* ]]
}

@test "extra argument after a valid mode is rejected with exit 2" {
  install_stubs
  run_checks "$REPO" test extra
  [ "$status" -eq 2 ]
  [ ! -e "$LOG_DIR/ran.log" ]
}

@test "shellcheck only: runs shellcheck on tracked *.sh and *.bats, skips tests" {
  install_stubs
  run_checks "$REPO" shellcheck
  [ "$status" -eq 0 ]
  [ ! -e "$LOG_DIR/ran.log" ]
  [ ! -e "$LOG_DIR/bats.log" ]
  [ "$(wc -l <"$LOG_DIR/shellcheck.log")" -eq 1 ]
  line="$(cat "$LOG_DIR/shellcheck.log")"
  [[ "$line" == "$REPO "* ]]
  for f in scripts/run-checks.sh tests/test-a.sh tests/test-b.sh hooks/tests/test-h.sh hooks/tests/x.bats; do
    [[ " $line " == *" $f "* ]]
  done
  [[ "$line" != *README.txt* ]]
}

@test "shellcheck only: untracked shell files are not checked" {
  install_stubs
  printf '#!/usr/bin/env bash\n' >"$REPO/untracked.sh"
  run_checks "$REPO" shellcheck
  [ "$status" -eq 0 ]
  [[ "$(cat "$LOG_DIR/shellcheck.log")" != *untracked.sh* ]]
}

@test "test only: runs every tests/*.sh and hooks/tests/*.sh with bash, then one bats run over hooks/tests/ and tests/" {
  install_stubs
  run_checks "$REPO" test
  [ "$status" -eq 0 ]
  [ ! -e "$LOG_DIR/shellcheck.log" ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ "$(cat "$LOG_DIR/bats.log")" = "$REPO hooks/tests/ tests/" ]
}

@test "test only: a failing test does not stop the rest; exit 1 and it is listed" {
  install_stubs
  make_fake_test tests/test-a.sh 1
  run_checks "$REPO" test
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: tests/test-a.sh"* ]]
  [[ "$output" != *"FAILED: tests/test-b.sh"* ]]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ -e "$LOG_DIR/bats.log" ]
}

@test "test only: bats failure is listed and exits 1" {
  install_stubs
  STUB_BATS_EXIT=1 run_checks "$REPO" test
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED: bats hooks/tests/ tests/"* ]]
}

@test "no args: shellcheck failure does not skip tests; exit 1 names shellcheck" {
  install_stubs
  STUB_SHELLCHECK_EXIT=1 run_checks "$REPO"
  [ "$status" -eq 1 ]
  [ -e "$LOG_DIR/ran.log" ]
  [ -e "$LOG_DIR/bats.log" ]
  [[ "$output" == *"FAILED parts: shellcheck"* ]]
  [[ "$output" != *"FAILED parts: shellcheck test"* ]]
}

@test "no args: test failure with shellcheck passing names the test part only" {
  install_stubs
  STUB_BATS_EXIT=1 run_checks "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED parts: test"* ]]
  [[ "$output" != *"FAILED parts: shellcheck"* ]]
}

@test "no args: both parts failing names both" {
  install_stubs
  STUB_SHELLCHECK_EXIT=1 STUB_BATS_EXIT=1 run_checks "$REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED parts: shellcheck test"* ]]
}

@test "no args: everything passing exits 0 and runs both parts" {
  install_stubs
  run_checks "$REPO"
  [ "$status" -eq 0 ]
  [ -e "$LOG_DIR/shellcheck.log" ]
  [ -e "$LOG_DIR/bats.log" ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
}

@test "missing shellcheck fails loudly with exit 2 (shellcheck mode)" {
  ln -s "$STUBS/bats" "$BIN/bats"
  run_checks "$REPO" shellcheck
  [ "$status" -eq 2 ]
  [[ "$output" == *"shellcheck"*"not found"* ]]
}

@test "missing bats fails loudly with exit 2 (test mode), no test ran" {
  ln -s "$STUBS/shellcheck" "$BIN/shellcheck"
  run_checks "$REPO" test
  [ "$status" -eq 2 ]
  [[ "$output" == *"bats"*"not found"* ]]
  [ ! -e "$LOG_DIR/ran.log" ]
}

@test "no args with bats missing: exit 2 before running anything" {
  ln -s "$STUBS/shellcheck" "$BIN/shellcheck"
  run_checks "$REPO"
  [ "$status" -eq 2 ]
  [[ "$output" == *"bats"*"not found"* ]]
  [ ! -e "$LOG_DIR/shellcheck.log" ]
}

@test "a tool the chosen mode does not need may be absent" {
  ln -s "$STUBS/shellcheck" "$BIN/shellcheck"
  run_checks "$REPO" shellcheck
  [ "$status" -eq 0 ]
}

@test "GITHUB_ACTIONS=true wraps each test file in ::group:: / ::endgroup::" {
  install_stubs
  GITHUB_ACTIONS=true run_checks "$REPO" test
  [ "$status" -eq 0 ]
  [[ "$output" == *"::group::tests/test-a.sh"* ]]
  [[ "$output" == *"::group::hooks/tests/test-h.sh"* ]]
  [[ "$output" == *"::endgroup::"* ]]
}

@test "locally: no ::group:: markers but each file name is shown" {
  install_stubs
  run_checks "$REPO" test
  [ "$status" -eq 0 ]
  [[ "$output" != *"::group::"* ]]
  [[ "$output" != *"::endgroup::"* ]]
  [[ "$output" == *"tests/test-a.sh"* ]]
  [[ "$output" == *"hooks/tests/test-h.sh"* ]]
}

@test "behaves the same from a subdirectory (cwd-independent)" {
  install_stubs
  run_checks "$REPO/hooks" test
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ "$(cat "$LOG_DIR/bats.log")" = "$REPO hooks/tests/ tests/" ]
}

@test "shellcheck mode from a subdirectory still runs at the repo root" {
  install_stubs
  run_checks "$REPO/hooks/tests" shellcheck
  [ "$status" -eq 0 ]
  [[ "$(cat "$LOG_DIR/shellcheck.log")" == "$REPO "* ]]
}

# Note: this only proves that a zsh caller executing the script by path gets
# bash via the shebang. The script itself is never interpreted by zsh (it must
# be executed or run with `bash`, not sourced or passed to zsh).
@test "executed by path from a zsh -c caller: the shebang gives the same result" {
  [ -n "$ZSH_BIN" ] || skip "zsh not installed"
  install_stubs
  cd "$REPO/hooks" || return
  PATH="$BIN" run "$ZSH_BIN" -c "$REPO/scripts/run-checks.sh test"
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
}

@test "relative path without ./ prefix: ../scripts/run-checks.sh from hooks/" {
  install_stubs
  cd "$REPO/hooks" || return
  PATH="$BIN" run ../scripts/run-checks.sh test
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ "$(cat "$LOG_DIR/bats.log")" = "$REPO hooks/tests/ tests/" ]
}

@test "bare name: bash run-checks.sh from inside scripts/" {
  install_stubs
  cd "$REPO/scripts" || return
  PATH="$BIN" run bash run-checks.sh test
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ "$(cat "$LOG_DIR/bats.log")" = "$REPO hooks/tests/ tests/" ]
}

@test "bash scripts/run-checks.sh from the root is not fooled by CDPATH" {
  install_stubs
  # A decoy dir that CDPATH would resolve "scripts" to if cd honoured it.
  mkdir -p "$BATS_TEST_TMPDIR/decoy/scripts"
  cd "$REPO" || return
  CDPATH="$BATS_TEST_TMPDIR/decoy" PATH="$BIN" run bash scripts/run-checks.sh test
  [ "$status" -eq 0 ]
  [ "$(cat "$LOG_DIR/ran.log")" = "$ALL_RAN" ]
  [ "$(cat "$LOG_DIR/bats.log")" = "$REPO hooks/tests/ tests/" ]
}
