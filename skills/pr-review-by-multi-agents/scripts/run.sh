#!/usr/bin/env bash
# Orchestrates parallel PR code review by claude, codex, and opencode CLIs.
#
# Command line: run.sh <pr-link> <issue-link> <design-doc-path>. All three
# positional arguments may be the empty string -- an empty PR link derives
# the PR from the current branch (see parse_pr_url); an empty issue link or
# design doc path is passed straight through to build_prompt, which renders
# it as an explicit "not provided" statement for the reviewer contract.
#
# This file defines, in order: whether to run at all and how many reviewer
# CLIs are available (input parsing and preflight checks); the code
# workspace and full prompt each reviewer CLI needs (worktree setup and
# prompt assembly); and, below, launching each reviewer CLI with its own
# least-privilege sandbox/permission flags, supervising them to completion,
# and reporting a summary -- the main() function at the bottom strings all
# of the above into the complete pipeline.
set -euo pipefail

# IFS is intentionally left at its bash default here. Nothing in this file
# currently iterates over multi-line/multi-word command output, and this
# file is `source`d directly into tests/test-pr-review-by-multi-agents.sh's
# own shell process -- a global IFS override here would silently leak into
# that test script (and into whatever later tasks append below). When a
# future addition actually needs to split on newlines, scope it locally
# instead of overriding IFS at file scope, e.g. `while IFS= read -r line;
# do ...; done < <(cmd)` or `local IFS=$'\n\t'` inside just that function.

# parse_pr_url <input>
#
# Accepts a full PR URL (https://github.com/<owner>/<repo>/pull/<N>), the
# shorthand "<owner>/<repo>#<N>", or an empty string. An empty string derives
# the PR from the current branch via `gh pr view`, then falls through to the
# same URL parser used for the explicit-URL case.
#
# On success, prints "<owner> <repo> <number>" to stdout and returns 0.
# On any parse failure, returns non-zero and prints nothing to stdout.
parse_pr_url() {
  local input="${1:-}"
  local owner repo number

  if [ -z "$input" ]; then
    # No input given: ask gh for the URL of the PR belonging to the current
    # branch, then parse that URL below like any other explicit input.
    input="$(gh pr view --json url --jq .url 2>/dev/null)" || return 1
    [ -n "$input" ] || return 1
  fi

  if [[ "$input" =~ ^https://github\.com/([^/[:space:]]+)/([^/[:space:]]+)/pull/([0-9]+)([/?#].*)?$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  elif [[ "$input" =~ ^([^/[:space:]]+)/([^/#[:space:]]+)#([0-9]+)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    number="${BASH_REMATCH[3]}"
  else
    return 1
  fi

  printf '%s %s %s\n' "$owner" "$repo" "$number"
}

# check_prerequisites <owner> <repo> <number>
#
# Verifies gh is installed, gh is authenticated, and the target PR exists.
# Returns 0 when all three hold. On the first failure, prints the reason to
# stderr and returns non-zero.
check_prerequisites() {
  local owner="$1" repo="$2" number="$3"

  if ! command -v gh >/dev/null 2>&1; then
    printf 'check_prerequisites: gh CLI not found in PATH\n' >&2
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    printf 'check_prerequisites: gh is not authenticated (run: gh auth login)\n' >&2
    return 1
  fi

  if ! gh pr view "$number" --repo "$owner/$repo" >/dev/null 2>&1; then
    printf 'check_prerequisites: PR %s/%s#%s not found\n' "$owner" "$repo" "$number" >&2
    return 1
  fi

  return 0
}

# detect_reviewers
#
# Prints the installed reviewer CLI names to stdout, one per line, in the
# fixed order claude, codex, opencode. A CLI that is not on PATH is silently
# skipped (graceful degradation) rather than treated as an error. Returns
# non-zero only when none of the three are installed.
detect_reviewers() {
  local cli found=0

  for cli in claude codex opencode; do
    if command -v "$cli" >/dev/null 2>&1; then
      printf '%s\n' "$cli"
      found=1
    fi
  done

  [ "$found" -eq 1 ] || return 1
}

# resolve_contract_path
#
# Locates references/reviewer-contract.md relative to this script's own
# file, resolving any symlinks the skill was installed through (e.g.
# install.sh deploys the whole skill directory as a single symlink under
# ~/.claude/skills or ~/.agents/skills). Prints the absolute contract path
# to stdout on success. A missing contract file is a hard failure -- it
# means this run has no review standard to hand any reviewer -- so this
# returns non-zero and prints nothing rather than falling back to anything.
resolve_contract_path() {
  local script_path script_dir skill_root contract_path

  script_path="$(readlink -f "${BASH_SOURCE[0]}")" || return 1
  script_dir="$(cd "$(dirname "$script_path")" && pwd)" || return 1
  skill_root="$(cd "$script_dir/.." && pwd)" || return 1
  contract_path="$skill_root/references/reviewer-contract.md"

  if [ ! -f "$contract_path" ]; then
    printf 'resolve_contract_path: contract file not found at %s\n' "$contract_path" >&2
    return 1
  fi

  printf '%s\n' "$contract_path"
}

# _origin_matches_owner_repo <origin_url> <owner> <repo>
#
# True (exit 0) when origin_url is a github-style HTTPS or SSH remote URL
# for exactly <owner>/<repo>, with or without a trailing .git. Requires an
# explicit / or : boundary immediately before <owner> -- a bare `*` prefix
# is not enough, because e.g. an owner of "acme" would then also match a
# same-suffixed but different owner like "not-acme" (.../not-acme/widgets.git
# ends with "acme/widgets.git" too). owner/repo are quoted inside the case
# pattern, so any glob metacharacters that happened to be in their values
# are matched literally rather than interpreted as wildcards.
_origin_matches_owner_repo() {
  local origin_url="$1" owner="$2" repo="$3"

  case "$origin_url" in
    */"$owner/$repo" | */"$owner/$repo".git | *:"$owner/$repo" | *:"$owner/$repo".git) return 0 ;;
    *) return 1 ;;
  esac
}

