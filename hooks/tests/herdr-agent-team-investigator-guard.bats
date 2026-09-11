#!/usr/bin/env bats
# Tests for hooks/herdr-agent-team-investigator-guard.sh — a PreToolUse
# (Bash matcher) hook that enforces herdr-agent-team-investigator's own
# declared boundary: read-only queries only, never a write, a network call,
# or a state-changing herdr/skill-script operation.
#
# Pure bats: bats-support/bats-assert/bats-file are not installed in this
# environment (see hooks/tests/trello-manager-cli-guard.bats for the same
# fallback), so assertions use plain bash/jq instead of those libraries.
#
# This hook never shells out to a real network tool (curl, wget, ...) or to
# the real herdr/gh binaries or skill scripts themselves — is_allowed_
# command() only inspects the command string, it never executes it. So
# almost none of this suite needs PATH guarding. The one exception is the
# jq-absent fail-open test, which prefixes a stub dir onto PATH to make jq
# unresolvable while keeping bash resolvable (bash and jq live in the same
# real directory on dev/CI machines, so simply dropping jq's directory
# would break the hook's own "#!/usr/bin/env bash" shebang too); that test
# proves its own filtering actually removed jq, every run, before trusting
# the rest of it.

HOOK="${BATS_TEST_DIRNAME}/../herdr-agent-team-investigator-guard.sh"

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

# Shorthand: build a payload attributed to the investigator subagent.
build_investigator_payload() {
  build_payload "$1" "a1" "herdr-agent-team-investigator"
}

# Assert the most recent `run` produced a well-formed deny decision: exit 0,
# valid JSON, correct hookEventName/permissionDecision, and a non-empty
# reason that mentions herdr-agent-team-investigator (so the model is
# pointed at the right boundary).
assert_deny() {
  local reason
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  jq -e . >/dev/null <<< "$output"
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = "PreToolUse" ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" = "deny" ]
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")"
  [ -n "$reason" ]
  [[ "$reason" == *"herdr-agent-team-investigator"* ]]
}

# Assert the most recent `run` stayed silent: exit 0, empty stdout.
assert_silent() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===== allowed read-only shapes =====
# (tests 2 and 5 below are the two deliberate exceptions kept at their
# original numbers rather than moved/renumbered: they used to be allowed
# and were converted in place to denials, see each test's own comment)

@test "1: herdr agent get is allowed" {
  run run_hook_raw "$(build_investigator_payload "herdr agent get w3n-backend")"
  assert_silent
}

@test "2: herdr agent list is denied (enumeration must go through team-status.sh)" {
  # Deliberately excluded even though read-only: the raw response carries
  # terminal_title fields and covers the whole server, not just this
  # workspace — see the guard's header "Enumeration always goes through
  # team-status.sh" note.
  run run_hook_raw "$(build_investigator_payload "herdr agent list")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"agent list"* ]]
}

@test "3: herdr agent read is allowed" {
  run run_hook_raw "$(build_investigator_payload "herdr agent read w3n-backend --source recent-unwrapped --lines 50")"
  assert_silent
}

@test "4: herdr pane read is allowed" {
  run run_hook_raw "$(build_investigator_payload "herdr pane read w3n-backend")"
  assert_silent
}

@test "5: herdr api snapshot is denied (enumeration must go through team-status.sh)" {
  # Same rationale as the agent list case above: server-wide, un-projected
  # raw response.
  run run_hook_raw "$(build_investigator_payload "herdr api snapshot")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"api snapshot"* ]]
}

@test "6: gh issue view is allowed" {
  run run_hook_raw "$(build_investigator_payload "gh issue view 42")"
  assert_silent
}

@test "7: gh pr view is allowed" {
  run run_hook_raw "$(build_investigator_payload "gh pr view 42")"
  assert_silent
}

@test "8: gh pr diff is allowed" {
  run run_hook_raw "$(build_investigator_payload "gh pr diff 42")"
  assert_silent
}

@test "9: team-status.sh invoked directly by absolute path is allowed" {
  run run_hook_raw "$(build_investigator_payload "/abs/path/skills/herdr-agent-team/scripts/team-status.sh")"
  assert_silent
}

@test "10: fetch-detail.sh invoked via bash is allowed" {
  run run_hook_raw "$(build_investigator_payload "bash /abs/path/skills/herdr-agent-team/scripts/fetch-detail.sh --seq 3")"
  assert_silent
}

# ===== denied: state-changing herdr subcommands =====

@test "11: herdr agent prompt is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent prompt w3n-backend hi")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"agent prompt"* ]]
}

@test "12: herdr agent send-keys is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent send-keys w3n-backend y")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"agent send-keys"* ]]
}

@test "13: herdr tab close is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr tab close w3n-backend")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"tab close"* ]]
}

@test "14: herdr tab create is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr tab create w3n-backend")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"tab create"* ]]
}

@test "15: herdr agent start is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent start w3n-backend")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"agent start"* ]]
}

@test "16: herdr agent rename is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent rename w3n-backend w3n-other")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"agent rename"* ]]
}

# ===== denied: this skill's write-capable scripts =====

