#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/set-worker-field.sh
#
# 用法：
#   set-worker-field.sh --to <worker> --field <欄位名> --value <值>
#
# 職責：workers/<name>.json 欄位白名單裡有四個欄位——`.stage`（生命週
# 期關卡）、`.completion_criteria`（完成判準）、`.delivery_point`（交
# 付點）、`.end_point`（終點）——一直沒有專屬包裝腳本；SKILL.md 與
# references/thin-command-format.md 目前教的做法是「`source lib/
# common.sh` 之後直接呼叫 `hat_json_set`」。那條路徑繞過整支腳本層的
# 守衛：workspace 入口守衛不會執行、`hat_assert_agent_name` 的名稱格
# 式驗證也不會執行。其中 `.stage` 是核心之一——`shutdown-worker.sh` 正
# 是讀它擋下「`delivered` 關卡不得走關閉」那條規則（見該檔檔頭「交付
# 點不等於終點」一節），一個沒有經過守衛就被寫進去的值，會讓那道閘門
# 建立在不可信的資料上。本腳本補上這支缺的包裝，讓這四個欄位跟其餘欄
# 位一樣，只能經過守衛才寫得進去。
#
# ---- 這支腳本自己再帶一層欄位白名單，比 hat_json_set 的白名單更窄
#      ----
# `lib/common.sh` 的 `_HAT_WORKER_JSON_FIELDS` 涵蓋 `workers/<name>.
# json` 全部寫入端的欄位（座標類由 `launch-worker.sh` 寫、整筆記錄由
# `shutdown-worker.sh` 移除、計數類由 `watchdog.sh` 維護），「寫入端欄
# 位集合不重疊」是這個設計用來防止互相覆蓋的機制（見 `lib/common.sh`
# 該陣列上方的說明）。若本腳本直接沿用那份清單當自己的白名單，呼叫端
# 就能經由它寫到座標、計數這些本來由別的腳本專責的欄位，等於用一支新
# 腳本繞過同一個約定。因此本腳本自己再帶一層更窄的白名單，只放行本腳
# 本職責範圍內的四個欄位；白名單外的欄位以 2 拒絕，不透傳給
# `hat_json_set` 決定。
#
# ---- .stage 的值另有一層驗證：只放行設計定義的生命週期關卡名稱 ----
# 生命週期是 `running → delivered →（可回到 running）→ closing →
# closed`（`shutdown-worker.sh` 檔頭「交付點不等於終點」一節）。這四
# 個名稱之外的值一律以 2 拒絕——寫錯字（例如 "deliverd"）不該被無聲接
# 受，讓 `shutdown-worker.sh` 那道「`.stage` = `delivered` 時拒絕關
# 閉」的閘門在錯字面前完全失靈。其餘三個欄位（`.completion_criteria`／
# `.delivery_point`／`.end_point`）是自由文字（locator 或判準描述，見
# `references/thin-command-format.md`「完成判準必須是外部查得到的形
# 式」一節），本腳本不驗內容，那是 orchestrator 自己的判斷。
#
# ---- 守衛順序：環境前提 → 名稱格式 → workspace 邊界 ----
# 跟其餘接受既有 target 的腳本（`press-approval.sh`／`instruct.sh`／
# `shutdown-worker.sh`）同一個順序：`--to` 會被直接用來組
# `workers/<--to>.json` 這條 registry 路徑，先驗格式（不合格式以 2 結
# 束）才能安全拿去組路徑；再讀出這個 worker 的 `pane_id` 斷言屬於本
# workspace（不屬於以 4 結束），早於任何會動到 registry 的寫入。本腳
# 本自己的欄位／值白名單檢查屬於「呼叫端用錯」的參數形狀檢查，不需要
# 碰 registry，排在名稱格式驗證之前（跟 `shutdown-worker.sh` 把
# `--reason` 白名單排在 `hat_assert_agent_name` 之前是同一個做法）。
#
# ---- 不加 --dry-run ----
# 介面簽章只有目標、欄位名、值三項，不添加沒有要求的選項；四個欄位裡
# 沒有一個是不可逆動作（跟 `shutdown-worker.sh` 移除整筆記錄不同），
# 寫錯了可以再呼叫一次覆寫回去。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／instruct.sh／set-goal.sh／launch-worker.sh／
# shutdown-worker.sh 的同名局部函式：各腳本各自獨立定義，不共用。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

to="" field="" value=""
have_to=0 have_field=0 have_value=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "set-worker-field.sh: --to 缺值"
      to="$2"; have_to=1; shift 2 ;;
    --field)
      [ "$#" -ge 2 ] || hat_die 2 "set-worker-field.sh: --field 缺值"
      field="$2"; have_field=1; shift 2 ;;
    --value)
      [ "$#" -ge 2 ] || hat_die 2 "set-worker-field.sh: --value 缺值"
      value="$2"; have_value=1; shift 2 ;;
    *)
      hat_die 2 "set-worker-field.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_to" -ne 1 ] || [ "$have_field" -ne 1 ] || [ "$have_value" -ne 1 ]; then
  hat_die 2 "set-worker-field.sh: --to／--field／--value 三項全部必填"
fi

# ---- 本腳本自己的欄位白名單，比 hat_json_set 的白名單更窄（見檔頭
#      「這支腳本自己再帶一層欄位白名單」一節）----
case "$field" in
  stage | completion_criteria | delivery_point | end_point) : ;;
  *)
    hat_die 2 "set-worker-field.sh: 欄位 '$field' 不在本腳本允許清單內，只接受 stage、completion_criteria、delivery_point、end_point 四個；其餘欄位各有專責寫入端（座標由 launch-worker.sh、計數由 watchdog.sh、整筆記錄由 shutdown-worker.sh 移除），不透過本腳本寫入" ;;
esac

# ---- .stage 的值驗證（見檔頭同名一節）----
if [ "$field" = "stage" ]; then
  case "$value" in
    running | delivered | closing | closed) : ;;
    *)
      hat_die 2 "set-worker-field.sh: --field stage 的值 '$value' 不是設計定義的生命週期關卡，只接受 running、delivered、closing、closed 四個（見 shutdown-worker.sh 檔頭「交付點不等於終點」一節）" ;;
  esac
fi

# ---- 名稱格式驗證早於組 registry 路徑（見檔頭「守衛順序」一節）----
hat_assert_agent_name "$to"

registry_root="$(hat_registry_root)"
worker_file="$registry_root/workers/$to.json"

# ---- workspace 邊界，早於寫入（見檔頭「守衛順序」一節）----
pane_id="$(hat_json_get "$worker_file" '.pane_id')"
hat_assert_workspace "$pane_id"

hat_json_set "$worker_file" ".$field" "$(hat_json_string "$value")"

printf 'to=%s field=%s set\n' "$to" "$field"
exit 0
