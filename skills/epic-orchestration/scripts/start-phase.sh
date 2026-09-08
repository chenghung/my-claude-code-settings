#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/start-phase.sh
#
# 用法：start-phase.sh <sub-issue 編號>
#
# 動作順序：
#   1. herdr tab create（workspace 取自 HERDR_WORKSPACE_ID、cwd 指向主
#      倉庫、label 帶 sub-issue 編號、--no-focus 不搶焦點）。
#   2. 從回應取 result.tab.tab_id 與 result.root_pane.pane_id，立刻寫
#      進狀態檔（理由見下方「先寫 tab_id／pane_id 再啟動」）。
#   3. herdr agent start（kind 為 claude、名稱由 eo_agent_name 產生、
#      帶 --timeout 等待就緒，原生引數 --permission-mode auto 附在
#      -- 之後）。agent start 本身阻塞到就緒才回傳成功，成功即就緒憑
#      據，不再另外查詢任何欄位。
#
# 成功時輸出一行 `tab_id=<值> pane_id=<值> agent=<名稱>`，並把
# agent_name 補寫進狀態檔。啟動未就緒時以 8 結束，不送出任何開場指令
# ——本腳本的職責到 agent start 就緒為止，不含後續的 prompt 遞送，那
# 是 send-to-phase.sh 的責任。
#
# ---- 對真實 herdr 0.8.2 查證過的事實：agent start 阻塞到就緒，沒有
#      「啟動三項」這種事後輪詢欄位 ----
# 本腳本原本的設計假設是 agent start 之後要再呼叫一次 agent get，檢查
# agent_status 是否為 idle、launch_pending 是否為假、interactive_ready
# 是否為真三個欄位（「啟動三項」）。這個假設已被查證推翻並修正計畫：對
# 真實 session 兩個存活的 agent 執行 `herdr agent get <target>` 唯讀查
# 詢，回應裡的 agent 物件只有既有查證過的十五個欄位（agent、
# agent_session、agent_status、cwd、focused、foreground_cwd、pane_id、
# revision、state_change_seq、tab_id、terminal_id、terminal_title、
# terminal_title_stripped、tokens、workspace_id），沒有 launch_pending，
# 也沒有 interactive_ready（這兩次查詢對象都是已經穩定運行一段時間的
# agent，不是剛啟動、卡在核准對話框那個短暫窗口；references/rationale.md
# 另外記錄過那個窗口下 launch_pending 會短暫出現且為真。不論哪一種情
# 形，這兩個欄位都不是本腳本要依賴的訊號——即使它們有時真的存在，也
# 只在啟動過程中一個轉瞬即逝的窗口內有意義，拿來做同步的啟動判準本來
# 就不可靠，這正是本腳本改成只信任 agent start 自身成功／失敗的原因）。
# 隨二進位附的 `herdr --skill` 文件也明講：
# 「A successful agent start returns only after Herdr detects the
# expected agent in the same pane and considers it ready for
# interactive input.」——也就是 agent start 本身阻塞到就緒才回傳成
# 功，失敗態是 `agent_not_ready`（herdr 伺服器錯誤慣例：JSON 印在
# stderr、結束碼 1），不是靠事後輪詢兩個不存在的布林欄位。因此本腳本
# 只把 agent start 自身的成功／失敗當就緒憑據，失敗一律映成本腳本的
# 結束碼 8（見下方呼叫處），不呼叫 agent get。若日後真的需要另外查
# agent get，切記它的欄位是巢狀的：在 result 底下的 agent 底下（例如
# `.result.agent.agent_status`），不是扁平掛在 result 底下。
#
# ---- 先寫 tab_id／pane_id 再啟動 agent ----
# tab create 一成功，tab_id／pane_id 立刻寫進狀態檔，早於呼叫
# agent start。理由：這支腳本與 close-phase.sh 合成一個任務，正是因為
# 啟動未就緒（結束碼 8）時，呼叫端要能靠 close-phase.sh 把這個已經真
# 實建立、但沒能就緒的 tab 關掉才能重啟——close-phase.sh 完全依賴狀態
# 檔找 tab_id，若等到 agent start 成功才寫入，啟動失敗時狀態檔要嘛沒
# 有這個 phase 的記錄、要嘛還留著上一輪的舊 tab_id，close-phase.sh 都
# 關不到這次真正建立的那個 tab，失敗路徑會漏一個孤兒 tab。agent_name
# 則留到 agent start 成功之後才寫，因為在那之前這個名稱還沒有對應到
# 任何真的啟動成功的 agent。
#
# ---- 不建立 git worktree ----
# 本腳本只開 tab、啟動 agent，cwd 指向主倉庫，不建立任何 git worktree。
# 建立 worktree、切分支是 phase agent 自己開工後的責任（規格附錄 B 的
# worktree／分支命名慣例是講給 phase agent 聽的，不是講給這支腳本聽
# 的）。設計文件本來就在主倉庫底下，phase agent 從主倉庫 cwd 起步不需
# 要額外的目錄授權。這不是漏掉一步，是刻意分工。
#
# ---- --permission-mode auto 已實測 ----
# 四個候選權限模式裡，只有 --permission-mode auto 通得過，其餘會在啟
# 動期間卡住等待互動確認、不符合本腳本「啟動後立刻可無人值守運作」的
# 前提。這個結論已實測，不必每次重測。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 1 ]; then
  eo_die 2 "start-phase.sh: 缺少必填參數 <sub-issue 編號>"
