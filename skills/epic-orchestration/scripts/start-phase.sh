#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/start-phase.sh
#
# 用法：start-phase.sh <sub-issue 編號>
#
# 動作順序：
#   0. eo_state_init 確保狀態檔存在（理由見下方「狀態檔由這支腳本建
#      立，而且排在 tab create 之前」）。
#   1. herdr tab create（workspace 取自 HERDR_WORKSPACE_ID、cwd 指向主
#      倉庫、label 帶 sub-issue 編號、--no-focus 不搶焦點）。
#   2. 從回應取 result.tab.tab_id 與 result.root_pane.pane_id，連同
#      agent_name 與 held_by_orchestrator 一起立刻寫進狀態檔（理由見
#      下方「這筆記錄在啟動之前就要寫齊」）。
#   3. herdr agent start（kind 為 claude、名稱由 eo_agent_name 產生、
#      帶 --timeout 等待就緒，原生引數 --permission-mode auto 附在
#      -- 之後）。agent start 本身阻塞到就緒才回傳成功，成功即就緒憑
#      據，不再另外查詢任何欄位。
#
# 成功時輸出一行 `tab_id=<值> pane_id=<值> agent=<名稱>`。啟動未就緒
# 時以 8 結束，不送出任何開場指令——本腳本的職責到 agent start 就緒為
# 止，不含後續的 prompt 遞送，那是 send-to-phase.sh 的責任。
#
# ---- 對真實 herdr 0.8.2 查證過的事實：agent start 阻塞到就緒，沒有
#      「啟動三項」這種事後輪詢欄位 ----
# 本腳本原本的設計假設是 agent start 之後要再呼叫一次 agent get，檢查
# agent_status 是否為 idle、launch_pending 是否為假、interactive_ready
# 是否為真三個欄位（「啟動三項」）。這個假設已被查證推翻並修正計畫：對
# 真實 session 兩個存活的 agent 執行 `herdr agent get <target>` 唯讀查
# 詢，回應裡的 agent 物件只有這十六個欄位（agent、agent_session、
# agent_status、cwd、focused、foreground_cwd、name、pane_id、revision、
# state_change_seq、tab_id、terminal_id、terminal_title、
# terminal_title_stripped、tokens、workspace_id），沒有 launch_pending，
# 也沒有 interactive_ready（這兩次查詢對象都是已經穩定運行一段時間的
# agent，不是剛啟動、卡在核准對話框那個短暫窗口；references/rationale.md
# 記錄過那個窗口下曾觀察到 launch_pending 為真，但已把它標為未在當前
# 版本查證過、不得用作任何判準——那筆觀察來自事件驅動改版之前那一輪，
# 本輪沒有重測，因為製造那個窗口本身有副作用。不論哪一種情
# 形，這兩個欄位都不是本腳本要依賴的訊號——即使它們有時真的存在，也
# 只在啟動過程中一個轉瞬即逝的窗口內有意義，拿來做同步的啟動判準本來
# 就不可靠，這正是本腳本改成只信任 agent start 自身成功／失敗的原因）。
# 這份清單本身有一次修正紀錄：先前記成十五個欄位、且漏了 name，是對
# 真實 herdr 0.8.2 重新探測時發現的（agent get 與 api snapshot 的 agent
# 條目都回十六個鍵，name 裝的就是被指派的名稱）。這次修正不動搖上面
# 載重的那個結論——launch_pending 與 interactive_ready 兩者仍然都不在
# 清單裡，就緒判準改用 agent start 自身結束碼的理由不受影響。
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
# ---- 狀態檔由這支腳本建立，而且排在 tab create 之前 ----
# 建立記錄是本腳本的職責（SKILL.md「進度表與狀態檔」明文），而「建立
# 這個檔案」是它的前一步：沒有這一步，全新 epic 的第一次派工必然是
# tab create 成功、tab 真的開出來了，接著第一次 eo_state_set 撞上檔案
# 不存在、以 5 結束，而 close-phase.sh 第一件事也是從狀態檔取 tab_id，
# 同樣以 5 死掉——編排端拿不到識別碼，沒有任何腳本關得掉那個 tab。
#
# 呼叫的是 eo_state_init（見 common.sh），它是幂等的：檔案已存在時完
# 全不動內容，所以第二個 phase 的派工不會把第一個 phase 的記錄清掉；
# 多個 phase 在很短時間內接連啟動時，「檢查是否存在」與「寫入」兩步都
# 在同一把鎖的臨界區內，不會有一邊的寫入被另一邊蓋掉。
#
# 排在 tab create 之前是實質的，不是順手：狀態檔的目錄或檔案若因為權
# 限、磁碟等原因建不起來，這時候失敗只是一次沒開成的派工；排在 tab
# create 之後失敗，留下的就是這支腳本最要避免的那種孤兒 tab。
#
# ---- 這筆記錄在啟動之前就要寫齊 ----
# tab create 一成功，這筆記錄的四個欄位就立刻寫進狀態檔，早於呼叫
# agent start。原本的理由只涵蓋 tab_id／pane_id：這支腳本與
# close-phase.sh 合成一個任務，正是因為啟動未就緒（結束碼 8）時，呼叫
# 端要能靠 close-phase.sh 把這個已經真實建立、但沒能就緒的 tab 關掉才
# 能重啟——close-phase.sh 完全依賴狀態檔找 tab_id，若等到 agent start
# 成功才寫入，啟動失敗時狀態檔要嘛沒有這個 phase 的記錄、要嘛還留著上
# 一輪的舊 tab_id，close-phase.sh 都關不到這次真正建立的那個 tab，失敗
# 路徑會漏一個孤兒 tab。
#
# agent_name 適用完全相同的理由，所以跟它們同一批寫，不再留到 agent
# start 成功之後。這個名稱是由 phase 編號與主倉庫路徑推導出來的確定值
# （見 common.sh 的 eo_agent_name），不需要 agent start 成功才知道；而
# 啟動未就緒最主要的成因正是工作區信任對話框，它的復原路徑是由編排端
# 呼叫 press-approval.sh --startup 代按——那支腳本第一件事就是從狀態
# 檔取 agent 名稱，欄位不存在時以 5 結束，整支腳本會死在任何守衛與代按
# 之前，而 5 的既有語意是「檔案不存在或該 phase 不在檔內」，指不到真正
# 的成因。名稱留到成功之後才寫，等於這條復原路徑永遠執行不到，第一次
# 跑 epic 就會卡死在第一次派工。
#
# held_by_orchestrator 一起寫成 false：它是編排端擁有的欄位，
# event-generator.sh 連補預設值都不碰（那個不重疊正是「不必為每個欄位
# 單獨加鎖」這個決定的依據，見 set-phase-field.sh 檔頭「白名單不是防
# 呆」一節），所以它的初始值必須由建立記錄的這一方寫下，本腳本是它唯
# 一的初始寫入方。跟座標欄位同一批寫，啟動失敗的記錄因此一樣有它。
#
# 「欄位一定齊全」這件事仍然不能被下游當成假設：中斷恢復重建記錄與人
# 手動編輯狀態檔這兩條路徑都不經過本腳本，讀取端該有的缺漏容忍照樣要
# 有（見 event-generator.sh 的 _eo_ensure_field 與 eo_classify_stop）。
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