# setup_worktree <owner> <repo> <number> <base_dir>
#
# Prunes stale worktree registrations, then checks the PR's head commit out
# into a new worktree at <base_dir>/worktree, leaving the caller's current
# branch and working tree untouched. Prints the worktree's absolute path to
# stdout on success. Returns non-zero, printing nothing, on any failure --
# spec section 6 treats a worktree that didn't actually get created as a
# hard-stop precondition, same tier as gh being missing.
setup_worktree() {
  local owner="$1" repo="$2" number="$3" base_dir="$4"
  local origin_url worktree_path pr_ref stale_ref

  # Fail fast if the cwd's origin doesn't actually point at this PR's own
  # repo, rather than silently fetching/reviewing the wrong codebase.
  origin_url="$(git remote get-url origin 2>/dev/null)" || return 1
  if ! _origin_matches_owner_repo "$origin_url" "$owner" "$repo"; then
    printf 'setup_worktree: origin remote (%s) does not match %s/%s\n' "$origin_url" "$owner" "$repo" >&2
    return 1
  fi

  git worktree prune >/dev/null 2>&1 || true

  # Best-effort cleanup of this function's own local refs left behind by
  # earlier runs whose worktree has since been removed -- otherwise every
  # run adds one more branch that never goes away. git refuses to delete a
  # branch that is still checked out in a live worktree, so this only ever
  # removes ones that are genuinely stale.
  while IFS= read -r stale_ref; do
    git branch -D "$stale_ref" >/dev/null 2>&1 || true
  done < <(git for-each-ref --format='%(refname:short)' 'refs/heads/pr-review-*' 2>/dev/null)

  worktree_path="$base_dir/worktree"
  # $$ keeps this local ref name unique across concurrent runs that happen
  # to target the same PR number.
  pr_ref="pr-review-$number-$$"

  # The leading + force-updates the local ref even when it isn't a
  # fast-forward. Without it, a PID reused from an earlier run whose
  # same-named ref was left pointing somewhere unrelated would make this
  # fetch fail for a reason that has nothing to do with the current PR.
  #
  # GitHub always exposes this pull-ref on the base repo, regardless of
  # whether the PR's source branch lives there or in a fork.
  git fetch origin "+pull/$number/head:$pr_ref" >/dev/null 2>&1 || return 1
  git worktree add "$worktree_path" "$pr_ref" >/dev/null 2>&1 || return 1

  printf '%s\n' "$worktree_path"
}

# resolve_model <cli_name>
#
# Reads the given reviewer CLI's own config file for its default model and
# prints the model name to stdout. Sources: codex reads the top-level
# `model` key from ~/.codex/config.toml (a `model =` line living under a
# later [profile] table is a different model, not the default one, so
# parsing stops at the first section header); opencode reads .model from
# ~/.config/opencode/opencode.json; claude reads .model from
# $CLAUDE_CONFIG_DIR/settings.json, falling back to ~/.claude/settings.json
# when that env var is unset -- the same variable and fallback SKILL.md
# uses to locate this very script, since a personal-subscription deployment
# points it at a different config directory and a hardcoded ~/.claude would
# miss that deployment's actual settings file. Failing to resolve a value -- missing config
# file, missing field, malformed content (invalid JSON, or a value of the
# wrong type), or jq unavailable for the JSON sources -- is not an error:
# it prints the fixed "unknown-model" marker and still returns 0, because
# an honestly-reported unknown is exactly what the reviewer contract's
# disclosure section needs, not a reason to abort.
#
# Every value-producing command below is guarded with `|| value=""`. Under
# set -euo pipefail, a bare `value="$(cmd)"` whose cmd fails (jq on
# malformed JSON, or a pipeline killed by SIGPIPE) does NOT reliably abort
# just this function -- whether it aborts the whole calling shell depends
# on how the caller happens to invoke resolve_model (a plain call or output
# redirection propagates the failure via errexit; wrapping the call in
# $(...) happens to mask it, since bash disables errexit inside command
# substitutions by default). This function's contract is "never abort,
# always degrade to unknown-model", so it does not rely on the caller
# invoking it in one particular way to get that behavior.
resolve_model() {
  local cli="$1" unknown="unknown-model"
  local config_file value=""

  case "$cli" in
    codex)
      config_file="$HOME/.codex/config.toml"
      if [ -f "$config_file" ]; then
        # Quits right after the first match instead of piping through
        # `head -n1`: a separate `head` closing its read end early, while
        # sed is still writing further lines, can deliver SIGPIPE to sed
        # and (under pipefail) fail this whole assignment -- which happens
        # for real once a config has two or more top-level `model =` lines
        # before any [section] header. Matching and quitting inside the
        # same sed invocation removes the second process, and therefore
        # the race, entirely.
        value="$(sed -n '/^\[/q; /^[[:space:]]*model[[:space:]]*=/{s/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p;q}' "$config_file")" || value=""
      fi
      ;;
    opencode)
      config_file="$HOME/.config/opencode/opencode.json"
      if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
        value="$(jq -r '.model // empty' "$config_file" 2>/dev/null)" || value=""
      fi
      ;;
    claude)
      config_file="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
      if [ -f "$config_file" ] && command -v jq >/dev/null 2>&1; then
        value="$(jq -r '.model // empty' "$config_file" 2>/dev/null)" || value=""
      fi
      ;;
    *)
      ;;
  esac

  printf '%s\n' "${value:-$unknown}"
}

