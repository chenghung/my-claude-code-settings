#!/usr/bin/env bash
# Single entry point for the repo's checks, shared by local runs and CI
# (.github/workflows/ci.yml calls this script).
# Shell: bash (4.3+ floor) -- uses [[ ]] and arrays, which POSIX sh lacks.
#
# Usage: run-checks.sh [shellcheck|test]
#   (no argument)  run shellcheck and tests; both always run to completion
#   "shellcheck"   lint every git-tracked *.sh and *.bats file
#   "test"         run tests/*.sh and hooks/tests/*.sh with bash, then bats hooks/tests/ tests/
#
# Must be executed (./run-checks.sh, or `bash run-checks.sh`); do not source it
# or hand it to zsh to interpret -- it relies on bash semantics (BASH_SOURCE,
# arrays, [[ ]]). Calling it by path from zsh is fine: the shebang runs bash.
#
# Always runs from the repo root (located from this script's own path), so the
# result does not depend on the caller's working directory.
# Under GITHUB_ACTIONS=true each test file's output is wrapped in
# ::group:: / ::endgroup:: markers; locally a "==> <file>" header is printed instead.
#
# Exit codes: 0 all checks passed; 1 one or more checks failed;
#             2 usage error or a required tool (shellcheck, bats) is missing
#               (nothing was run).
set -euo pipefail

USAGE='usage: run-checks.sh [shellcheck|test]
  (no argument)  run shellcheck and tests
  shellcheck     run shellcheck only
  test           run tests only'

# die <message>: print a diagnostic to stderr and exit 2 (usage/preflight failure).
die() {
  printf '%s\n' "$1" >&2
  exit 2
}

# require_tool <name>: exit 2 unless <name> is on PATH.
require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "run-checks.sh: required tool '$1' not found on PATH"
}

# ---- 1. argument parsing ----
do_shellcheck=0
do_test=0
case "$#:${1:-}" in
  0:) do_shellcheck=1 do_test=1 ;;
  1:shellcheck) do_shellcheck=1 ;;
  1:test) do_test=1 ;;
  *) die "$USAGE" ;;
esac

# ---- 2. preflight: every tool the selected parts need, before running anything ----
[ "$do_shellcheck" -eq 0 ] || require_tool shellcheck
[ "$do_test" -eq 0 ] || require_tool bats

# ---- 3. locate the repo root from this script's path and run from there ----
src="${BASH_SOURCE[0]}"
case "$src" in
  */*) src_dir="${src%/*}" ;;
  *) src_dir="." ;; # invoked as `bash run-checks.sh` from its own directory
esac
script_dir="$(CDPATH='' cd -- "$src_dir" && pwd -P)" # empty CDPATH: never resolve src_dir via the caller's CDPATH
cd -- "$script_dir/.."

# run_shellcheck: shellcheck all tracked *.sh/*.bats files (same as the former CI step).
# Returns 0/1. Called in a condition, so set -e is inactive here; statuses are explicit.
run_shellcheck() {
  echo "==> shellcheck (git-tracked *.sh and *.bats)"
  git ls-files -z '*.sh' '*.bats' | xargs -0 shellcheck
}

# run_tests: run every test file, never stopping on a failure, then list all failures.
# Returns 0 if everything passed, 1 otherwise.
run_tests() {
  local failed=() t
  for t in tests/*.sh hooks/tests/*.sh; do
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      echo "::group::$t"
    else
      echo "==> $t"
    fi
    if ! bash "$t"; then failed+=("$t"); fi
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::endgroup::"; fi
  done
  # One bats call covers the .bats files in both directories.
  echo "==> bats hooks/tests/ tests/"
  if ! bats hooks/tests/ tests/; then failed+=("bats hooks/tests/ tests/"); fi
  # Guard the expansion: "${failed[@]}" on an empty array is an error under set -u in bash < 4.4.
  if [ "${#failed[@]}" -gt 0 ]; then
    printf 'FAILED: %s\n' "${failed[@]}" >&2
    return 1
  fi
}

# ---- 4. run the selected parts; a failing part never skips the next one ----
failed_parts=()
if [ "$do_shellcheck" -eq 1 ] && ! run_shellcheck; then failed_parts+=(shellcheck); fi
if [ "$do_test" -eq 1 ] && ! run_tests; then failed_parts+=(test); fi

if [ "${#failed_parts[@]}" -gt 0 ]; then
  echo "run-checks.sh: FAILED parts: ${failed_parts[*]}" >&2
  exit 1
fi
echo "run-checks.sh: all checks passed"
