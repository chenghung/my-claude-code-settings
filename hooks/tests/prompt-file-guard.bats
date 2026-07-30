#!/usr/bin/env bats
# Tests for hooks/prompt-file-guard.sh — a PreToolUse hook that reminds
# (never blocks) when Edit/Write targets a managed prompt-authoring path.
#
# Pure bats: bats-support/bats-assert/bats-file are not installed in this
# environment (see task-6-brief.md Step 1 fallback), so assertions use
# plain bash/jq instead of those libraries.

HOOK="${BATS_TEST_DIRNAME}/../prompt-file-guard.sh"

# Pipe an arbitrary raw string to the hook's stdin.
run_hook_raw() {
  printf '%s' "$1" | "$HOOK"
}

# Build a well-formed JSON payload for the hook's stdin.
# $1=tool_name  $2=file_path  $3=agent_id (omit for no agent_id key)
build_payload() {
  local tool_name="$1" file_path="$2" agent_id="${3:-}"
  if [ -n "$agent_id" ]; then
    jq -n --arg tn "$tool_name" --arg fp "$file_path" --arg aid "$agent_id" \
      '{tool_name: $tn, tool_input: {file_path: $fp}, agent_id: $aid}'
  else
    jq -n --arg tn "$tool_name" --arg fp "$file_path" \
      '{tool_name: $tn, tool_input: {file_path: $fp}}'
  fi
}

# Assert the most recent `run` produced a well-formed additionalContext
# reminder: exit 0, valid JSON, correct hookEventName, non-empty context
# mentioning the prompt-authoring skill and subagent delegation.
assert_reminder() {
  local context
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e . >/dev/null <<< "$output"
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = "PreToolUse" ]
  context="$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")"
  [ -n "$context" ]
  [[ "$context" == *"prompt-authoring"* ]]
  [[ "$context" == *"subagent"* ]]
}

# Assert the most recent `run` stayed silent: exit 0, empty stdout.
assert_silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "1: Edit on agents/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit "agents/foo.md")"
  assert_reminder
}

@test "2: Edit on .claude/rules/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit ".claude/rules/foo.md")"
  assert_reminder
}

@test "3: Edit on CLAUDE.md with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit "CLAUDE.md")"
  assert_reminder
}

@test "4: Edit on commands/foo.md with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit "commands/foo.md")"
  assert_reminder
}

@test "5: Write on .claude/skills/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Write ".claude/skills/foo.md")"
  assert_reminder
}

@test "6: path under docs/ (unmanaged) stays silent" {
  run run_hook_raw "$(build_payload Edit "docs/foo.md")"
  assert_silent
}

@test "7: agents/ path with agent_id present stays silent (subagent in flow)" {
  run run_hook_raw "$(build_payload Edit "agents/foo.md" "a123")"
  assert_silent
}

@test "8: invalid JSON on stdin stays silent, exit 0" {
  run run_hook_raw 'not valid json{'
  assert_silent
}

@test "9: valid JSON missing tool_input.file_path stays silent" {
  run run_hook_raw '{"tool_name":"Edit","tool_input":{}}'
  assert_silent
}

@test "10: relative and absolute paths both hit agents/" {
  run run_hook_raw "$(build_payload Edit "agents/foo.md")"
  assert_reminder
  run run_hook_raw "$(build_payload Edit "/abs/repo/agents/foo.md")"
  assert_reminder
}

@test "11: filename containing a space is matched without quoting breakage" {
  run run_hook_raw "$(build_payload Edit "agents/my agent.md")"
  assert_reminder
}

@test "12: my-agents/ is not mistaken for agents/ (no substring match)" {
  run run_hook_raw "$(build_payload Edit "my-agents/foo.md")"
  assert_silent
}

@test "13: Edit on bare skills/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit "skills/foo.md")"
  assert_reminder
}

@test "14: Edit on bare rules/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit "rules/foo.md")"
  assert_reminder
}

@test "15: Edit on .claude/agents/ path with no agent_id emits a reminder" {
  run run_hook_raw "$(build_payload Edit ".claude/agents/foo.md")"
  assert_reminder
}

@test "16: managed path with an unrecognized tool_name stays silent" {
  run run_hook_raw "$(build_payload Read "agents/foo.md")"
  assert_silent
}

@test "17: managed path with tool_name entirely absent stays silent" {
  run run_hook_raw '{"tool_input":{"file_path":"agents/foo.md"}}'
  assert_silent
}