fi
phase="$1"

# herdr agent start --help 查證到的預設逾時（default: 30000; max:
# 300000），這裡明確帶入而不是依賴隱含預設：外顯優於內隱，且日後 herdr
# 改了預設值也不會讓本腳本的行為跟著意外改變。
readonly EO_AGENT_START_TIMEOUT_MS=30000

workspace_id="${HERDR_WORKSPACE_ID:-}"
if [ -z "$workspace_id" ]; then
  eo_die 4 "start-phase.sh: HERDR_WORKSPACE_ID 未設，無法建立 tab"
fi

main_repo="$(eo_main_repo)"
agent="$(eo_agent_name "$phase")"

tab_json="$(eo_herdr tab create --workspace "$workspace_id" \
  --cwd "$main_repo" --label "phase-$phase" --no-focus)"
tab_id="$(printf '%s' "$tab_json" | jq -r '.result.tab.tab_id')"
pane_id="$(printf '%s' "$tab_json" | jq -r '.result.root_pane.pane_id')"

eo_state_set "$phase" tab_id "\"$tab_id\""
eo_state_set "$phase" pane_id "\"$pane_id\""

# agent start 不透過 eo_herdr：失敗時要映射成本腳本專屬的「啟動未就
# 緒」8，不是 eo_herdr 通用的「herdr 拒絕」6。刻意用 if 包住呼叫本身
# （而不是裸陳述句接著讀 $?），理由與 common.sh 的 eo_herdr 完全一
# 樣：本腳本開頭已 set -e，裸陳述句一旦失敗會在讀到 $? 之前就先終止
# 整個腳本，走不到下面的錯誤碼判斷。標準輸出導向 /dev/null 丟棄，不
# 轉發任何 herdr 原始回應；標準錯誤保持原樣，讓 herdr 自己印的錯誤訊
# 息還在，方便除錯。
if herdr agent start "$agent" --kind claude --pane "$pane_id" \
    --timeout "$EO_AGENT_START_TIMEOUT_MS" \
    -- --permission-mode auto >/dev/null; then
  :
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    eo_die 2 "start-phase.sh: herdr 以結束碼 2 拒絕 agent start，疑似腳本呼叫語法錯誤（agent=$agent, pane=$pane_id）"
  fi
  eo_die 8 "start-phase.sh: agent start 在逾時（${EO_AGENT_START_TIMEOUT_MS}ms）內未回報就緒（phase $phase, tab $tab_id, pane $pane_id），結束碼 $rc"
fi

eo_state_set "$phase" agent_name "\"$agent\""

printf 'tab_id=%s pane_id=%s agent=%s\n' "$tab_id" "$pane_id" "$agent"
