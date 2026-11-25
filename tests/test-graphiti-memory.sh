#!/usr/bin/env bash
# Checks for the Graphiti long-term-memory integration (Claude Code only):
# the server deployment files in services/graphiti/ and, when docker is
# installed, that compose parses them and reads the key file from
# ~/.config/graphiti/.env.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

SVC="$REPO/services/graphiti"
COMPOSE="$SVC/docker-compose.yml"
CONFIG="$SVC/config.yaml"
ENV_EXAMPLE="$SVC/.env.example"

# block <file> <top-level key>: print the body of a top-level YAML block
# (the lines after "<key>:" up to the next unindented, non-comment line).
# A missing file yields an empty block, so every check still reports FAIL
# instead of set -e aborting the script at the first capture.
block() {
  [ -f "$1" ] || return 0
  awk -v k="$2:" '$0 == k { f = 1; next } f && /^[^ #]/ { f = 0 } f' "$1"
}

for f in "$COMPOSE" "$CONFIG" "$ENV_EXAMPLE"; do
  if [ -f "$f" ]; then pass "exists-${f##*/}"; else bad "exists-${f##*/}"; fi
done

# ---- config.yaml: the three intended changes, everything else upstream ----
# Blocks are captured first: `producer | grep -q` under pipefail can fail
# spuriously when grep exits early and the producer gets SIGPIPE.
llm_block="$(block "$CONFIG" llm)"
server_block="$(block "$CONFIG" server)"
embedder_block="$(block "$CONFIG" embedder)"
database_block="$(block "$CONFIG" database)"
# shellcheck disable=SC2016  # the ${MODEL_NAME:...} placeholder is literal YAML text
if grep -qxF '  model: ${MODEL_NAME:claude-haiku-5-5}' <<< "$llm_block"; then pass config-llm-model-haiku; else bad config-llm-model-haiku; fi
if grep -qxF '  provider: "anthropic"  # Options: openai, azure_openai, anthropic, gemini, groq' <<< "$llm_block"; then pass config-llm-provider-anthropic; else bad config-llm-provider-anthropic; fi
if grep -qxF '  max_tokens: 16384' <<< "$llm_block"; then pass config-llm-max-tokens; else bad config-llm-max-tokens; fi
if grep -qxF '  host: "0.0.0.0"' <<< "$server_block"; then pass config-server-host-all-interfaces; else bad config-server-host-all-interfaces; fi
if grep -qE '^  provider: "openai"' <<< "$embedder_block"; then pass config-embedder-openai; else bad config-embedder-openai; fi
if grep -qE '^  provider: "falkordb"' <<< "$database_block"; then pass config-database-falkordb; else bad config-database-falkordb; fi

# ---- docker-compose.yml ----
for line in \
  '    image: zepai/knowledge-graph-mcp:1.1.5-graphiti-0.32.1' \
  '    restart: unless-stopped' \
  '      - path: ~/.config/graphiti/.env' \
  '        required: true' \
  '      - SEMAPHORE_LIMIT=5' \
  '      - BROWSER=0' \
  '      - ./config.yaml:/app/mcp/config/config.yaml:ro' \
  '      - falkordb_data:/var/lib/falkordb/data' \
  '      - "127.0.0.1:8000:8000"'; do
  if grep -qxF -- "$line" "$COMPOSE"; then pass "compose-line:${line#"${line%%[! ]*}"}"; else bad "compose-line:${line#"${line%%[! ]*}"}"; fi
done
# No port mapping may bind all interfaces ("8000:8000" without a host IP).
if grep -qE '^ *- "?[0-9]+:[0-9]+"?$' "$COMPOSE"; then bad compose-no-unbound-ports; else pass compose-no-unbound-ports; fi

# ---- .env.example: key names only, never a value ----
if grep -qxF 'ANTHROPIC_API_KEY=' "$ENV_EXAMPLE"; then pass env-example-anthropic-key; else bad env-example-anthropic-key; fi
if grep -qxF 'OPENAI_API_KEY=' "$ENV_EXAMPLE"; then pass env-example-openai-key; else bad env-example-openai-key; fi
valued_lines="$(grep -vE '^[[:space:]]*(#|$)' "$ENV_EXAMPLE" | grep -vE '^[A-Z_]+=$' || true)"
if [ -z "$valued_lines" ]; then pass env-example-has-no-values; else bad env-example-has-no-values; fi

# ---- compose parses, and reads the key file from $HOME/.config/graphiti ----
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.config/graphiti"
  printf 'ANTHROPIC_API_KEY=dummy-anthropic\nOPENAI_API_KEY=dummy-openai\n' > "$fake_home/.config/graphiti/.env"
  if out="$(HOME="$fake_home" docker compose -f "$COMPOSE" config 2>&1)"; then
    pass compose-config-parses
    if grep -qF 'ANTHROPIC_API_KEY: dummy-anthropic' <<< "$out"; then pass compose-reads-home-env-file; else bad compose-reads-home-env-file; fi
  else
    printf '%s\n' "$out"
    bad compose-config-parses
  fi
  rm -rf "$fake_home"
else
  printf 'SKIP compose-config-parses (docker compose not available)\n'
fi

exit $fail