# build_prompt <contract_path> <pr_url> <issue_url> <design_doc_path> \
#              <cli_name> <model> <worktree_path> <base_ref> <scratch_dir>
#
# Prints the complete prompt for one reviewer CLI to stdout: the reviewer
# contract's full text, verbatim and unabridged, followed by this run's
# coordinates -- the PR and issue links, the design doc path, this
# worktree's absolute path, the base ref the contract's pinned diff command
# needs, this reviewer's own CLI/model identity, and a scratch directory
# outside the worktree for the comment-body file the contract requires.
# issue_url and design_doc_path may be empty strings; the contract's own
# input-list section requires an explicit "not provided" statement rather
# than a blank field for those two, so an empty value is rendered as such
# here instead of being left out.
build_prompt() {
  local contract_path="$1" pr_url="$2" issue_url="$3" design_doc_path="$4"
  local cli_name="$5" model="$6" worktree_path="$7" base_ref="$8" scratch_dir="$9"
  local contract issue_display design_display

  contract="$(cat "$contract_path")" || return 1

  issue_display="${issue_url:-（未提供，明確視為不存在）}"
  design_display="${design_doc_path:-（未提供，明確視為不存在）}"

  # Printed via a sequence of printf calls rather than interpolated into a
  # heredoc: the contract is external content that a separate task keeps
  # revising, and a heredoc here would make correctness depend on none of
  # its lines ever colliding with the terminator. printf's %s never
  # rescans its argument for shell syntax or a delimiter, so this stays
  # correct regardless of what that content contains. (Each coordinate
  # line's format string starts with "- ", which the plain bash builtin
  # would otherwise try to parse as an option; `--` stops that.)
  printf '%s\n' "$contract"
  printf '\n## 本次審查的座標資訊\n\n'
  printf -- '- PR：%s\n' "$pr_url"
  printf -- '- git worktree 絕對路徑：%s\n' "$worktree_path"
  printf -- '- base ref：%s\n' "$base_ref"
  printf -- '- issue：%s\n' "$issue_display"
  printf -- '- design document 路徑：%s\n' "$design_display"
  printf -- '- 產出這則 review 的 CLI 名稱：%s\n' "$cli_name"
  printf -- '- 產出這則 review 的 model 名稱：%s\n' "$model"
  printf -- '- 暫存目錄（worktree 之外，張貼 comment 前把內文寫入此處的檔案）：%s\n' "$scratch_dir"
}

# _git_status_snapshot <worktree_dir>
#
# Prints a single comparable snapshot of the worktree's git state: its
# working-tree/index status plus its current HEAD commit. Two snapshots
# taken before and after a reviewer's run are byte-for-byte equal if and
# only if nothing about the worktree changed in between -- covering both an
# uncommitted edit (caught by `git status`) and a commit that leaves the
# tree clean again (caught by the HEAD line, which status alone would miss).
# `--ignored` is required, not optional: the reviewer contract promises
# that "呼叫端會在每個 review 行程啟動前後比對 worktree 的 git 狀態" with no
# carve-out for gitignored paths, so a snapshot that silently skipped them
# would make that promise false for exactly the paths a reviewer could
# write to with the least chance of being noticed otherwise. The tradeoff
# this accepts: if some reviewer CLI drops its own incidental cache/scratch
# file inside a gitignored path within the worktree (rather than under its
# own home-dir config, where well-behaved CLIs keep that kind of state),
# this snapshot will flag that run as invalidated even though nothing
# about the *reviewed code* changed -- a false positive, but one that
# fails toward distrusting a review rather than toward silently trusting a
# tampered one, which is the direction this check exists to protect.
#
# Every command is guarded with `|| var=""` for the same reason
# resolve_model's are: this can run inside a command substitution (bash
# disables errexit there on this repo's bash 4.3 floor, pre-inherit_errexit),
# so it must degrade to an empty field rather than depend on the caller's
# invocation style to catch a failure.
_git_status_snapshot() {
  local worktree_dir="$1" status_output head_sha

  status_output="$(git -C "$worktree_dir" status --porcelain=v1 --untracked-files=all --ignored 2>/dev/null)" || status_output=""
  head_sha="$(git -C "$worktree_dir" rev-parse HEAD 2>/dev/null)" || head_sha=""

  printf '%s\nHEAD:%s\n' "$status_output" "$head_sha"
}