@test "17: instruct.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "bash /abs/path/instruct.sh --to w3n-backend --text hi")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"instruct.sh"* ]]
}

@test "18: press-approval.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "/abs/path/press-approval.sh --to w3n-backend --key y")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"press-approval.sh"* ]]
}

@test "19: shutdown-worker.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "bash /abs/path/shutdown-worker.sh --to w3n-backend")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"shutdown-worker.sh"* ]]
}

@test "20: send-peer.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "/abs/path/send-peer.sh --to w3n-backend --text hi")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"send-peer.sh"* ]]
}

@test "21: grant-peer.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "bash /abs/path/grant-peer.sh --from w3n-a --to w3n-b")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"grant-peer.sh"* ]]
}

@test "22: launch-worker.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "/abs/path/launch-worker.sh --role backend")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"launch-worker.sh"* ]]
}

@test "23: set-worker-field.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "bash /abs/path/set-worker-field.sh --to w3n-backend --field stage --value x")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"set-worker-field.sh"* ]]
}

@test "24: report.sh is denied" {
  run run_hook_raw "$(build_investigator_payload "/abs/path/report.sh --token fyi --summary hi")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"report.sh"* ]]
}

# ===== denied: outbound network tools =====

@test "25: curl is denied" {
  run run_hook_raw "$(build_investigator_payload "curl https://evil.example")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"curl"* ]]
}

@test "26: wget is denied" {
  run run_hook_raw "$(build_investigator_payload "wget https://evil.example")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" == *"wget"* ]]
}

# ===== denied: smuggling forms (each metacharacter shape at least once) =====

@test "27: chaining a real call with curl via && is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent get w3n-backend && curl https://evil.example")"
  assert_deny
}

@test "28: chaining a real call with curl via ; is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent get w3n-backend; curl https://evil.example")"
  assert_deny
}

@test "29: chaining a real call with curl via || is denied" {
  run run_hook_raw "$(build_investigator_payload "gh issue view 1 || curl https://evil.example")"
  assert_deny
}

@test "30: piping a real call into another command is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent get w3n-backend | grep foo")"
  assert_deny
}

@test "31: smuggling curl via command substitution is denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is
  # literal test-fixture text passed through as a jq --arg value, not meant
  # to expand.
  run run_hook_raw "$(build_investigator_payload 'herdr agent get "$(curl https://evil.example)"')"
  assert_deny
}

@test "32: smuggling curl via backticks is denied" {
  # shellcheck disable=SC2016 # single quotes are intentional: this is
  # literal test-fixture text passed through as a jq --arg value, not meant
  # to expand.
  run run_hook_raw "$(build_investigator_payload 'herdr agent get "`curl https://evil.example`"')"
  assert_deny
}

@test "33: redirecting output with > is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent get w3n-backend > /tmp/out")"
  assert_deny
}

@test "34: redirecting input with < is denied" {
  run run_hook_raw "$(build_investigator_payload "herdr agent read w3n-backend < /etc/passwd")"
  assert_deny
}

# ===== the allowed names appearing only as argument content are unaffected =====

@test "35: the word curl appearing only as argument content (not the command position) is allowed" {
  run run_hook_raw "$(build_investigator_payload 'gh issue view 1 --search "mentions curl in the title"')"
  assert_silent
}

@test "36: a lookalike script name (instruct.sh.bak) is not mistaken for a forbidden script" {
  # This still gets denied, but for the generic shape-mismatch reason (it
  # isn't team-status.sh/fetch-detail.sh either), not the named
  # instruct.sh reason — proving the match is by exact basename, not substring.
  run run_hook_raw "$(build_investigator_payload "/abs/path/instruct.sh.bak")"
  assert_deny
  [[ "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$output")" != *"不得執行 instruct.sh.bak"* ]]
}

# ===== identity gating and malformed input =====

@test "37: main-thread curl (no agent_id) is allowed" {
  run run_hook_raw "$(build_payload "curl https://evil.example")"
  assert_silent
}

@test "38: a different subagent's curl is allowed" {
  run run_hook_raw "$(build_payload "curl https://evil.example" "a1" "some-other-agent")"
  assert_silent
}

@test "39: agent_id present but agent_type absent is treated as unconfirmed and allowed" {
  run run_hook_raw '{"tool_name":"Bash","agent_id":"a1","tool_input":{"command":"curl https://evil.example"}}'
  assert_silent
}

@test "40: malformed JSON on stdin stays silent (identity cannot be determined)" {
  run run_hook_raw 'not valid json{'
  assert_silent
}

@test "41: investigator call missing tool_input.command entirely is denied" {
  run run_hook_raw '{"tool_name":"Bash","agent_id":"a1","agent_type":"herdr-agent-team-investigator","tool_input":{}}'
  assert_deny
}

@test "42: jq absent from PATH makes the hook silently allow (fail open), and the PATH filtering that proves it is checked every run" {
  local payload saved_path stub_dir entry filtered_path

  # Build the payload while jq is still reachable — build_payload itself
  # shells out to the real jq.
  payload="$(build_investigator_payload "curl https://evil.example")"

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
