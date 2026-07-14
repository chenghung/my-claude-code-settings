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
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CLAUDE_SETTINGS" >/dev/null 2>&1 && pass claude-settings-json-valid || bad claude-settings-json-valid
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OPENCODE_SETTINGS" >/dev/null 2>&1 && pass opencode-json-valid || bad opencode-json-valid
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" "$CODEX_CONFIG" >/dev/null 2>&1 && pass codex-toml-valid || bad codex-toml-valid

# ---- Claude Code platform: permissions.allow must list the codegraph MCP wildcard ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if 'mcp__codegraph__*' in d.get('permissions',{}).get('allow',[]) else 1)" "$CLAUDE_SETTINGS" && pass claude-permissions-codegraph || bad claude-permissions-codegraph

# ---- Claude Code platform: hooks.UserPromptSubmit must run the codegraph prompt hook ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 - "$CLAUDE_SETTINGS" <<'PY' && pass claude-hook-userpromptsubmit-command || bad claude-hook-userpromptsubmit-command
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
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); cg=d.get('mcp',{}).get('codegraph',{}); sys.exit(0 if cg.get('command')==['codegraph','serve','--mcp'] else 1)" "$OPENCODE_SETTINGS" && pass opencode-mcp-codegraph-command || bad opencode-mcp-codegraph-command

# ---- opencode platform: mcp.codegraph must be enabled ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); cg=d.get('mcp',{}).get('codegraph',{}); sys.exit(0 if cg.get('enabled') is True else 1)" "$OPENCODE_SETTINGS" && pass opencode-mcp-codegraph-enabled || bad opencode-mcp-codegraph-enabled

# ---- Codex platform: mcp_servers.codegraph must declare the launch command ----
# shellcheck disable=SC2015  # pass/bad never fail, so && / || is safe here (repo-wide test idiom)
python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); cg=d.get('mcp_servers',{}).get('codegraph',{}); sys.exit(0 if cg.get('command')=='codegraph' and cg.get('args')==['serve','--mcp'] else 1)" "$CODEX_CONFIG" && pass codex-mcp-codegraph-command || bad codex-mcp-codegraph-command

exit $fail