# _write_opencode_permission_config <path>
#
# Writes opencode's own permission config (consulted via the OPENCODE_CONFIG
# env var -- see launch_reviewer) to <path>: the built-in `edit` tool is
# denied outright, and `bash` lists only the git/gh/filesystem mutation
# verbs this run must not perform (denied by pattern) plus the one write
# the contract requires (`gh pr comment*`, explicitly allowed). Read
# commands, including the contract's pinned `git diff` command, `gh issue
# view`/`gh issue list` (the contract lists issue content as fit-for-
# requirements-conformance-axis material, so a reviewer needs to actually
# be able to read it), and a plain `gh api` GET request, are never listed
# here at all -- they fall through to launch_reviewer's `--auto` flag,
# which auto-approves anything not explicitly denied. `gh issue*` and
# `gh api*` are deliberately NOT used as blanket deny patterns for this
# reason: an earlier version did, and it silently denied those same read
# commands too, degrading the requirements-conformance axis to "issue
# material not provided" for a reason opaque to whoever later reads that
# comment on the PR. Each `gh issue`/`gh api` deny below instead names the
# specific mutating subcommand or HTTP write method it blocks. This
# deliberately has no catch-all "*": "allow" entry: an earlier version did,
# but opencode's actual precedence rule for multiple *matching* bash
# patterns (does the first match win, the last one, or the most specific
# one?) could not be confirmed against the compiled binary, and an
# explicit catch-all sharing key-space with the deny patterns makes the
# correctness of every deny below depend on guessing that rule right. With
# no catch-all, a command either matches exactly one of the deny patterns
# below (denied, unambiguous) or matches none of them (falls through to
# --auto's own default-allow, equally unambiguous) -- correct regardless
# of which precedence rule opencode actually implements, at zero extra
# cost over the catch-all version.
#
# Rules are static and contain no interpolated content, so a plain quoted
# heredoc (no variable/command expansion) is safe here, unlike
# build_prompt's contract text which is untrusted external content
# assembled with printf instead.
_write_opencode_permission_config() {
  local path="$1"

  cat > "$path" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "deny",
    "bash": {
      "git add*": "deny",
      "git commit*": "deny",
      "git push*": "deny",
      "git checkout*": "deny",
      "git reset*": "deny",
      "git rebase*": "deny",
      "git merge*": "deny",
      "git rm*": "deny",
      "git branch -D*": "deny",
      "rm *": "deny",
      "mv *": "deny",
      "chmod *": "deny",
      "sudo*": "deny",
      "gh api -X POST*": "deny",
      "gh api -X PUT*": "deny",
      "gh api -X PATCH*": "deny",
      "gh api -X DELETE*": "deny",
      "gh api --method POST*": "deny",
      "gh api --method PUT*": "deny",
      "gh api --method PATCH*": "deny",
      "gh api --method DELETE*": "deny",
      "gh pr edit*": "deny",
      "gh pr review*": "deny",
      "gh pr merge*": "deny",
      "gh pr close*": "deny",
      "gh pr reopen*": "deny",
      "gh issue close*": "deny",
      "gh issue comment*": "deny",
      "gh issue create*": "deny",
      "gh issue delete*": "deny",
      "gh issue edit*": "deny",
      "gh issue lock*": "deny",
      "gh issue pin*": "deny",
      "gh issue reopen*": "deny",
      "gh issue transfer*": "deny",
      "gh issue unlock*": "deny",
      "gh issue unpin*": "deny",
      "gh pr comment*": "allow"
    }
  }
}
JSON
}