# ---- phase 必須是純數字，而這支腳本是最不能少這道檢查的一支 ----
# 消費端早就要求純數字了：read-phase-pane.sh --marker-only（要接進
# grep 樣式）與 event-generator.sh 的 eo_classify_stop 都明確驗證過。
# 本檔原本完全不驗，而它正好是唯一會建立記錄的那一支——最寬的那道口
# 開在最上游。實測拿一個含空白的字串當 phase 跑本腳本：rc 0、印出成功
# 行，狀態檔多一筆鍵含空白的記錄，agent 名稱也含空白（違反檔頭引用的
# herdr 命名規則）。之後 eo_state_phases 列得出這個鍵，事件產生器的
# main 因此把它當監看對象，而 eo_classify_stop 對它一律 eo_die 2、
# read-phase-pane.sh --marker-only 對它一律 rc 2，於是邊緣迴圈固定得到
# 標記缺席，每一輪白派一次調查者。
#
# 語意跟消費端契約對齊：本專案命名慣例裡 sub-issue 編號恆為數字。
# close-phase.sh／send-to-phase.sh／press-approval.sh／phase-status.sh
# 都套同一道檢查，理由不在那四支重複，指回這裡。
case "$phase" in
  ''|*[!0-9]*)
    eo_die 2 "start-phase.sh: <sub-issue 編號> 必須是純數字，收到：$phase"
    ;;
esac

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

# 狀態檔不存在就建（幂等、與其他寫入端共用同一把鎖），排在 tab create
# 之前，見檔頭「狀態檔由這支腳本建立，而且排在 tab create 之前」。
eo_state_init

tab_json="$(eo_herdr tab create --workspace "$workspace_id" \
  --cwd "$main_repo" --label "phase-$phase" --no-focus)"
tab_id="$(printf '%s' "$tab_json" | jq -r '.result.tab.tab_id')"
pane_id="$(printf '%s' "$tab_json" | jq -r '.result.root_pane.pane_id')"

