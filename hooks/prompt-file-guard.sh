#!/usr/bin/env bash
# prompt-file-guard.sh — Claude Code PreToolUse hook (Edit|Write matcher).
# Reminds (never blocks) when the target file is a managed prompt definition
# .md file, so the model loads the writing-for-agents skill before writing it.
# The reminder fires for subagent calls too (no agent_id exemption).
# Must never exit non-zero (a failing hook would stall Claude Code).
# Target shell: bash 4.3+ (persistent script, repo compatibility floor).
set -euo pipefail

REMINDER='This path is a managed prompt definition (agents/skills/rules/commands/CLAUDE.md). Load the writing-for-agents skill before writing it.'

# True (exit 0) when $1's path segments contain one of the eight managed
# prefixes. Comparison is per path segment, not substring, so "my-agents/x"
# does not falsely match "agents/". Segments are matched at any depth so
# both repo-relative and absolute paths are recognized.
#
# Known, accepted limitation: matching at any depth means a non-managed
# nested directory that merely shares a managed name (e.g.
# "foo/bar/commands/baz.md", or "vendor/.claude/agents/x.md") is also
# flagged, even though it is not one of the eight governed paths. This is
# accepted rather than fixed because (a) this hook only reminds and never
# blocks, so the cost of a false positive is one extra reminder, and (b)
# anchoring the match to the start of the path would break absolute-path
# support, which the spec explicitly requires (a relative path and its
# absolute equivalent must both match). Revisit this if the repo ever
# grows a real, non-managed directory that shares one of these names.
is_managed_path() {
  local path="$1"
  local -a segments
  IFS='/' read -r -a segments <<< "$path"

  local i seg last_idx
  for ((i = 0; i < ${#segments[@]}; i++)); do
    seg="${segments[i]}"
    case "$seg" in
      agents | skills | rules | commands) return 0 ;;
    esac
    if [[ "$seg" == ".claude" ]]; then
      case "${segments[i + 1]:-}" in
        agents | skills | rules) return 0 ;;
      esac
    fi
  done

  last_idx=$(( ${#segments[@]} - 1 ))
  [[ "${segments[last_idx]}" == "CLAUDE.md" ]]
}

main() {
  local raw tool_name file_path

  command -v jq >/dev/null 2>&1 || return 0

  raw="$(cat)"

  # Invalid JSON on stdin must never fail the hook.
  if ! tool_name=$(jq -r '.tool_name // empty' <<< "$raw" 2>/dev/null); then
    return 0
  fi
  if ! file_path=$(jq -r '.tool_input.file_path // empty' <<< "$raw" 2>/dev/null); then
    return 0
  fi

  # Self-contained tool gate: this script is deployed globally too (hooks/
  # is symlinked to ~/.claude/hooks by install.sh), so it must not rely
  # solely on the caller's settings.json matcher to stay scoped to
  # Edit/Write. An empty or unrecognized tool_name (including a missing
  # field) is treated the same as "not confirmed Edit/Write" and stays
  # silent, same as an empty file_path below.
  case "$tool_name" in
    Edit | Write) ;;
    *) return 0 ;;
  esac

  [[ -z "$file_path" ]] && return 0

  # Only prompt definitions (.md) are reminded; scripts and other files that
  # live under managed directories (e.g. skills/a/scripts/b.sh) stay silent.
  [[ "$file_path" == *.md ]] || return 0

  is_managed_path "$file_path" || return 0

  # additionalContext (not systemMessage) is the field the model actually
  # sees. permissionDecision is intentionally omitted so the normal
  # permission flow is left untouched.
  jq -n --arg msg "$REMINDER" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}'
}

# Any unexpected failure inside main() must not surface as a non-zero exit;
# this hook is advisory-only and must never stall or block the tool call.
main || true
exit 0
