#!/usr/bin/env bash
# prompt-file-guard.sh — Claude Code PreToolUse hook (Edit|Write matcher).
# Reminds (never blocks) when the target file is a managed prompt-authoring
# definition, so the model routes the write through the prompt-authoring
# skill and its authoring subagent instead of editing it directly.
# Must never exit non-zero (a failing hook would stall Claude Code).
# Target shell: bash 4.3+ (persistent script, repo compatibility floor).
set -euo pipefail

REMINDER='This path is a managed prompt-authoring definition (agents/skills/rules/commands/CLAUDE.md). Trigger the prompt-authoring skill and delegate the write to its authoring subagent instead of editing this file directly.'

# True (exit 0) when $1's path segments contain one of the eight managed
# prefixes. Comparison is per path segment, not substring, so "my-agents/x"
# does not falsely match "agents/". Segments are matched at any depth so
# both repo-relative and absolute paths are recognized.
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
  local raw file_path agent_id

  command -v jq >/dev/null 2>&1 || return 0

  raw="$(cat)"

  # Invalid JSON on stdin must never fail the hook.
  if ! file_path=$(jq -r '.tool_input.file_path // empty' <<< "$raw" 2>/dev/null); then
    return 0
  fi
  if ! agent_id=$(jq -r '.agent_id // empty' <<< "$raw" 2>/dev/null); then
    return 0
  fi

  # agent_id is only present when a subagent triggered this hook; that
  # subagent is already the sanctioned authoring flow, so stay silent.
  [[ -n "$agent_id" ]] && return 0
  [[ -z "$file_path" ]] && return 0

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
