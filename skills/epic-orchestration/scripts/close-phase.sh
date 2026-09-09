#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/close-phase.sh
#
# 用法：close-phase.sh <sub-issue 編號>
#
# 三道守衛依序全過才呼叫 herdr tab close；任一不過以 4 結束，並在
# stderr 指出是哪一道。狀態檔缺漏（檔案不存在，或該 phase 不在檔內）
# 由 eo_state_get 既有邏輯以 5 結束，發生在三道守衛之前，不算其中一
# 道。tab close 成功後移除該 phase 在狀態檔裡的整筆記錄（見下方最後
# 一行）：設計規格生命週期第六步明文要求收尾要把記錄移出狀態檔，記
# 錄留著不刪，事件產生器會一直監看一個已經收尾的 phase。
#
#   守衛一：該 tab 屬於本 workspace（eo_assert_workspace，判定依據集
#           中在 common.sh、來源是 HERDR_WORKSPACE_ID，本腳本不重新
#           推導）。
#   守衛二：緊接在守衛一之後，重新讀一次狀態檔的 tab_id，必須與守衛
#           一驗證的那個值完全一致。守衛一內部有一次 herdr round
#           trip，這段等待期間 state.json 可能被另一個行程（尤其是
#           常駐的 event-generator.sh，或另一個並行呼叫的 orchestrator
#           操作）併發改寫——例如這個 phase 剛好在同一時刻被重啟、
#           tab_id 換成了新 tab。沒有這一步重新核對，close 動作用的
#           會是「呼叫當下第一次讀到」的舊值，跟「現在真正該關的是哪
#           個 tab」在時間上已經脫勾。
#   守衛三：不等於 HERDR_TAB_ID（呼叫者自己所在的 tab）。HERDR_TAB_ID
#           未設或為空一律視為守衛不成立，不因為變數沒設就放行——否
#           則呼叫端有可能關掉自己所在的 tab。這支腳本同時用在收尾完
#           成後關閉，也用在啟動失敗後重啟前關閉（見 start-phase.sh
#           結束碼 8 的說明），兩種情境一律套用同一套守衛，不為任一
#           情境開後門。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 1 ]; then
  eo_die 2 "close-phase.sh: 缺少必填參數 <sub-issue 編號>"
fi
phase="$1"

# phase 一律驗成純數字，與消費端契約對齊；完整理由見 start-phase.sh
# 同一道檢查上方的說明，不在這裡重複。
case "$phase" in
  ''|*[!0-9]*)
    eo_die 2 "close-phase.sh: <sub-issue 編號> 必須是純數字，收到：$phase"
    ;;
esac

tab_id="$(eo_state_get "$phase" tab_id)"

# 守衛一：該 tab 屬於本 workspace。
eo_assert_workspace "$tab_id"

# 守衛二：重新讀一次狀態檔，確認 tab_id 在守衛一的 herdr round trip
# 期間沒有被其他行程改寫。
current_tab_id="$(eo_state_get "$phase" tab_id)"
if [ "$current_tab_id" != "$tab_id" ]; then
  eo_die 4 "close-phase.sh: 守衛二不成立：狀態檔記錄的 tab_id 在守衛檢查期間變動（原 $tab_id，現在 $current_tab_id），phase $phase 拒絕關閉"
fi

# 守衛三：不得關閉呼叫者自己所在的 tab。HERDR_TAB_ID 未設或為空一律
# 視為守衛不成立，不因為變數沒設就放行。
if [ -z "${HERDR_TAB_ID:-}" ] || [ "$current_tab_id" = "$HERDR_TAB_ID" ]; then
  eo_die 4 "close-phase.sh: 守衛三不成立：目標 tab（$current_tab_id）等於呼叫者自己的 HERDR_TAB_ID，或該變數未設，phase $phase 拒絕關閉"
fi

# 丟棄 herdr 原始回應：本專案一貫的紀律是只轉發自組的最小結果，不轉
# 發 herdr 原始 JSON（phase-status.sh、start-phase.sh 皆同）。close 動
# 作沒有任何欄位需要呼叫端進一步解析，因此直接丟棄，不必另外組一行輸
# 出。
eo_herdr tab close "$current_tab_id" >/dev/null

# tab 確實關閉後才移除狀態記錄，順序是實質的：若中途失敗（走上面的
# eo_herdr 錯誤路徑），狀態檔要留著讓下一次呼叫還找得到這個 phase 的
# tab_id 再試一次；只有真的關成功了，這筆記錄才算收尾完成。
eo_state_remove_phase "$phase"