# launch_reviewer <cli_name> <worktree_dir> <log_file>
#
# Starts one reviewer CLI as a detached, nohup'd background process whose
# working directory is <worktree_dir> and whose prompt is this function's
# own stdin (the caller redirects it in, e.g. `launch_reviewer ... <
# prompt_file`). All three reviewer CLIs were confirmed during preflight
# probing to read their prompt from stdin when no positional prompt
# argument is given: `claude -p`, `codex exec`, and `opencode run` (without
# a `message` argument) all do this -- that probe result is recorded here
# rather than only in .tmp/probe-results.md, since that file is gitignored
# and won't exist for anyone who didn't run the probe themselves. Combined
# stdout+stderr go to <log_file>. Prints the launched process's PID to
# stdout on success.
#
# Each CLI gets its own least-privilege enforcement, using that CLI's own
# mechanism rather than trusting the reviewer contract's natural-language
# read-only rule alone (the contract itself only binds the reviewer CLI's
# behavior; nothing about it stops the CLI's host environment from already
# having git/gh/sed pre-approved, which is exactly the gap this closes).
# None of these three mechanisms turned out, on real testing, to reliably
# stop a write into the *worktree* on their own (see the OS-level chmod
# note further below) -- they're kept regardless as each CLI's own first
# line of defense, shaping what it can even attempt, with chmod as the
# backstop that actually has to hold:
#   - claude: `--permission-mode dontAsk` (auto-denies anything not
#     explicitly allowed, except read-only Bash commands) plus an explicit
#     `--allowedTools` whitelist naming the read tools, `Write` (needed for
#     the contract's required comment-body file -- see below), and the one
#     `gh pr comment` write the contract requires; `--disallowedTools`
#     covers Edit/NotebookEdit, which this run never needs.
#
#     Two things here are empirically verified facts about a real claude
#     binary, not inferred from --help text (which, on the first point,
#     suggests the opposite would happen; on the second, actively
#     recommends a syntax that turned out not to work) -- if either ever
#     needs re-verifying against a future claude release, re-run the same
#     kind of probe rather than trusting this comment or the official text
#     alone:
#       1. dontAsk auto-denies anything not on --allowedTools *except*
#          read-only Bash commands, which it lets through uncondition-
#          ally -- confirmed by asking it to run the contract's pinned
#          `git diff <base>...HEAD` with this exact allowedTools/
#          disallowedTools pair (no Bash pattern for `git diff` in the
#          allow list at all) and getting real diff output back.
#       2. There is no way to scope the `Write` tool to a specific path via
#          `--allowedTools`/`--disallowedTools`: `Write(<path>/**)` is
#          rejected outright at startup with "is not matched by file
#          permission checks -- only Edit(path) rules are. Use Edit(...)
#          instead" -- but that suggestion doesn't actually work either;
#          an `Edit(<worktree>/**)` disallow rule, combined with a bare
#          `Write` allow, still let a real claude process write into that
#          worktree in a real test run. `Write` in claude's tool-permission
#          model is all-or-nothing: either the whole tool is allowed
#          (anywhere the process can reach) or it isn't. This is why the
#          worktree itself is separately protected at the OS level below,
#          instead of through this flag.
#   - codex: `-s read-only`, the most restrictive of codex's three sandbox
#     modes (the other two, `workspace-write` and
#     `--dangerously-bypass-approvals-and-sandbox`, grant filesystem writes
#     codex doesn't need for reviewing) and the one that best matches the
#     contract's own read-only requirement. It was tried first, before
#     either of the more permissive modes, specifically because it's the
#     most restrictive; sandbox probing confirmed `gh` still reaches the
#     network under it (read-only blocks local filesystem writes only, not
#     network I/O), so there was no need to fall back to a less restrictive
#     mode. (The worktree write-attempt this same probing later surfaced --
#     see the OS-level chmod protection below -- means codex's sandbox
#     alone turned out not to fully enforce that filesystem restriction in
#     `codex exec`'s non-interactive mode; this flag is kept anyway as a
#     first line of defense, on top of the chmod backstop that now carries
#     the real guarantee.)
#   - opencode: no CLI-level permission flag exists, so the restriction
#     lives in a scratch, run-specific config file (see
#     _write_opencode_permission_config) pointed at via the OPENCODE_CONFIG
#     env var; `--auto` is required alongside it so permissions this config
#     leaves unset (i.e. everything not on the explicit deny list) don't
#     block waiting for a human who, in this headless run, will never
#     answer. That config's `bash` deny list is necessarily a list of
#     specific risky verbs (git commit, rm, sudo, ...), not an exhaustive
#     one -- a real test run confirmed a plain shell redirect
#     (`printf ... > file`, which matches none of those specific patterns)
#     writes successfully wherever the underlying shell can reach,
#     including into the worktree. No bash-pattern blacklist can close
#     that off completely (there is no bounded list of every way a shell
#     command can write a file), which is the other reason the worktree
#     gets OS-level protection below rather than depending on this list
#     alone.
#
# All three of the mechanisms above turned out, on real testing, not to
# reliably stop a write into the worktree by itself -- claude's `Write`
# tool has no path scoping at all (see above), codex's `-s read-only`
# sandbox did not block a real write attempt in `codex exec`'s non-
# interactive mode (a sandbox-escalation path this script has no flag to
# turn off for `codex exec` specifically), and opencode's bash deny list
# is a blacklist of specific verbs that a plain shell redirect walks
# straight past. Given that, the worktree's actual protection is now an
# OS-level one applied uniformly to all three from main(), independent of
# any single CLI's own permission engine: `chmod -R a-w` on the worktree
# right after setup_worktree creates it (before any reviewer is launched),
# restored with `chmod -R u+w` immediately before removal (see
# spawn_supervisor and _dispatch_failed_cleanup). `git status`/`git diff`
# -- everything the contract's read-only true-source-of-truth section asks
# a reviewer to do -- were confirmed to still work against a worktree
# chmod'd this way, since a linked worktree's own index/HEAD housekeeping
# lives under the main repo's .git/worktrees/<name>/, not inside the
# worktree's own directory tree. Each CLI's flags above are kept anyway:
# they still shape what the model even attempts (fewer tool calls that
# have to fail), and they're the only defense at all for scratch-dir
# writes and for whatever this script's own git-status-snapshot comparison
# in spawn_supervisor cannot see (see that function's own docstring on the
# gitignored-path tradeoff).
#
# None of the three CLIs are given a model flag (design decision, made
# before this task and held here unchanged: each uses its own configured
# default; resolve_model reads that default back out for disclosure, it is
# never fed back in here). This is a deliberate override of, not an
# oversight against, a preflight probing finding recorded elsewhere (in a
# gitignored scratch file that won't exist for anyone who didn't run the
# probe themselves, so the finding itself is restated here): opencode's
# probe run needed an explicit, funded model because its configured
# default had insufficient billing -- that finding is about the state of
# one account's opencode config, not about this script's design,
# and hardcoding a model here to work around it would trade one staleness
# problem (a model name baked into this script drifting from whatever the
# user actually configures) for another. Concretely, this means: if a
# user's own opencode default model is unusable (no billing, revoked
# credentials, etc.), the opencode reviewer is expected to fail with a
# non-zero exit code -- spawn_supervisor records that in the summary file
# exactly like any other reviewer failure, and print_summary's PID/log
# line lets the caller find the failing run's log to see why. Fixing an
# individual user's opencode billing/model setup is out of this script's
# scope.
#
# Implementation note on the PID this prints: the underlying process is
# wrapped as `nohup bash -c '...' &` so that process's own exit code can be
# captured to a file once it finishes (see the header comment above
# spawn_supervisor for why this file-based handoff is used instead of
# `wait`). That wrapper file is named after the wrapped process's own PID
# using `$$` from *inside* the wrapper script -- which is the same PID this
# function's `$!` observes, because `nohup` execs its argument in place
# rather than forking an extra layer. This holds true even when this whole
# function is invoked via command substitution (`pid=$(launch_reviewer
# ...)`), which is the normal way main() calls it: unlike `wait`, this
# file-based handoff has no dependency on process parentage, so it survives
# the command substitution's own transient subshell exiting immediately
# after printing the PID.
launch_reviewer() {
  local cli_name="$1" worktree_dir="$2" log_file="$3"
  local -a cmd=()
  local base_dir before_snapshot starting_dir config_file pid

  base_dir="$(dirname "$worktree_dir")"

  case "$cli_name" in
    claude)
      cmd=(claude -p --permission-mode dontAsk \
        --allowedTools "Read Grep Glob WebFetch Write Bash(gh pr comment:*)" \
        --disallowedTools "Edit NotebookEdit")
      ;;
    codex)
      cmd=(codex exec -s read-only -C "$worktree_dir")
      ;;
    opencode)
      config_file="$(dirname "$log_file")/opencode-permission.json"
      _write_opencode_permission_config "$config_file"
      cmd=(opencode run --auto --dir "$worktree_dir")
      ;;
    *)
      printf 'launch_reviewer: unknown reviewer CLI: %s\n' "$cli_name" >&2
      return 1
      ;;
  esac

  before_snapshot="$(_git_status_snapshot "$worktree_dir")"

  # claude has no working-directory flag; it uses whatever the process's
  # cwd is. Changing and restoring cwd here (a plain `cd`, not a subshell)
  # affects only this function's own shell, which for every real call is
  # itself a short-lived command-substitution subshell already -- so this
  # never leaks into the caller's cwd.
  if [ "$cli_name" = claude ]; then
    starting_dir="$(pwd)" || return 1
    cd "$worktree_dir" || return 1
  fi

  # opencode has no CLI flag for its permission config; it reads the
  # OPENCODE_CONFIG env var instead, so it's the only CLI needing anything
  # prefixed onto the launch below. `env` (rather than a bare `VAR=val`
  # prefix) lets this stay one shared launch line for every CLI: an empty
  # env_prefix expands to zero words, so the line reduces to plain `nohup
  # ...` for claude/codex.
  local -a env_prefix=()
  if [ "$cli_name" = opencode ]; then
    env_prefix=(env "OPENCODE_CONFIG=$config_file")
  fi

  # The `bash -c` wrapper's script body is single-quoted on purpose: `$1`,
  # `$$`, `$@` and `$?` inside it must reach *that* subshell unexpanded by
  # this shell, to be evaluated once that process actually starts running
  # (see this function's docstring for why exit-code capture works this
  # way instead of `wait`).
  #
  # `< /dev/stdin` is required, not decorative: POSIX has asynchronous
  # commands (anything started with `&`) default their stdin to /dev/null
  # unless *that specific command* carries its own explicit redirect --
  # this function's own stdin already being the prompt (via the caller's
  # `launch_reviewer ... < prompt_file`) does not, by itself, carry through
  # to a backgrounded command inside it. Verified empirically against this
  # repo's actual bash before adding this: the backgrounded reviewer
  # received an empty stdin without it.
  # shellcheck disable=SC2016 # single quotes are intentional, see comment above
  "${env_prefix[@]+"${env_prefix[@]}"}" nohup bash -c '
    base_dir="$1"; shift
    exit_file="$base_dir/.exit-$$"
    "$@"
    printf "%s" "$?" > "$exit_file"
  ' _ "$base_dir" "${cmd[@]}" < /dev/stdin > "$log_file" 2>&1 &
  pid=$!

  if [ "$cli_name" = claude ]; then
    cd "$starting_dir" || true
  fi

  printf '%s\n' "$before_snapshot" > "$base_dir/.git-status-before-$pid"

  printf '%s\n' "$pid"
}

