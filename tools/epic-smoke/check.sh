#!/usr/bin/env bash
# tools/epic-smoke/check.sh - Directory statistics script for epic-smoke
#
# 用法：check.sh [--json]。加上 --json 時，另外把統計結果以 JSON 印到標準輸出。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

count_files() {
  local target_dir="$1"
  local full_path="$REPO_ROOT/$target_dir"
  local count=0

  if [[ -d "$full_path" ]]; then
    count=$(( $(find "$full_path" -type f -print0 | tr -cd '\0' | wc -c) ))
  fi

  echo "$count"
}

main() {
  local json_mode=0
  local agents_count
  local skills_count
  local rules_count

  if [[ "${1:-}" == "--json" ]]; then
    json_mode=1
  fi

  agents_count=$(count_files "agents")
  skills_count=$(count_files "skills")
  rules_count=$(count_files "rules")

  log_msg "agents: $agents_count"
  log_msg "skills: $skills_count"
  log_msg "rules: $rules_count"

  if (( json_mode )); then
    printf '{"agents":%d,"skills":%d,"rules":%d}\n' \
      "$agents_count" "$skills_count" "$rules_count"
  fi
}

main "$@"
