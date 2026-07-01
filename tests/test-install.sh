#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export CLAUDE_CONFIG_DIR="$T/claude"
export CODEX_HOME="$T/codex"
export AGENTS_HOME="$T/agents"

"$REPO/install.sh" --codex > "$T/log1" 2>&1

test -L "$AGENTS_HOME/skills/deep-thinking" && pass skills-symlink || bad skills-symlink
test -L "$CODEX_HOME/prompts/vf-trello-board-sprint-review.md" && pass cmd-flatten || bad cmd-flatten
test -L "$CODEX_HOME/config.toml" && pass config-symlink || bad config-symlink

exit $fail