# spawn_supervisor <worktree_dir> <summary_file> <pid>...
#
# Backgrounds itself and returns immediately (the caller, main(), does not
# wait for it). For each given PID, waits for that reviewer to finish,
# compares the worktree's git state against the snapshot launch_reviewer
# took right before starting it (see _git_status_snapshot), and appends one
# line to <summary_file> recording its PID, exit code, end time, and
# whether the comparison found the worktree modified during its run. Once
# every PID has been recorded, removes the worktree. The number of PIDs
# handled is exactly the number given -- nothing here assumes three.
#
# Why this polls for a per-PID exit-code file instead of using `wait`: bash
# can only `wait` on an actual child of the *current* process. By the time
# main() calls this function, each reviewer process is already a child of
# main()'s own shell (launch_reviewer backgrounded it there); the `(...)&`
# this function uses to background itself forks a *new*, separate process
# that is a sibling of those reviewers, not their parent, so `wait` on
# their PIDs from inside that subshell fails outright ("not a child of this
# shell") -- verified against this repo's actual bash before settling on
# this design, not merely reasoned about. launch_reviewer's nohup wrapper
# sidesteps the whole problem by having each reviewer process record its
# own exit code to a file when it finishes, which needs no parent-child
# relationship to observe from here.
#
# Known limitation from processing PIDs sequentially in the order given,
# combined with all of them sharing one worktree (a separate, already-
# accepted tradeoff of the shared-worktree design itself, not something
# introduced here): the "after" snapshot for an earlier PID in the list is
# only taken once this loop gets around to it, which can be *after* a
# still-running later reviewer has already written something. In that
# window, an innocent earlier reviewer can be marked "invalidated" for a
# change it didn't make. This is a conservative failure mode, not a
# detection gap -- it can only ever cause a false "invalidated" on an
# innocent run, never a false "ok" on a run that actually tampered with
# the worktree, since every real tamper still gets caught by whichever
# PID's window it actually fell inside. Accepted as-is rather than
# reworked into concurrent/interleaved polling, given that direction.
#
# `trap '' HUP` right below, before anything else runs in the backgrounded
# subshell, is not redundant with the `disown` after it: `disown` only
# stops *this shell* from sending SIGHUP to the job when the shell itself
# exits; it does nothing about the kernel sending SIGHUP to the whole
# foreground process group when the controlling terminal goes away (e.g.
# the terminal this whole run.sh invocation was started from gets closed).
# Without also ignoring that signal, this subshell dying is not a minor
# inconvenience: it is the only thing that ever removes the worktree or
# completes the summary file, so its death leaves the worktree (still
# holding the branch this run created) permanently stuck -- neither this
# script's own future runs (which only prune worktrees whose directory is
# already gone) nor a normal branch cleanup ever reaches it again.
spawn_supervisor() {
  local worktree_dir="$1" summary_file="$2"
  shift 2
  local -a pids=("$@")

  (
    trap '' HUP
    local pid rc end_time before after status exit_file base_dir
    base_dir="$(dirname "$worktree_dir")"
    : > "$summary_file"

    for pid in "${pids[@]}"; do
      exit_file="$base_dir/.exit-$pid"
      # Also breaks out if the process is simply gone (e.g. killed by a
      # signal the wrapper couldn't trap) so this can't poll forever.
      until [ -f "$exit_file" ] || ! kill -0 "$pid" 2>/dev/null; do
        sleep 1
      done

      rc="$(cat "$exit_file" 2>/dev/null)" || rc=""
      # The exit file's own mtime is this reviewer's real completion time;
      # `date` at this point in the loop would instead read whenever this
      # sequential loop happened to get around to checking it, which lags
      # further behind for whichever PID is checked later.
      end_time="$(date -u -r "$exit_file" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || end_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

      before="$(cat "$base_dir/.git-status-before-$pid" 2>/dev/null)" || before=""
      after="$(_git_status_snapshot "$worktree_dir")"
      if [ "$before" = "$after" ]; then
        status="ok"
      else
        status="invalidated"
      fi

      printf 'pid=%s exit=%s ended_at=%s worktree_status=%s\n' \
        "$pid" "${rc:-unknown}" "$end_time" "$status" >> "$summary_file"
    done

    # Undo main()'s `chmod -R a-w` (see main()'s own comment) before
    # removing -- `git worktree remove` needs write access to actually
    # delete the tree, and a still-read-only tree makes it fail outright.
    chmod -R u+w "$worktree_dir" 2>/dev/null || true
    git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
  ) &
  disown
}

