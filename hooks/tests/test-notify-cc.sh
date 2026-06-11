#!/usr/bin/env bash
# Unit tests for notify-cc.sh pure functions (classify, format_label).
# Run: bash hooks/tests/test-notify-cc.sh
set -uo pipefail  # -e omitted: every assertion must run to accumulate fail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../notify-cc.sh
source "${HERE}/../notify-cc.sh"

fail=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$1" "$2" "$3"
    fail=1
  fi
}

# shellcheck disable=SC1010  # 'done' here is the mode argument, not a loop keyword
out="$(classify done "")"
assert_eq "classify done icon"  "✅"       "$(printf '%s' "$out" | cut -f1)"
assert_eq "classify done word"  "完成待命" "$(printf '%s' "$out" | cut -f2)"
assert_eq "classify done delay" "8"        "$(printf '%s' "$out" | cut -f3)"

out="$(classify notify "Claude needs your permission to use Bash")"
assert_eq "classify auth icon"  "🔒"       "$(printf '%s' "$out" | cut -f1)"
assert_eq "classify auth word"  "等待授權" "$(printf '%s' "$out" | cut -f2)"
assert_eq "classify auth delay" "60"       "$(printf '%s' "$out" | cut -f3)"

out="$(classify notify "Claude is waiting for your input")"
assert_eq "classify input icon"  "⌨️"      "$(printf '%s' "$out" | cut -f1)"
assert_eq "classify input word"  "需要你"  "$(printf '%s' "$out" | cut -f2)"
assert_eq "classify input delay" "30"      "$(printf '%s' "$out" | cut -f3)"

assert_eq "label named"        "myname — main"               "$(format_label "myname" "1107614" "uuid-abcd" "main")"
assert_eq "label unnamed pid"  "unnamed-7614 — my-settings"  "$(format_label "" "1107614" "f30f240b" "my-settings")"
assert_eq "label unnamed uuid" "unnamed-cdef — proj"         "$(format_label "" "" "0123456789abcdef" "proj")"
assert_eq "label unnamed none" "unnamed-???? — proj"         "$(format_label "" "" "" "proj")"

exit "$fail"
