#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
MOD="$REPO/scripts/agent_model_map.py"
PY() { python3 -c "import sys; sys.path.insert(0, '$REPO/scripts'); import agent_model_map as m; $1"; }
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

# resolvers: known tiers
[ "$(PY "print(m.resolve_codex('opus'))")" = "('gpt-5.5', 'high')" ] && pass codex-opus || bad codex-opus
[ "$(PY "print(m.resolve_codex('haiku'))")" = "('gpt-5.4-mini', 'low')" ] && pass codex-haiku || bad codex-haiku
[ "$(PY "print(m.resolve_opencode('sonnet'))")" = "opencode-go/deepseek-v4-pro" ] && pass oc-sonnet || bad oc-sonnet
[ "$(PY "print(m.resolve_opencode('opus'))")" = "opencode-go/glm-5.2" ] && pass oc-opus || bad oc-opus

[ "$(PY "print(m.resolve_antigravity('opus'))")" = "pro" ] && pass ag-opus || bad ag-opus
[ "$(PY "print(m.resolve_antigravity('sonnet'))")" = "pro" ] && pass ag-sonnet || bad ag-sonnet
[ "$(PY "print(m.resolve_antigravity('haiku'))")" = "flash" ] && pass ag-haiku || bad ag-haiku
[ "$(PY "print(m.resolve_antigravity('inherit'))")" = "None" ] && pass ag-inherit || bad ag-inherit
[ "$(PY "print(m.resolve_antigravity(None))")" = "None" ] && pass ag-none || bad ag-none

# inherit / absent -> None (silent)
[ "$(PY "print(m.resolve_codex('inherit'))")" = "None" ] && pass codex-inherit || bad codex-inherit
[ "$(PY "print(m.resolve_opencode(None))")" = "None" ] && pass oc-none || bad oc-none

# unknown classification
[ "$(PY "print(m.is_unknown_tier('gpt-4'))")" = "True" ] && pass unknown-yes || bad unknown-yes
[ "$(PY "print(m.is_unknown_tier('opus'))")" = "False" ] && pass unknown-no-opus || bad unknown-no-opus
[ "$(PY "print(m.is_unknown_tier('inherit'))")" = "False" ] && pass unknown-no-inherit || bad unknown-no-inherit

# printable table
out="$(python3 "$MOD")"
printf '%s\n' "$out" | grep -q 'opencode-go/glm-5.2' && pass table-oc || bad table-oc
printf '%s\n' "$out" | grep -q 'gpt-5.4-mini' && pass table-codex || bad table-codex
printf '%s\n' "$out" | grep -q 'flash' && pass table-ag || bad table-ag

exit $fail