# print_summary <logs_dir> <dispatched_cli>... --skipped <skipped_cli>...
#
# Prints the dispatch summary the skill relays to the user: which reviewers
# were actually launched (with each one's PID, read back from the
# <cli>.pid file main() writes right after launch_reviewer, and its log
# file path), and which were skipped because that CLI wasn't installed.
# When exactly one reviewer was dispatched, adds a line calling out that
# cross-validation across independent reviewers does not hold for this run.
print_summary() {
  local logs_dir="$1"
  shift
  local -a dispatched=() skipped=()
  local arg mode="dispatched" cli pid

  for arg in "$@"; do
    if [ "$arg" = "--skipped" ]; then
      mode="skipped"
      continue
    fi
    if [ "$mode" = "dispatched" ]; then
      dispatched+=("$arg")
    else
      skipped+=("$arg")
    fi
  done

  printf '已派出的 reviewer：\n'
  if [ "${#dispatched[@]}" -eq 0 ]; then
    printf '（無）\n'
  else
    for cli in "${dispatched[@]+"${dispatched[@]}"}"; do
      pid="$(cat "$logs_dir/$cli.pid" 2>/dev/null)" || pid=""
      printf -- '- %s（PID：%s，log：%s）\n' "$cli" "${pid:-未知}" "$logs_dir/$cli.log"
    done
  fi

  printf '\n已跳過的 reviewer：\n'
  if [ "${#skipped[@]}" -eq 0 ]; then
    printf '（無）\n'
  else
    for cli in "${skipped[@]+"${skipped[@]}"}"; do
      printf -- '- %s（原因：未安裝）\n' "$cli"
    done
  fi

  if [ "${#dispatched[@]}" -eq 1 ]; then
    printf '\n本次只有一個 reviewer，交叉驗證效果不成立。\n'
  fi
}

# resolve_base_ref <owner> <repo> <number>
#
# Looks up this PR's base branch name via gh, then fetches it from origin
# into a local remote-tracking ref (refs/remotes/origin/<name>) so the diff
# command every reviewer's contract is pinned to
# (`git diff <base-ref>...HEAD`) can actually resolve <base-ref> inside the
# shared worktree -- a linked worktree shares refs/objects with the repo
# it's attached to, so fetching here (in the caller's cwd, the same repo
# setup_worktree operates against) makes the ref resolve there too. Prints
# "origin/<base-branch-name>" to stdout on success. This is a hard
# precondition, same tier as setup_worktree failing: with no resolvable
# base ref, every reviewer would independently hit the contract's own
# "base ref 沒有提供" abort path and immediately exit without reviewing
# anything, so failing here first avoids paying for three CLI invocations
# that would only self-abort anyway.
resolve_base_ref() {
  local owner="$1" repo="$2" number="$3" base_ref_name

  base_ref_name="$(gh pr view "$number" --repo "$owner/$repo" --json baseRefName --jq .baseRefName 2>/dev/null)" || return 1
  [ -n "$base_ref_name" ] || return 1

  git fetch origin "+refs/heads/$base_ref_name:refs/remotes/origin/$base_ref_name" >/dev/null 2>&1 || return 1

  printf 'origin/%s\n' "$base_ref_name"
}

# _dispatch_failed_cleanup <worktree_dir> <already_launched_pid>...
#
# main()'s reviewer-dispatch loop calls resolve_model, build_prompt, and
# launch_reviewer once per detected CLI; under set -e, any one of those
# failing partway through (say, on the second of three CLIs) would abort
# main() right there with no further cleanup -- leaving the worktree in
# place forever (nothing else in this script's lifetime ever removes it
# outside spawn_supervisor, which this abort path never reaches) and, if a
# CLI *before* the one that failed already got launched, its process
# running as a permanent orphan with no spawn_supervisor ever tracking it
# to completion or recording its exit. Both are silent resource leaks with
# no error surfaced anywhere else, which is why main() calls this instead
# of just letting set -e abort bare: it reports exactly which already-
# launched PIDs are now unsupervised (so a human has something to `kill`
# or `ps` on) and makes a best-effort attempt to remove the worktree before
# main() exits non-zero.
_dispatch_failed_cleanup() {
  local worktree_dir="$1"
  shift

  if [ "$#" -gt 0 ]; then
    printf 'run.sh: reviewer dispatch failed partway through; PID(s) already launched and now unsupervised: %s\n' "$*" >&2
  else
    printf 'run.sh: reviewer dispatch failed before any reviewer was launched\n' >&2
  fi

  # Undo main()'s `chmod -R a-w` before removing -- see spawn_supervisor's
  # matching step for why `git worktree remove` needs this first.
  chmod -R u+w "$worktree_dir" 2>/dev/null || true
  git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
}

