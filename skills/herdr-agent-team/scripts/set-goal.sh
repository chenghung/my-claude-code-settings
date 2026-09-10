#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/set-goal.sh
#
# 用法：
#   set-goal.sh --achieve <文字> --success <文字> --not-doing <文字> \
#     --assumption <文字> [--confirmed] [--changed-by <來源>] \
#     [--rationale <文字>]
#
# 職責（規格 §9）：把 goal 四項內容——要達成什麼、怎樣算成功（外部查
# 得到）、不做什麼、依賴哪些還沒驗證的前提——寫進 team.json。每次寫入
# 都遞增 goal_version，並在 goal_history 追加一筆：新舊四項、
# changed_by、rationale、時間戳。
#
# ---- --confirmed 不在時絕不翻動 goal_confirmed ----
# 規格 §9 定案：第一版由人類確認，之後每一次變更由 orchestrator 自
# 決，人類中間沒有第二個介入點。這代表「已經確認過」這件事一旦成立就
# 不該被後續呼叫動到——沒帶 --confirmed 的呼叫必須完全不碰這個欄位，
# 而不是把它寫回 false，否則 orchestrator 自決的每一次調整都會把已經
# 通過的開工閘門重新鎖上。
#
# ---- 顯著標記：GOAL-SUCCESS-CHANGED ----
# 這是規格 §9 定案的第二項不打擾補償：目標的變更權轉移給 orchestrator
# 之後，人類沒有機制得知目標被怎麼改了。這次變更若動到「怎樣算成功」
# （四項裡唯一設計成外部可查驗的一項），就在 stdout 印一行機器可辨識
# 的固定字串（不是散文），供 orchestrator 往事件流轉述。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面，印出來。hat_json_set 要的是
# JSON 值而非 shell 字串；這裡的四項目標內容與 --changed-by／
# --rationale 都是使用者可自由輸入的文字，可能含引號、反斜線或換行，
# 不能像 team-init.sh 對 hat_normalize_name 的輸出那樣手工拼
# `"\"$text\""`——那樣做在那裡安全是因為輸出字元集受限，這裡沒有那層
# 保證。改用 jq -Rn --arg 讓 jq 自己處理跳脫。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

achieve="" success="" not_doing="" assumption=""
changed_by="" rationale="" confirmed=0
have_achieve=0 have_success=0 have_not_doing=0 have_assumption=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --achieve)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --achieve 缺值"
      achieve="$2"
      have_achieve=1
      shift 2
      ;;
    --success)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --success 缺值"
      success="$2"
      have_success=1
      shift 2
      ;;
    --not-doing)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --not-doing 缺值"
      not_doing="$2"
      have_not_doing=1
      shift 2
      ;;
    --assumption)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --assumption 缺值"
      assumption="$2"
      have_assumption=1
      shift 2
      ;;
    --confirmed)
      confirmed=1
      shift
      ;;
    --changed-by)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --changed-by 缺值"
      changed_by="$2"
      shift 2
      ;;
    --rationale)
      [ "$#" -ge 2 ] || hat_die 2 "set-goal.sh: --rationale 缺值"
      rationale="$2"
      shift 2
      ;;
    *)
      hat_die 2 "set-goal.sh: 未知參數 '$1'"
      ;;
  esac
done

if [ "$have_achieve" -ne 1 ] || [ "$have_success" -ne 1 ] \
  || [ "$have_not_doing" -ne 1 ] || [ "$have_assumption" -ne 1 ]; then
  hat_die 2 "set-goal.sh: --achieve／--success／--not-doing／--assumption 四項全部必填（規格 §9）"
fi

team_json="$(hat_registry_root)/team.json"

# ---- 讀舊值：欄位缺漏是正常狀態，不透過 hat_json_get ----
# 第一次呼叫時 goal 四項、goal_version、goal_history 都還沒寫過，這是
# 正常狀態而不是 registry 壞了，因此不用 hat_json_get（它對缺漏欄位會
# 真的 exit 5，把整支腳本帶走）；改用 jq 直讀並以 `// empty`／`// 0`／
# `// []` 接住缺漏。
old_achieve="$(jq -r '.goal.achieve // empty' "$team_json" 2>/dev/null)" || old_achieve=""
old_success="$(jq -r '.goal.success // empty' "$team_json" 2>/dev/null)" || old_success=""
old_not_doing="$(jq -r '.goal.not_doing // empty' "$team_json" 2>/dev/null)" || old_not_doing=""
old_assumption="$(jq -r '.goal.assumptions // empty' "$team_json" 2>/dev/null)" || old_assumption=""
old_version="$(jq -r '.goal_version // 0' "$team_json" 2>/dev/null)" || old_version=0
old_history="$(jq -c '.goal_history // []' "$team_json" 2>/dev/null)" || old_history="[]"

new_version=$((old_version + 1))
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

success_changed=0
if [ "$old_success" != "$success" ]; then
  success_changed=1
fi

new_history="$(jq -c -n \
  --argjson history "$old_history" \
  --argjson version "$new_version" \
  --arg changed_at "$timestamp" \
  --arg changed_by "$changed_by" \
  --arg rationale "$rationale" \
  --arg old_achieve "$old_achieve" \
  --arg old_success "$old_success" \
  --arg old_not_doing "$old_not_doing" \
  --arg old_assumption "$old_assumption" \
  --arg new_achieve "$achieve" \
  --arg new_success "$success" \
  --arg new_not_doing "$not_doing" \
  --arg new_assumption "$assumption" \
  '$history + [{
    version: $version,
    changed_at: $changed_at,
    changed_by: $changed_by,
    rationale: $rationale,
    old: {achieve: $old_achieve, success: $old_success, not_doing: $old_not_doing, assumptions: $old_assumption},
    new: {achieve: $new_achieve, success: $new_success, not_doing: $new_not_doing, assumptions: $new_assumption}
  }]')"

hat_json_set "$team_json" '.goal.achieve' "$(hat_json_string "$achieve")"
hat_json_set "$team_json" '.goal.success' "$(hat_json_string "$success")"
hat_json_set "$team_json" '.goal.not_doing' "$(hat_json_string "$not_doing")"
hat_json_set "$team_json" '.goal.assumptions' "$(hat_json_string "$assumption")"
hat_json_set "$team_json" '.goal_version' "$new_version"
hat_json_set "$team_json" '.goal_history' "$new_history"

# --confirmed 不在時完全不碰 goal_confirmed（見檔頭說明），不是寫回
# false：寫回 false 會把 orchestrator 自決階段的每一次調整都重新鎖上
# 開工閘門。
if [ "$confirmed" -eq 1 ]; then
  hat_json_set "$team_json" '.goal_confirmed' 'true'
fi

if [ "$success_changed" -eq 1 ]; then
  printf 'GOAL-SUCCESS-CHANGED version=%s\n' "$new_version"
fi
