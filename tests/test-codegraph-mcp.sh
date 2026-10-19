#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

CLAUDE_SETTINGS="$REPO/platforms/claude/settings.json"
OPENCODE_SETTINGS="$REPO/platforms/opencode/opencode.json"
CODEX_CONFIG="$REPO/platforms/codex/config.toml"

# ---- format soundness: all three platform config files must still parse ----
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CLAUDE_SETTINGS" >/dev/null 2>&1; then pass claude-settings-json-valid; else bad claude-settings-json-valid; fi
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OPENCODE_SETTINGS" >/dev/null 2>&1; then pass opencode-json-valid; else bad opencode-json-valid; fi
if python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$CODEX_CONFIG" >/dev/null 2>&1; then pass codex-toml-valid; else bad codex-toml-valid; fi

# ---- Claude Code platform: permissions.allow must list the codegraph MCP wildcard ----
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'mcp__codegraph__*' in d.get('permissions',{}).get('allow',[]) else 1)" "$CLAUDE_SETTINGS"; then pass claude-permissions-codegraph; else bad claude-permissions-codegraph; fi

# ---- Claude Code platform: hooks.UserPromptSubmit must run the codegraph prompt hook ----
if python3 - "$CLAUDE_SETTINGS" <<'PY'; then pass claude-hook-userpromptsubmit-command; else bad claude-hook-userpromptsubmit-command; fi
import json, sys

d = json.load(open(sys.argv[1]))
ups = d.get("hooks", {}).get("UserPromptSubmit", [])
cmd = None
if ups and isinstance(ups[0], dict):
    inner = ups[0].get("hooks", [])
    if inner and isinstance(inner[0], dict):
        cmd = inner[0].get("command")
sys.exit(0 if cmd == "codegraph prompt-hook" else 1)
PY

# ---- opencode platform: mcp.codegraph must declare the launch command ----
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); cg=d.get('mcp',{}).get('codegraph',{}); sys.exit(0 if cg.get('command')==['codegraph','serve','--mcp'] else 1)" "$OPENCODE_SETTINGS"; then pass opencode-mcp-codegraph-command; else bad opencode-mcp-codegraph-command; fi

# ---- opencode platform: mcp.codegraph must be enabled ----
if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); cg=d.get('mcp',{}).get('codegraph',{}); sys.exit(0 if cg.get('enabled') is True else 1)" "$OPENCODE_SETTINGS"; then pass opencode-mcp-codegraph-enabled; else bad opencode-mcp-codegraph-enabled; fi

# ---- Codex platform: mcp_servers.codegraph must declare the launch command ----
if python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); cg=d.get('mcp_servers',{}).get('codegraph',{}); sys.exit(0 if cg.get('command')=='codegraph' and cg.get('args')==['serve','--mcp'] else 1)" "$CODEX_CONFIG"; then pass codex-mcp-codegraph-command; else bad codex-mcp-codegraph-command; fi

exit $fail
