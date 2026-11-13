#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/set-team-field.sh
#
# 用法：
#   set-team-field.sh --field thin_command_source --value <絕對路徑>
#
# 職責：team.json 的 `.thin_command_source` 原本沒有包裝腳本，
# references/thin-command-format.md 教 orchestrator 在自己的 shell 裡
# `source lib/common.sh` 再直接呼叫 `hat_json_set`。orchestrator 的
# shell 是 zsh 時，這條路會失敗（已實測）：zsh 把小寫的 `path` 陣列和
# PATH 綁在一起，`hat_json_set` 的 `local path=...` 因此把 PATH 改成欄
# 位名稱，接著找不到 flock，等鎖 30 秒後以 5 結束，欄位沒有寫入。本
# 腳本固定以 bash 執行，不受呼叫端 shell 影響，並跟 set-worker-field.sh
# 一樣先過守衛再寫入。
#
# ---- 欄位白名單只放 thin_command_source ----
# team.json 其餘欄位各有專責寫入端（goal 系列由 set-goal.sh 寫，
# orchestrator 座標由 team-init.sh 寫）。理由同 set-worker-field.sh 檔
# 頭「這支腳本自己再帶一層欄位白名單」一節：沿用 hat_json_set 的完整白
# 名單，等於開一條繞過專責寫入端的路。
#
# ---- 值必須是既有檔案的絕對路徑 ----
# thin-command-format.md 要求寫入絕對路徑。相對路徑換了工作目錄就指向
# 別的檔案，而寫入當下不會有任何錯誤，所以在這裡擋下。
#
# ---- 守衛順序：環境前提 → 參數形狀 → 自我續租 → 寫入 ----
# 同 set-goal.sh：本腳本只寫 team.json，沒有 worker 座標可驗，所以沒
# 有名稱格式或 workspace 邊界這兩關。自我續租排在所有本地守衛之後，
# 讓「呼叫端用錯時完全不呼叫任何 herdr」這個保證成立，理由見
# lib/common.sh hat_renew_orchestrator_name 的檔頭。
#
# 結束碼：0 成功；2 用法錯誤（缺旗標、未知旗標、欄位不在白名單、值不是
# 既有檔案的絕對路徑）；3 HERDR_ENV 不是 1；5 registry 缺漏或寫入失敗。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 用法與理由同 set-worker-field.sh 的同名局部函式：各腳本各自獨立定
# 義，不共用。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

field="" value=""
have_field=0 have_value=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --field)
      [ "$#" -ge 2 ] || hat_die 2 "set-team-field.sh: --field 缺值"
      field="$2"; have_field=1; shift 2 ;;
    --value)
      [ "$#" -ge 2 ] || hat_die 2 "set-team-field.sh: --value 缺值"
      value="$2"; have_value=1; shift 2 ;;
    *)
      hat_die 2 "set-team-field.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_field" -ne 1 ] || [ "$have_value" -ne 1 ]; then
  hat_die 2 "set-team-field.sh: --field／--value 兩項全部必填"
fi

case "$field" in
  thin_command_source) : ;;
  *)
    hat_die 2 "set-team-field.sh: 欄位 '$field' 不在本腳本允許清單內，只接受 thin_command_source；team.json 其餘欄位各有專責寫入端（goal 系列由 set-goal.sh、orchestrator 座標由 team-init.sh），不透過本腳本寫入" ;;
esac

case "$value" in
  /*) : ;;
  *) hat_die 2 "set-team-field.sh: --value 必須是絕對路徑，收到：$value" ;;
esac
[ -f "$value" ] || hat_die 2 "set-team-field.sh: --value 指向的檔案不存在：$value"

hat_renew_orchestrator_name

team_json="$(hat_registry_root)/team.json"
hat_json_set "$team_json" ".$field" "$(hat_json_string "$value")"

printf 'field=%s set\n' "$field"
exit 0