# main <pr-link> <issue-link> <design-doc-path>
#
# The full pipeline: resolve and validate the PR, detect which reviewer
# CLIs are installed, set up the shared worktree and base ref, launch every
# detected reviewer with its own prompt, hand them to spawn_supervisor, and
# print the dispatch summary. Every hard precondition (gh missing/not
# authenticated, PR not found, no reviewer CLI installed, contract file
# missing, base ref unresolvable, worktree creation failing) exits non-zero
# before anything is launched -- see each called function's own docstring
# for what it reports on failure.
main() {
  local pr_arg="${1:-}" issue_url="${2:-}" design_doc_path="${3:-}"
  local pr_info owner repo number contract_path base_ref pr_url
  local project_root project_hash project_folder
  local base_dir logs_dir scratch_dir summary_file worktree_dir
  local cli d found model prompt pid cli_scratch_dir
  local -a all_reviewers=() skipped=() pids=()

  if ! pr_info="$(parse_pr_url "$pr_arg")"; then
    printf 'run.sh: unable to resolve the PR from %s\n' \
      "${pr_arg:-the current branch (no PR link given, and no PR is associated with it)}" >&2
    exit 1
  fi
  read -r owner repo number <<< "$pr_info"

  check_prerequisites "$owner" "$repo" "$number" || exit 1

  mapfile -t all_reviewers < <(detect_reviewers)
  if [ "${#all_reviewers[@]}" -eq 0 ]; then
    printf 'run.sh: none of claude, codex, opencode are installed\n' >&2
    exit 1
  fi

  for cli in claude codex opencode; do
    found=0
    for d in "${all_reviewers[@]}"; do
      [ "$d" = "$cli" ] && { found=1; break; }
    done
    [ "$found" -eq 1 ] || skipped+=("$cli")
  done

  contract_path="$(resolve_contract_path)" || exit 1

  base_ref="$(resolve_base_ref "$owner" "$repo" "$number")" || {
    printf 'run.sh: unable to resolve the PR base ref\n' >&2
    exit 1
  }

  project_root="$(git rev-parse --show-toplevel)" || {
    printf 'run.sh: not inside a git repository\n' >&2
    exit 1
  }
  project_hash="$(printf '%s' "$project_root" | sha256sum | cut -c1-8)"
  project_folder="$(basename "$project_root")-$project_hash"
  # $$ (same disambiguation setup_worktree's own pr_ref already relies on)
  # keeps two calls for the same PR started within the same second from
  # colliding on one base_dir -- the timestamp alone isn't fine-grained
  # enough to rule that out.
  base_dir="$HOME/.tmp/$project_folder/pr-review/$number-$(date -u +%Y%m%d%H%M%S)-$$"
  logs_dir="$base_dir/logs"
  scratch_dir="$base_dir/scratch"
  summary_file="$base_dir/summary.txt"
  mkdir -p "$logs_dir" "$scratch_dir"

  worktree_dir="$(setup_worktree "$owner" "$repo" "$number" "$base_dir")" || {
    printf 'run.sh: failed to set up the review worktree\n' >&2
    exit 1
  }

  # This chmod, not any single reviewer CLI's own sandbox/permission flags,
  # is the actual enforcement behind the reviewer contract's read-only
  # promise -- launch_reviewer's docstring records the real testing that
  # led here (every one of the three CLIs' own mechanisms turned out to
  # have a real gap). Applied once, right after the worktree exists and
  # before any reviewer is launched; spawn_supervisor and
  # _dispatch_failed_cleanup both restore write access before removing it.
  if ! chmod -R a-w "$worktree_dir"; then
    printf 'run.sh: failed to make the review worktree read-only\n' >&2
    git worktree remove --force "$worktree_dir" >/dev/null 2>&1 || true
    exit 1
  fi

  pr_url="https://github.com/$owner/$repo/pull/$number"

  for cli in "${all_reviewers[@]}"; do
    # A per-CLI subdirectory under scratch_dir, not scratch_dir itself:
    # all three reviewers get the byte-for-byte same prompt and run
    # concurrently, so if they all wrote their comment-body file into one
    # shared directory, two of them picking the same filename (nothing in
    # the contract constrains the name beyond "a file") is a real risk,
    # not a hypothetical one -- a same-named overwrite in the few seconds
    # between one reviewer writing its file and posting from it would post
    # someone else's comment body under this reviewer's own disclosure
    # header, and the contract forbids ever editing or deleting a posted
    # comment to fix that after the fact. logs_dir already gets this same
    # per-CLI split (each reviewer's own <cli>.log); this mirrors it.
    #
    # Each step below is checked explicitly (rather than as a bare
    # statement) so a failure partway through this loop runs
    # _dispatch_failed_cleanup instead of letting set -e abort main() with
    # an already-launched reviewer or the worktree left behind with
    # nothing to clean it up.
    cli_scratch_dir="$scratch_dir/$cli"
    if ! mkdir -p "$cli_scratch_dir" \
      || ! model="$(resolve_model "$cli")" \
      || ! prompt="$(build_prompt "$contract_path" "$pr_url" "$issue_url" "$design_doc_path" \
             "$cli" "$model" "$worktree_dir" "$base_ref" "$cli_scratch_dir")"; then
      _dispatch_failed_cleanup "$worktree_dir" "${pids[@]+"${pids[@]}"}"
      exit 1
    fi
    printf '%s' "$prompt" > "$logs_dir/$cli.prompt"
    if ! pid="$(launch_reviewer "$cli" "$worktree_dir" "$logs_dir/$cli.log" < "$logs_dir/$cli.prompt")"; then
      _dispatch_failed_cleanup "$worktree_dir" "${pids[@]+"${pids[@]}"}"
      exit 1
    fi
    pids+=("$pid")
    printf '%s\n' "$pid" > "$logs_dir/$cli.pid"
  done

  spawn_supervisor "$worktree_dir" "$summary_file" "${pids[@]}"

  print_summary "$logs_dir" "${all_reviewers[@]}" --skipped "${skipped[@]+"${skipped[@]}"}"
}

# Only run the pipeline when this file is executed directly -- sourcing it
# (as tests/test-pr-review-by-multi-agents.sh does, to call these functions
# individually) must not trigger a real run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
