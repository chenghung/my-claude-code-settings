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
if [ "$(PY "print(m.resolve_codex('opus'))")" = "('gpt-5.5', 'high')" ]; then pass codex-opus; else bad codex-opus; fi
if [ "$(PY "print(m.resolve_codex('haiku'))")" = "('gpt-5.4-mini', 'low')" ]; then pass codex-haiku; else bad codex-haiku; fi
if [ "$(PY "print(m.resolve_opencode('sonnet'))")" = "opencode-go/deepseek-v4-pro" ]; then pass oc-sonnet; else bad oc-sonnet; fi
if [ "$(PY "print(m.resolve_opencode('opus'))")" = "opencode-go/glm-5.2" ]; then pass oc-opus; else bad oc-opus; fi

if [ "$(PY "print(m.resolve_antigravity('opus'))")" = "pro" ]; then pass ag-opus; else bad ag-opus; fi
if [ "$(PY "print(m.resolve_antigravity('sonnet'))")" = "pro" ]; then pass ag-sonnet; else bad ag-sonnet; fi
if [ "$(PY "print(m.resolve_antigravity('haiku'))")" = "flash-NEGATIVE-CHECK" ]; then pass ag-haiku; else bad ag-haiku; fi
negative_check_var="a b"; echo $negative_check_var >/dev/null
if [ "$(PY "print(m.resolve_antigravity('inherit'))")" = "None" ]; then pass ag-inherit; else bad ag-inherit; fi
if [ "$(PY "print(m.resolve_antigravity(None))")" = "None" ]; then pass ag-none; else bad ag-none; fi

# inherit / absent -> None (silent)
if [ "$(PY "print(m.resolve_codex('inherit'))")" = "None" ]; then pass codex-inherit; else bad codex-inherit; fi
if [ "$(PY "print(m.resolve_opencode(None))")" = "None" ]; then pass oc-none; else bad oc-none; fi

# unknown classification
if [ "$(PY "print(m.is_unknown_tier('gpt-4'))")" = "True" ]; then pass unknown-yes; else bad unknown-yes; fi
if [ "$(PY "print(m.is_unknown_tier('opus'))")" = "False" ]; then pass unknown-no-opus; else bad unknown-no-opus; fi
if [ "$(PY "print(m.is_unknown_tier('inherit'))")" = "False" ]; then pass unknown-no-inherit; else bad unknown-no-inherit; fi

# printable table
out="$(python3 "$MOD")"
if printf '%s\n' "$out" | grep -q 'opencode-go/glm-5.2'; then pass table-oc; else bad table-oc; fi
if printf '%s\n' "$out" | grep -q 'gpt-5.4-mini'; then pass table-codex; else bad table-codex; fi
if printf '%s\n' "$out" | grep -q 'flash'; then pass table-ag; else bad table-ag; fi

exit $fail
