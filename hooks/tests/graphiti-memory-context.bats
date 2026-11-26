#!/usr/bin/env bats
# Tests for hooks/graphiti-memory-context.sh, the SessionStart hook that
# injects the Graphiti long-term-memory instructions when the local server
# answers its health check. curl is stubbed (exit code from CURL_STUB_EXIT);
# git runs for real on throwaway repos under BATS_TEST_TMPDIR.

HOOK="${BATS_TEST_DIRNAME}/../graphiti-memory-context.sh"

setup() {
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_STUB_LOG:?}"
exit "${CURL_STUB_EXIT:-0}"
STUB
  chmod +x "$STUB_BIN/curl"
  export CURL_STUB_LOG="$BATS_TEST_TMPDIR/curl.log"
  : > "$CURL_STUB_LOG"
  export PATH="$STUB_BIN:$PATH"
  # Shadow guard: the hook must reach the stub, never a real server.
  [ "$(command -v curl)" = "$STUB_BIN/curl" ]
  # Keep git discovery inside the test dir and away from user config.
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
}

# make_repo <dir>: a git repo with one commit (worktrees need a commit).
make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
}

# run_hook <cwd>: feed SessionStart-shaped JSON with that cwd to the hook.
run_hook() {
  jq -n --arg c "$1" '{session_id: "s", hook_event_name: "SessionStart", source: "startup", cwd: $c}' | "$HOOK"
}

@test "server down: no output, exit 0" {
  make_repo "$BATS_TEST_TMPDIR/proj"
  export CURL_STUB_EXIT=7
  run run_hook "$BATS_TEST_TMPDIR/proj"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "health check hits /health with a 1 second timeout" {
  run run_hook "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  grep -qF -- '--max-time 1' "$CURL_STUB_LOG"
  grep -qF -- 'http://127.0.0.1:8000/health' "$CURL_STUB_LOG"
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "in a repo: lists project group and personal, search uses both" {
  make_repo "$BATS_TEST_TMPDIR/proj_1-a"
  run run_hook "$BATS_TEST_TMPDIR/proj_1-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- project: `proj_1-a`'* ]]
  [[ "$output" == *'- cross-project: `personal`'* ]]
  [[ "$output" == *'`group_ids` set to both groups above'* ]]
  [[ "$output" == *'facts that hold only for this project go to the project group'* ]]
  [[ "$output" == *'`episode_body` is written in English'* ]]
  [[ "$output" == *'`add_memory`'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "special characters in the repo name become dashes" {
  make_repo "$BATS_TEST_TMPDIR/My.Repo name+x"
  run run_hook "$BATS_TEST_TMPDIR/My.Repo name+x"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- project: `My-Repo-name-x`'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "subdirectory of a repo uses the repo's group" {
  make_repo "$BATS_TEST_TMPDIR/proj"
  mkdir -p "$BATS_TEST_TMPDIR/proj/a/b"
  run run_hook "$BATS_TEST_TMPDIR/proj/a/b"
  [[ "$output" == *'- project: `proj`'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "linked worktree uses the main worktree's name" {
  make_repo "$BATS_TEST_TMPDIR/proj"
  git -C "$BATS_TEST_TMPDIR/proj" worktree add -q -b wt "$BATS_TEST_TMPDIR/proj-feature-wt"
  run run_hook "$BATS_TEST_TMPDIR/proj-feature-wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- project: `proj`'* ]]
  [[ "$output" != *'proj-feature-wt'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "outside a repo: only personal" {
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run run_hook "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- cross-project: `personal`'* ]]
  [[ "$output" != *'- project:'* ]]
  [[ "$output" == *'`group_ids` set to `personal`'* ]]
  [[ "$output" != *'project group'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "missing cwd in the JSON falls back to the working directory" {
  make_repo "$BATS_TEST_TMPDIR/proj"
  cd "$BATS_TEST_TMPDIR/proj"
  run bash -c 'printf "{}" | "$1"' _ "$HOOK"
  [ "$status" -eq 0 ]
  [[ "$output" == *'- project: `proj`'* ]]
}

# shellcheck disable=SC2016 # backticks in the single-quoted patterns are literal Markdown
@test "instructs to confirm each write with get_episodes" {
  run run_hook "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`add_memory` only queues the episode'* ]]
  [[ "$output" == *'only in the server log'* ]]
  [[ "$output" == *'call `get_episodes` for that group'* ]]
  [[ "$output" == *'before finishing the task'* ]]
  [[ "$output" == *'tell the user the memory was not saved'* ]]
}