# ---- 兩個識別碼必須真的取到，否則字串 `null` 會被寫成座標 ----
# jq 取不到路徑時安靜地印出字串 `null`，不是報錯——本檔上方「回應形
# 狀」與 phase-status.sh 都明文警告過取錯巢狀層的這個行為。實測（樁讓
# `tab tab create` 以 0 成功但 result 底下是空物件，也就是回應形狀漂移
# 或取錯層）：tab 與 pane 兩個識別碼都以字串 `null` 寫進狀態檔，接著
# `agent start` 帶著那個 pane 以 8 結束。
#
# 這筆記錄從此帶著指不到任何東西的座標，而且再也關不掉：close-phase.sh
# 第一道守衛拿 `null` 去做 workspace 斷言必然以 4 失敗，守衛二重讀到的
# 還是 `null`——正是上方「這筆記錄在啟動之前就要寫齊」要避免的那種孤
# 兒 tab，只是換一個入口。所以在寫狀態檔之前就擋下來。
#
# 此時 tab 已經真的建立了，所以訊息要帶上足以人工收拾的資訊：
# workspace 與 label 是唯一還指得到那個 tab 的線索（識別碼本身就是這
# 次沒取到的東西）。結束碼取 6（herdr 拒絕／回應不可用），不是 2：呼
# 叫端沒有用錯任何東西。
if [ -z "$tab_id" ] || [ "$tab_id" = "null" ] || [ -z "$pane_id" ] || [ "$pane_id" = "null" ]; then
  eo_die 6 "start-phase.sh: tab create 回報成功，但回應裡取不到可用的識別碼（tab_id='$tab_id' pane_id='$pane_id'），狀態檔未寫入。tab 可能已經真的建立，請以 workspace $workspace_id、label phase-$phase 人工確認並關閉"
fi

eo_state_set "$phase" tab_id "\"$tab_id\""
eo_state_set "$phase" pane_id "\"$pane_id\""
eo_state_set "$phase" agent_name "\"$agent\""
eo_state_set "$phase" held_by_orchestrator false

# agent start 不透過 eo_herdr：失敗時要映射成本腳本專屬的「啟動未就
# 緒」8，不是 eo_herdr 通用的「herdr 拒絕」6。刻意用 if 包住呼叫本身
# （而不是裸陳述句接著讀 $?），理由與 common.sh 的 eo_herdr 完全一
# 樣：本腳本開頭已 set -e，裸陳述句一旦失敗會在讀到 $? 之前就先終止
# 整個腳本，走不到下面的錯誤碼判斷。
#
# ---- herdr 印在 stderr 上的內容一律擷取後重組，不讓它原樣繼承 ----
# `2>&1 >/dev/null`：先把 fd2 導向目前的 fd1（也就是被命令替換擷取的
# 管線），再把 fd1 導向 /dev/null，結果只有 stderr 被擷取進
# err_output，成功時的回應直接丟棄（agent start 成功本身就是就緒憑
# 據，沒有任何欄位要讀）。手法與 send-to-phase.sh／press-approval.sh
# 對非逾時類錯誤完全一致，八支腳本裡不再留這一條例外。
#
# 為什麼不能讓它原樣繼承：本腳本的 stderr 直接就是編排端的 context。
# 這條失敗路徑最主要的成因正是工作區信任對話框，而那正是該 pane 的終
# 端標題最可能載著使用者或模型文字的時刻。`agent start` 這一類錯誤酬
# 載會不會整包帶著 agent 物件（因而帶著 terminal_title／
# terminal_title_stripped）至今未查證，而要製造一個卡在信任對話框的
# agent 本身就是副作用，沒有無副作用的探測手段可用。因此不逐一查證酬
# 載形狀，改採與另外兩支相同的結構性做法：只白名單擷取 error.code 與
# error.message 兩個純字串欄位，其餘欄位一律不觸碰；兩個欄位任一取不
# 到都給明確的替代字串，不靜默留空、也不因此退回轉發原文。
#
# 結束碼 1（伺服器錯誤，錯誤 JSON 印在 stderr）與結束碼 2（語法錯誤，
# herdr 印的是非 JSON 的用法說明）走同一道擷取，不是只處理 1：用法說
# 明一樣是未經接管的原始輸出，一樣不得原樣進入編排端的 context。它解
# 析不出 error.code，兩個欄位因此都落到替代字串，與 common.sh 的
# _eo_relay_herdr_stderr 對非 JSON 輸出的處置是同一個形狀。
rc=0
if err_output="$(herdr agent start "$agent" --kind claude --pane "$pane_id" \
    --timeout "$EO_AGENT_START_TIMEOUT_MS" \
    -- --permission-mode auto 2>&1 >/dev/null)"; then
  :
else
  rc=$?
fi

if [ "$rc" -ne 0 ]; then
  error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
  error_message="$(printf '%s' "$err_output" | jq -r '.error.message // empty' 2>/dev/null || true)"
  [ -n "$error_code" ] || error_code="(無法取得 error.code)"
  [ -n "$error_message" ] || error_message="(無法取得 error.message)"
  if [ "$rc" -eq 2 ]; then
    eo_die 2 "start-phase.sh: herdr 以結束碼 2 拒絕 agent start，疑似腳本呼叫語法錯誤（agent=$agent, pane=$pane_id）：code=$error_code message=$error_message"
  fi
  eo_die 8 "start-phase.sh: agent start 在逾時（${EO_AGENT_START_TIMEOUT_MS}ms）內未回報就緒（phase $phase, tab $tab_id, pane $pane_id），結束碼 $rc：code=$error_code message=$error_message"
fi

printf 'tab_id=%s pane_id=%s agent=%s\n' "$tab_id" "$pane_id" "$agent"
