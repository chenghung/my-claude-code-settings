#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/event-generator.sh
#
# 用法：event-generator.sh（無參數，常駐執行，掛在 Claude Code 的
# Monitor 工具上；每一行 stdout 就是 orchestrator 的一則事件通知）。
#
# ---- 這支腳本要修的問題 ----
# 現行編排端用前景輪詢觀測 phase agent，只等 idle 與 blocked、刻意排
# 除 done。但無人值守的 phase agent 回合結束一律落在 done，idle 只
# 有使用者親自在 herdr UI 點進那個 tab 之後才會出現——現行版本因此
# 永遠等不到，漏不漏取決於使用者有沒有看過那個 tab，不取決於 phase
# 做了什麼。本檔把觀測換成事件推送：常駐守著每個 phase，停下就立刻
# 知道，不必靠編排端記得回來查。
#
# ---- 整體形狀：每個 phase 一條邊緣迴圈＋一條低頻掃描 ----
# 每個 phase 一條迴圈，以子行程執行；main 每輪重讀狀態檔決定監看清
# 單，派工與收尾都不必重啟本腳本。Monitor 只吃單一指令，動態增減監
# 看對象沒有現成機制可借，本腳本得自己起停這些子行程（見 main／
# _eo_cleanup）；main 也監督低頻掃描那條子行程是否還活著，跟 phase
# 迴圈用同一套「不在了就重起」邏輯。
#
# 每條邊緣迴圈分外層／內層兩段：
#   外層  等 idle／done／blocked 其中之一（逾時 EO_WAIT_TIMEOUT_MS）
#     agent_not_found → 邊緣觸發印 GONE，結束這條迴圈
#     timeout         → 不印任何一行，重掛外層
#     其餘             → 抓標記行，交給 eo_classify_stop 分類
#   內層  印出事件（或自動推一把）之後，反覆等對方離開 working
#     timeout         → 重掛內層，絕不落回外層（見 _eo_phase_edge_loop
#                        內那段長註解——這是整支腳本最容易寫錯的地方）
#     working 已離開  → 回外層重掛
#     agent_not_found → 邊緣觸發印 GONE，結束這條迴圈
#
# 低頻掃描每 EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 秒一輪 phase-status.sh
# （這個常數與 EO_AUTO_PUSH_LIMIT／EO_SPINNING_SECONDS／
# EO_UNCLASSIFIED_ROUNDS 三個門檻都定義在 common.sh，且都標註「未查
# 證推估，首次真實跑 epic 為校準回合」——本檔引用它們的每個地方都會
# 就近重複這句提醒，不要看到數字就以為是量測出來的），只處理事件通
# 道抓不到的三種、且全部邊緣觸發（印過就靜音，直到條件反轉才解除）：
#   working 但 state_change_seq 久未變化  → SPINNING
#   phase 不在這輪查詢結果裡              → GONE（低頻掃描版，跟外層
#                                            wait 的 agent_not_found 共
#                                            用同一個 gone_muted 欄
#                                            位，見 _eo_scan_gone）
#   狀態連續多輪都是 unknown              → UNCLASSIFIED
#
# main 對每個 phase 的邊緣迴圈子行程也有監督重起，見
# _eo_phase_supervise：連續重起會退避（每次加倍延遲），超過
# EO_PHASE_RESPAWN_GIVEUP_THRESHOLD 次就放棄並印一則事件：
#   phase=<編號> RESPAWN-LIMIT count=<連續重起次數>
# 邊緣迴圈自己確認 agent_not_found（agent_gone 欄位為 true）時也不
# 會被重啟，但不會另外印一則事件——那個情境的事件已經在偵測到的當
# 下由 GONE 印過了。這兩種「不重啟」的情境共用同一套恢復機制：狀態
# 記錄有變動（例如操作者關掉這個 phase 重新 start-phase）才恢復。
#
# ---- 測試方式：EO_GENERATOR_NO_MAIN ----
# 本檔是常駐迴圈，不能整支跑進測試。設定 EO_GENERATOR_NO_MAIN 時，本
# 檔只定義函式就返回，不進入 main；測試藉此把本檔直接 source 進自己
# 的行程，單獨呼叫可測的函式並斷言其行為。凡是不需要 herdr 樁就測得
# 起來的串接層判斷（狀態檔欄位補齊、seq 追蹤的行程內記憶、
# EO_GENERATOR_DRY_RUN 開關、退避與放棄的計數邏輯），都必須有對應測
# 試——這條規則本身是這一輪修正的直接教訓：早先版本裡好幾個嚴重問
# 題，正是因為決策函式各自測起來都對、但串接它們的膠水程式碼從未被
# 任何測試碰過。這條規則同樣適用於呼叫本專案自己另一支姊妹腳本
# （send-to-phase.sh、phase-status.sh）的路徑：那些不是外部二進位，
# 樁化的難度跟樁化 herdr 完全不同量級，不能以「這條路徑要呼叫別的腳
# 本」為理由跟「需要 herdr 樁」混為一談而免測——見
# EO_SEND_TO_PHASE_SCRIPT／EO_PHASE_STATUS_SCRIPT 兩個環境變數。
#
# ---- EO_GENERATOR_DRY_RUN：把「測不了」變成「測得了」----
# 這支腳本唯一會主動對真實 agent 送下行的動作，是自動推進時呼叫
# send-to-phase.sh（見 _eo_do_auto_push）。設定 EO_GENERATOR_DRY_RUN
# 時完全不呼叫 send-to-phase.sh，改在 stderr 印一行可辨識的觀察行；
# 這不只是安全考量（測試與人工排錯都不該真的碰真實 agent），也讓這
# 段原本零測試覆蓋的迴圈層變得可以在完全不需要 herdr 樁的情況下驗證
# ——見上方「測試方式」那條規則。
#
# ---- 單例守衛：pidfile ----
# 常駐產生器只能同時存在一份，見 main 開頭的 _eo_acquire_singleton與
# 其註解：兩個產生器同時寫 last_marker_seq，會讓「seq 只會變大」這個
# 整條事件通道賴以判斷「標記是新是舊」的假設失效。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 重複 source 的風險：common.sh 用 readonly 定義門檻常數 ----
# 測試的做法是把本檔直接 source 進「已經 source 過 common.sh」的那個
# 測試行程（見檔頭「測試方式」），不是像其餘六支腳本那樣用 `bash
# foo.sh` 開新子行程執行。若這裡跟其餘六支腳本一樣無條件
# `source lib/common.sh`，common.sh 裡的 `readonly EO_AUTO_PUSH_LIMIT=40`
# 等敘述會在同一個行程裡對已經是 readonly 的變數再賦值一次，在
# set -e 下讓當下的 shell（也就是整個測試腳本）直接終止。用函式是否
# 已定義判斷 common.sh 是否已經載入過，比檢查某個變數更貼近「這是不
# 是同一份函式庫」的語意。
if ! declare -F eo_die >/dev/null; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/lib/common.sh"
fi

# ---- 本檔專屬的逾時／節奏值 ----
# 120000 毫秒不是未查證推估，是刻意的工程取捨：逾時不決定 phase 能跑
# 多久（迴圈永不放棄，重掛就是了），它決定的是「phase 消失」多久被
# 發現。代價只是每兩分鐘一次本機呼叫，換來消失最多兩分鐘被發現。這
# 個值跟 send-to-phase.sh 那個 10000 毫秒握手逾時是兩件不同的事——
# 握手逾時等的是「對方接手了」，這個逾時等的是「對方還在不在」，不
# 要因為兩者單位都是毫秒就以為可以一起調。
readonly EO_WAIT_TIMEOUT_MS=120000

# _eo_agent_wait 用內部信號跟呼叫端溝通「逾時」與「agent_not_found」，
# 只在本檔案內部使用，不是本專案結束碼表（0–8）的一部分；借用 GNU
# timeout 慣用的 124 代表逾時，125 沿用同一序列代表 agent_not_found，
# 純粹避免跟 0–8 或 herdr 自己的 1／2 混在一起。
readonly _EO_WAIT_TIMEOUT_RC=124
readonly _EO_WAIT_NOT_FOUND_RC=125

# event-generator.sh 專屬、不屬於七支腳本共用結束碼表（0–8）的碼：
# 9＝單例守衛擋下第二個常駐產生器（見 _eo_acquire_singleton）。只有
# 這支腳本會產生 9，因此不併入 common.sh 的共用表，只在這裡文件化。
readonly EO_SINGLETON_CONFLICT_EXIT_CODE=9

# 這個值只決定「新派工或剛收尾的 phase 多快被本迴圈接住監看」，不影
# 響任何事件是否正確，只影響延遲，因此不算三個未查證門檻之一，不必
# 逐字照抄或加校準註記。
readonly EO_PHASE_POLL_SECONDS=5

# ---- 自動推進送出的文字：權威在 phase-agent-contract.md，這裡只是
#      跟著同一份定案 ----
# 已由編排端定案（任務七審查裁定，2026-09-08）：這段文字的權威來源
# 是 phase-agent-contract.md，不是這支腳本——契約改寫任務會把同一段
# 文字帶進契約檔，讓兩邊一致。這裡逐字抄一份，是因為腳本要能獨立執
# 行，不能在執行期讀契約檔的內文來組這個下行。往後任何一邊改了這段
# 文字，另一邊要一起改，不能各自表述兩套「繼續」的說法。
#
# 措辭本身的理由：自動推進這條路徑的語意只有一件事——對方剛結束一
# 個回合、沒有待決事項，推它繼續，不需要引入任何新詞彙；提醒維持標
# 記行的約定，是因為標記行是整條事件通道的判讀依據，漏印一次就會被
# eo_classify_stop 判成標記缺席（marker=none），白派一次調查者。
readonly EO_AUTO_PUSH_TEXT='繼續進行你的 phase 任務。回合結束時依契約在畫面最後一行印出狀態標記。'

# ---- phase 邊緣迴圈連續重起的退避與放棄門檻 ----
# 未查證推估，首次真實跑 epic 為校準回合，與 common.sh 那三個門檻同
# 樣待校準：連續重起超過這個次數就放棄，改印一則事件交回
# orchestrator，直到狀態記錄有變動才恢復（見 _eo_phase_supervise）。
readonly EO_PHASE_RESPAWN_GIVEUP_THRESHOLD=6
# 未查證推估，首次真實跑 epic 為校準回合：退避延遲的上限秒數，避免
# 加倍下去無限增長。
readonly EO_PHASE_RESPAWN_BACKOFF_MAX_SECONDS=300

# ---- 常駐迴圈用的行程內狀態（不落地狀態檔，隨本行程結束而消失）----
declare -A _EO_PHASE_PIDS    # phase -> 該 phase 邊緣迴圈子行程的 PID
_EO_LOW_FREQ_PID=""          # 低頻掃描子行程的 PID
declare -A _EO_SPIN_SEQ      # phase -> 低頻掃描上次觀測到的 state_change_seq
declare -A _EO_SPIN_EPOCH    # phase -> 上面那個 seq 第一次被觀測到的 epoch 秒
declare -A _EO_PHASE_RESPAWN_COUNT       # phase -> 連續重起次數（健康時歸零）
declare -A _EO_PHASE_NEXT_RESPAWN_EPOCH  # phase -> 退避延遲下，下次允許重起的 epoch 秒
declare -A _EO_PHASE_GIVEUP_FINGERPRINT  # phase -> 放棄重起當下的狀態指紋；非空代表目前處於放棄狀態

# _eo_require_int <value> <desc>（內部輔助函式）
# 狀態檔讀出來、即將進算術展開（`$(( ))`）或整數比較的數值欄位，先
# 驗證是純數字（不含負號：這幾個欄位——last_marker_seq／
# auto_push_count／unknown_rounds／state_change_seq 差值——語意上都
# 不會是負的）。這裡要防的不是格式錯誤這麼單純：bash 的算術展開對運
# 算元的值會再展開一次，值裡藏著指令替換的字串會被執行——已由獨立
# 審查用真實 jq 1.8.2 重現：把 unknown_rounds 設成一段含指令替換的字
# 串，呼叫決策函式後真的建立了檔案、內容是使用者名稱，而且照常印出
# 事件行。狀態檔不是可信輸入：中斷恢復會重建狀態記錄、狀態檔也可能
# 被手動編輯，兩條路徑都不經過任何腳本驗證格式，因此每一個要進算術
# 或整數比較的欄位都要先過這一關，不是只補審查者指出的那一個。不通
# 過就以 5 結束（狀態檔缺漏／內容不合法，沿用既有結束碼 5 的「狀態
# 檔有問題」語意，不是新開一個碼）。
_eo_require_int() {
  local value="$1" desc="$2"
  case "$value" in
    ''|*[!0-9]*)
      eo_die 5 "event-generator.sh: 狀態檔欄位不是合法整數（$desc）：$value"
      ;;
  esac
}

# _eo_ensure_field <phase> <field> <json_default>（內部輔助函式）
# 欄位已存在就不動，不存在才補上預設值。
#
# ---- 為什麼呼叫要包進命令替換（子殼），不能是裸呼叫 ----
# eo_state_get 對缺漏的欄位呼叫 eo_die，那是真正的 `exit`，不是
# `return`。`exit` 一律終止「當下正在執行它的那個行程」，跟它是不是
# 被 if／&&／|| 當條件測試完全無關——if 的「條件豁免」只免除 errexit
# 對非零結束碼的反應，攔不住一個明講要結束行程的 exit。舊版把
# eo_state_get 寫成裸呼叫（`if ! eo_state_get ... >/dev/null 2>&1;
# then`），沒有開新行程，於是那個 exit 5 直接終止了呼叫端整個行程；
# 獨立審查用「只含三個座標欄位的狀態檔」（也就是 start-phase.sh 真
# 正會寫的那三個：tab_id／pane_id／agent_name）重現過：呼叫
# _eo_ensure_phase_defaults 後行程以 5 結束、七個欄位一個都沒補到，
# 而這正是每個由 start-phase.sh 建立的 phase 的預設狀態——事件產生
# 器因此在真實流程下對每個 phase 都會這樣悄悄死掉。改成
# `existing="$(eo_state_get ...)"` 之後，eo_state_get 的 exit 是在
# 命令替換開的子殼裡發生，只終止那個子殼；父行程（也就是
# _eo_ensure_field 自己）拿到的是子殼的非零結束碼，這時 if 的條件豁
# 免才真正管用。這裡不轉發 eo_state_get 失敗時的訊息（`2>/dev/null`
# 丟掉 stderr）：在這個函式的語境下，「欄位不存在」是預期中、正常
# 的第一次呼叫路徑，不是要回報的錯誤。
#
# ---- 這是消費端的職責，不是產生端漏了該補（編排端裁定，任務七審
#      查階段，2026-09-08）----
# 容忍欄位缺漏必須留在讀取這些欄位的一方（本檔案），不能改成依賴
# start-phase.sh 在 phase 啟動時把七個欄位一次寫齊。理由是狀態記錄
# 至少有兩條會繞過 start-phase.sh 的路徑：中斷恢復會依 GitHub 與
# herdr 的現況重建狀態記錄，狀態檔本身也可能被人手動編輯過——這兩
# 條路徑都不經過 start-phase.sh，若把「欄位一定齊全」的假設寄託在它
# 身上，遇到這兩條路徑一樣會缺漏。反過來，讓消費端自己容忍缺漏、缺
# 了就補上預設值，不論欄位是被誰用哪一種方式建立的都成立。也因此不
# 要把這段邏輯搬去 start-phase.sh、或看到這裡就以為是遺漏而想拿掉：
# 在產生端也做一次初始化只是多一層冗餘，換不到消費端仍然要有的這層
# 容忍。
_eo_ensure_field() {
  local phase="$1" field="$2" default="$3"
  local existing
  # shellcheck disable=SC2034 # 只需要命令替換帶來的子殼隔離與它的結束碼；欄位目前的值不需要用到，見上方大段落說明
  if existing="$(eo_state_get "$phase" "$field" 2>/dev/null)"; then
    return 0
  fi
  eo_state_set "$phase" "$field" "$default"
}

# _eo_ensure_phase_defaults <phase>
# 確保低頻掃描與邊緣迴圈依賴的欄位都存在。呼叫端（_eo_phase_edge_loop
# 起步時、_eo_low_freq_process_one 每次處理某個 phase 時）各自獨立呼
# 叫一次，成本是最多幾次 `jq -e` 查詢，換來不必假設有任何人已經初始
# 化過這些欄位。
#
# 前七個預設值已核對過與 constraints.md 狀態檔 schema 一致：三個靜
# 音欄位（spinning_muted／gone_muted／unclassified_muted）schema 裡
# 就是 false，直接採用；unknown_rounds schema 範例本來就是 0，直接
# 採用；last_marker_seq／auto_push_count 兩個計數欄位 schema 範例分
# 別是 17／3，但那是一個「已經跑過一陣子」的 phase 的示範值，不是初
# 始值——一個剛起步、還沒看過任何標記、還沒自動推過的 phase，這兩個
# 計數本來就該是 0，跟 schema 描述的欄位語意（累計次數）並不衝突；
# held_by_orchestrator schema 範例是 false，直接採用。
#
# agent_gone 是這一輪（修正輪次 3／5，High B）新增、不在 constraints.md
# 原始七個欄位之列的第八個欄位：只由 _eo_phase_edge_loop 自己確認
# agent_not_found 時設成 true，只由 _eo_phase_supervise 的放棄指紋
# 機制在狀態記錄變動時清回 false，低頻掃描完全不 touch 它——理由見
# _eo_scan_gone 與 _eo_phase_edge_loop 裡對應分支的說明。
_eo_ensure_phase_defaults() {
  local phase="$1"
  _eo_ensure_field "$phase" last_marker_seq 0
  _eo_ensure_field "$phase" held_by_orchestrator false
  _eo_ensure_field "$phase" auto_push_count 0
  _eo_ensure_field "$phase" unknown_rounds 0
  _eo_ensure_field "$phase" spinning_muted false
  _eo_ensure_field "$phase" gone_muted false
  _eo_ensure_field "$phase" unclassified_muted false
  _eo_ensure_field "$phase" agent_gone false
}

# eo_classify_stop <phase> <停下狀態> <標記行>
# 純決策函式：不呼叫 herdr、不呼叫任何其餘腳本，只讀寫狀態檔、印出
# 事件行（或印出空字串代表「自動推進，orchestrator 完全看不到這次停
# 下」）。刻意保持純粹，測試才能在完全沒有 herdr 樁的情況下單獨驗證
# 判斷邏輯；真正送出自動推進下行的動作在 _eo_phase_edge_loop 裡，看
# 到這裡回傳空字串才去做。
#
# <停下狀態> 是 idle／done／blocked 三者之一（下面會驗證，不直接信
# 任呼叫端傳來的字串——它在真實流程裡是 herdr 回報的 agent_status，
# 若因為某個時序巧合被判成 working 或 unknown 送進來，不能沒有防
# 備）；<標記行> 是 read-phase-pane.sh --marker-only 的輸出：要嘛是
# `[PHASE <n>] seq=<N> state=<STATE...>`，要嘛是抓不到標記行時的哨
# 兵字串 `marker=none`。
eo_classify_stop() {
  local phase="$1" stopped="$2" marker_line="$3"
  local pattern seq state_str last_seq held auto_count

  case "$phase" in
    ''|*[!0-9]*)
      eo_die 2 "eo_classify_stop: <phase> 必須是純數字，收到：$phase"
      ;;
  esac
  case "$stopped" in
    idle|done|blocked) ;;
    *)
      eo_die 2 "eo_classify_stop: <停下狀態> 必須是 idle／done／blocked 之一，收到：$stopped"
      ;;
  esac

  # 解析標記行，且核對標記行裡的 phase 編號與參數一致——不能只信任
  # 呼叫端（例如 read-phase-pane.sh 用 pane_id 對過號）已經保證這一
  # 點，那是函式契約外的依賴，核對標記與參數是否對得上是這個決策函
  # 式自己的責任。抓不到或編號對不上就直接視同 marker=none，不進 seq
  # 比對——沒有 seq 可比，比較本身沒有意義。這個正規表示式同時涵蓋
  # 字面上的哨兵字串 `marker=none`：那個字串本來就不會匹配
  # `^\[PHASE ...`。
  pattern="^\\[PHASE ${phase}\\] seq=([0-9]+) state=(.*)\$"
  seq=""
  state_str=""
  if [[ "$marker_line" =~ $pattern ]]; then
    seq="${BASH_REMATCH[1]}"
    state_str="${BASH_REMATCH[2]}"
  fi

  if [ -z "$seq" ]; then
    printf 'phase=%s stopped=%s marker=none\n' "$phase" "$stopped"
    return 0
  fi

  last_seq="$(eo_state_get "$phase" last_marker_seq)"
  _eo_require_int "$last_seq" "phase $phase last_marker_seq"
  if [ "$seq" -le "$last_seq" ]; then
    # seq 沒有變大：上一回合的標記還留在畫面上，等同標記缺席。危險
    # 方向是舊標記被當成新的，只有 seq 攔得住——這裡絕不能把它當成
    # 一則新事件處理。
    printf 'phase=%s stopped=%s marker=none\n' "$phase" "$stopped"
    return 0
  fi

  # 走到這裡代表真的看到一則新標記，不論下面哪個分支都要先記住這個
  # seq，下一輪才不會把它再判成舊的。
  eo_state_set "$phase" last_marker_seq "$seq"

  held="$(eo_state_get "$phase" held_by_orchestrator)"
  # 已 blocked 的目標不做自動推進：approval 對話框需要
  # press-approval.sh 代按，不是文字下行。send-to-phase.sh 對 blocked
  # 目標本來就會被 herdr 以 agent_blocked 拒絕（見 constraints.md 已
  # 查證表），在分類階段就先排除，不必等呼叫失敗才發現、也不會因此
  # 吞掉一次原本該讓 orchestrator 看到的通知。
  if [ "$held" != "true" ] && [ "$stopped" != "blocked" ] && [ "$state_str" = "working-ok" ]; then
    auto_count="$(eo_state_get "$phase" auto_push_count)"
    _eo_require_int "$auto_count" "phase $phase auto_push_count"
    # EO_AUTO_PUSH_LIMIT 定義在 common.sh，未查證推估，首次真實跑
    # epic 為校準回合，值不得自行調整。
    if [ "$auto_count" -ge "$EO_AUTO_PUSH_LIMIT" ]; then
      printf 'phase=%s AUTO-PUSH-LIMIT count=%s\n' "$phase" "$auto_count"
      return 0
    fi
    eo_state_set "$phase" auto_push_count "$((auto_count + 1))"
    return 0
  fi

  # 交回 orchestrator 的路徑：不論是 held_by_orchestrator 互斥擋下、
  # 對方是 blocked、還是標記根本不是 working-ok，都算「這一輪連續自
  # 動推進的紀錄中斷了」，歸零讓下一次 working-ok 重新從頭數，這樣
  # 「連續」兩個字才有意義。
  eo_state_set "$phase" auto_push_count 0
  printf 'phase=%s stopped=%s marker=%s\n' "$phase" "$stopped" "$state_str"
}

# eo_scan_spinning <phase> <目前 state_change_seq> <該 seq 上次變動的 epoch 秒>
# 邊緣觸發：狀態持續 working 但 state_change_seq 久未變化超過
# EO_SPINNING_SECONDS（定義在 common.sh，未查證推估，首次真實跑
# epic 為校準回合）就印一次 SPINNING，印過就靜音直到 seq 變動、
# elapsed 掉回門檻以下才解除。
#
# 第二個參數（目前 state_change_seq）本身不影響這裡的決策：真正決定
# 要不要印的只有第三個參數算出來的 elapsed。「seq 是否變動」這件事
# 由呼叫端（_eo_low_freq_scan_once）自己用行程內的關聯陣列追蹤，變
# 動時才把 epoch 重設成當下時間再傳進來——第二個參數留在介面裡是給
# 呼叫端那一行程式碼自我說明用的，不是決策函式需要的輸入。
eo_scan_spinning() {
  local phase="$1" changed_epoch="$3"
  local now elapsed muted

  _eo_require_int "$changed_epoch" "phase $phase 的『seq 上次變動 epoch』參數"
  now="$(date +%s)"
  elapsed=$((now - changed_epoch))
  muted="$(eo_state_get "$phase" spinning_muted)"

  if [ "$elapsed" -ge "$EO_SPINNING_SECONDS" ]; then
    if [ "$muted" != "true" ]; then
      eo_state_set "$phase" spinning_muted true
      printf 'phase=%s SPINNING\n' "$phase"
    fi
  else
    if [ "$muted" = "true" ]; then
      eo_state_set "$phase" spinning_muted false
    fi
  fi
}

# eo_scan_unknown <phase> <目前 agent_status>
# 邊緣觸發：狀態連續 EO_UNCLASSIFIED_ROUNDS（定義在 common.sh，未查
# 證推估，首次真實跑 epic 為校準回合）輪都是 unknown 才印一次
# UNCLASSIFIED，印過就靜音直到狀態變成別的才解除。呼叫端每輪都要
# 呼叫本函式（不論這輪狀態是不是 unknown），讓計數與解除靜音都在同
# 一個地方處理，呼叫端不必自己另外判斷「要不要歸零」。
eo_scan_unknown() {
  local phase="$1" status="$2"
  local rounds muted

  if [ "$status" = "unknown" ]; then
    rounds="$(eo_state_get "$phase" unknown_rounds)"
    _eo_require_int "$rounds" "phase $phase unknown_rounds"
    rounds=$((rounds + 1))
    eo_state_set "$phase" unknown_rounds "$rounds"

    muted="$(eo_state_get "$phase" unclassified_muted)"
    if [ "$rounds" -ge "$EO_UNCLASSIFIED_ROUNDS" ] && [ "$muted" != "true" ]; then
      eo_state_set "$phase" unclassified_muted true
      printf 'phase=%s UNCLASSIFIED\n' "$phase"
    fi
  else
    eo_state_set "$phase" unknown_rounds 0
    muted="$(eo_state_get "$phase" unclassified_muted)"
    if [ "$muted" = "true" ]; then
      eo_state_set "$phase" unclassified_muted false
    fi
  fi
}

# _eo_scan_gone <phase> <這輪查詢是否看得到這個 phase：0|1>（內部輔助函式）
# GONE 事件本身的邊緣觸發（純粹是「要不要印這一行」的報告用靜音，
# 不是要不要重啟邊緣迴圈的判斷——那個判斷是 agent_gone 欄位的責
# 任，見 _eo_phase_edge_loop 與 _eo_phase_supervise）。兩條通道共用
# 同一個 gone_muted 欄位：外層／內層邊緣迴圈偵測到 agent_not_found
# 時呼叫（present=0），低頻掃描見到 phase-status.sh 查全部模式回報
# 這個 phase 是 ERROR 時也呼叫（present=0）——同一次消失不論哪條通
# 道先看到，都只印一次；present=1 只會由低頻掃描呼叫，用來在 phase
# 重新出現於查詢結果時解除這個報告用的靜音。
#
# ---- 為什麼不能也拿這個欄位決定要不要重啟邊緣迴圈（High B，獨立審
#      查修正輪次 3／5 找到的問題）----
# 兩條通道認的是不同識別碼：邊緣迴圈等的是 eo_agent_name 推導出來的
# agent 名稱，低頻掃描比對的是狀態檔的 pane 識別碼是否還在
# snapshot 裡。當 pane 還在、但那個 agent 名稱已經不再註冊時，低頻
# 掃描的 present=1 會把這個共用欄位解回 false；若同一個欄位也被拿
# 來當「main 該不該重啟這條迴圈」的閘門，閘門就會被打開，重啟後立
# 刻又撞上 agent_not_found、再印一次 GONE，兩個判讀只要持續不一
# 致，這個循環就永遠不會停（已被獨立審查實測：45 秒印 4 則）。因此
# 「這一次消失有沒有報告過」（本欄位）與「這條迴圈該不該被重啟」
# （agent_gone）必須是兩個獨立欄位，後者只由邊緣迴圈自己設定、只由
# 狀態指紋變動時清除，低頻掃描完全不 touch 它。
_eo_scan_gone() {
  local phase="$1" present="$2"
  local muted

  muted="$(eo_state_get "$phase" gone_muted)"
  if [ "$present" -eq 0 ]; then
    if [ "$muted" != "true" ]; then
      eo_state_set "$phase" gone_muted true
      printf 'phase=%s GONE\n' "$phase"
    fi
  else
    if [ "$muted" = "true" ]; then
      eo_state_set "$phase" gone_muted false
    fi
  fi
}

# _eo_track_spin_seq <phase> <status> <seq>（內部輔助函式）
# 更新「這個 phase 的 state_change_seq 上次變動的 epoch」，供
# eo_scan_spinning 的第三個參數使用。
#
# ---- 為什麼刻意寫成裸呼叫、不能包進命令替換或子殼 ----
# 這個函式的唯一目的是把結果寫進行程內的關聯陣列 _EO_SPIN_SEQ／
# _EO_SPIN_EPOCH，讓下一輪呼叫還讀得到。子殼（含命令替換 `$(...)`）
# 會複製一份父行程當下的變數，子殼裡對這些陣列的寫入只存在於子殼自
# 己的記憶體，子殼結束就消失，回不到父行程——這正是上一版的真正問
# 題：舊版把整段追蹤邏輯寫在 _eo_low_freq_process_one 裡，而那個函
# 式被 _eo_low_freq_scan_once 包進 `( set -euo pipefail; ... )` 隔離
# 子殼呼叫（隔離子殼本身沒有錯，見下方 _eo_low_freq_scan_once 的說
# 明），於是每一輪寫進陣列的值都在子殼結束的瞬間報廢，下一輪
# eo_scan_spinning 拿到的「上次變動的 epoch」不會早於「現在」太多，
# elapsed 因此永遠算不出「久未變化」，SPINNING 整條事件類型死掉。獨
# 立審查用固定序號連續跑兩輪重現過：兩輪都判成剛變動、父行程的陣列
# 事後仍未設定。修法是把追蹤本身移出被隔離的那一層，這個函式因此必
# 須留在 _eo_low_freq_scan_once 自己的行程裡用裸呼叫執行，不能包進
# 任何子殼；真正需要隔離失敗的部分（_eo_low_freq_process_one）維持
# 用子殼呼叫，兩者分工。
_eo_track_spin_seq() {
  local phase="$1" status="$2" seq="$3"
  local now

  [ "$status" = "working" ] || return 0

  now="$(date +%s)"
  if [ "${_EO_SPIN_SEQ[$phase]:-}" != "$seq" ]; then
    _EO_SPIN_SEQ[$phase]="$seq"
    _EO_SPIN_EPOCH[$phase]="$now"
  fi
}

# _eo_agent_wait <target> <herdr agent wait 的其餘參數...>（內部輔助函式）
# 呼叫 `herdr agent wait`，把「成功」「逾時」「agent_not_found」三種
# 結果拆開，讓外層迴圈用 case 分流。不用 common.sh 的 eo_herdr——
# eo_herdr 把 herdr 結束碼 1 全部映射成 6，會把這三種混成同一碼，但
# 這裡三者的處置完全不同（成功要印事件、逾時要重掛、agent_not_found
# 要印 GONE 並結束整條迴圈）。
#
# 用 `2>&1` 把 stdout／stderr 合併成同一次擷取：herdr 成功時只在
# stdout 印 JSON、失敗時只在 stderr 印 JSON（已對真實 herdr 0.8.2 查
# 證），兩種情形合併擷取後 output 裡永遠是那份 JSON，不需要為了同時
# 保留「成功時的內容」與「失敗時的錯誤碼」而分別開兩支管線或暫存檔。
#
# 回傳（透過函式自身的結束碼）：
#   0                       成功，agent 物件的完整 JSON 印在 stdout
#   $_EO_WAIT_TIMEOUT_RC    逾時
#   $_EO_WAIT_NOT_FOUND_RC  agent_not_found
#   其餘                    herdr 原始結束碼原樣拋出（結束碼 2 視為本
#                           檔案呼叫 herdr 的語法有 bug，直接用 eo_die
#                           終止；結束碼 1 但錯誤碼非上述兩種同樣視為
#                           未預期情形，用 eo_die 6 終止）
_eo_agent_wait() {
  local target="$1"
  shift
  local output rc code

  if output="$(herdr agent wait "$target" "$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  else
    rc=$?
  fi

  if [ "$rc" -eq 2 ]; then
    eo_die 2 "event-generator.sh: herdr 以結束碼 2 拒絕 agent wait，疑似腳本呼叫語法錯誤：herdr agent wait $target $*"
  fi
  if [ "$rc" -ne 1 ]; then
    return "$rc"
  fi

  code="$(printf '%s' "$output" | jq -r '.error.code // empty' 2>/dev/null || true)"
  case "$code" in
    timeout)
      return "$_EO_WAIT_TIMEOUT_RC"
      ;;
    agent_not_found)
      return "$_EO_WAIT_NOT_FOUND_RC"
      ;;
    *)
      eo_die 6 "event-generator.sh: herdr 以結束碼 1 拒絕 agent wait（target=$target），錯誤碼非預期：$output"
      ;;
  esac
}

# _eo_do_auto_push <phase>（內部輔助函式）
# 執行自動推進的下行動作，是這支腳本唯一會主動對真實 agent 送下行的
# 地方。設定 EO_GENERATOR_DRY_RUN 時完全不呼叫 send-to-phase.sh（因
# 此也不會觸及 herdr），改在 stderr 印一行可辨識的觀察行——這個分支
# 不需要任何 herdr 樁就測得起來，依規定必須有測試（見任務報告
# Medium 13、檔頭「測試方式」）。回傳 send-to-phase.sh 的結束碼；
# dry-run 模式視為成功，回傳 0。
#
# ---- EO_SEND_TO_PHASE_SCRIPT：測試樁化 send-to-phase.sh 用 ----
# 這裡呼叫的是「$SCRIPT_DIR/send-to-phase.sh」這個明確路徑，不是靠
# PATH 解析的裸指令名，herdr 樁那套「在 PATH 前面插一個樁目錄」的手
# 法在這裡用不上——樁化 herdr 遮蔽的是一個外部二進位的名字，這裡要
# 遮蔽的是本專案自己另一支腳本的絕對路徑。改用環境變數間接：預設值
# 就是真正的路徑，測試設定這個變數就能換成一支假腳本（不需要處理
# herdr 的 JSON 回應形狀，只要照 send-to-phase.sh 的文件化契約回傳
# 對應結束碼即可，樁化難度跟樁化 herdr 完全不同量級），正常執行時
# 完全不受影響。
_eo_do_auto_push() {
  local phase="$1" script
  if [ -n "${EO_GENERATOR_DRY_RUN:-}" ]; then
    printf 'phase=%s DRY-RUN-AUTO-PUSH\n' "$phase" >&2
    return 0
  fi
  script="${EO_SEND_TO_PHASE_SCRIPT:-$SCRIPT_DIR/send-to-phase.sh}"
  bash "$script" "$phase" "$EO_AUTO_PUSH_TEXT" >/dev/null 2>&1
}

# _eo_run_auto_push_or_fallback <phase> <停下狀態>（內部輔助函式）
# 呼叫 _eo_do_auto_push；成功就什麼都不印，失敗就印一則
# stopped=<狀態> marker=working-ok 事件交回 orchestrator。
#
# ---- 為什麼這段失敗處理要抽成獨立函式 ----
# 自動推進送出失敗（agent_blocked、握手逾時等）不能靜默吞掉：
# eo_classify_stop 判定過這是 working-ok 且該自動推進，會走到這裡的
# 必然是 state=working-ok，因此可以直接印出對應的 stopped 事件。
# eo_classify_stop 已經把 last_marker_seq 推進過，若這裡什麼都不
# 印，這個 phase 會直接卡進內層 wait -- until working 永遠等不到
# （沒有人真的送出東西讓它離開 done），下一輪外層 wait 就算重新命中
# 同一個標記也只會判成 marker=none——沒有回退路徑，只能在這裡當下
# 就把控制權交還給 orchestrator。抽成獨立函式是為了讓這段失敗處理
# 邏輯可以在不需要 herdr 樁的情況下，用一支回傳 7 的 send-to-phase.sh
# 樁單獨驗證——這是有沒有事件抵達 orchestrator 的分界，重要性不容許
# 只靠人工核對程式碼邏輯。
_eo_run_auto_push_or_fallback() {
  local phase="$1" stopped="$2"
  if _eo_do_auto_push "$phase"; then
    return 0
  fi
  printf 'phase=%s stopped=%s marker=working-ok\n' "$phase" "$stopped"
}

# _eo_phase_edge_loop <phase>（內部輔助函式，以背景子行程執行）
# 單一 phase 的邊緣迴圈，見檔頭「整體形狀」那段的外層／內層說明。
_eo_phase_edge_loop() {
  local phase="$1"
  local agent

  agent="$(eo_agent_name "$phase")"
  _eo_ensure_phase_defaults "$phase"

  while true; do
    local wait_result rc

    # 每次外層迴圈重新開始前，先確認這個 phase 還在狀態檔裡——它可
    # 能在等待期間被收尾移除（close-phase.sh 呼叫
    # eo_state_remove_phase）。找不到就安靜結束這條迴圈，不印任何驚
    # 動人的訊息：這是成功收尾的正常後果，不是故障（Medium C，獨立
    # 審查修正輪次 3／5 找到的問題）。main 的監督邏輯本來就會在下一
    # 輪呼叫 _eo_forget_phase 順便收掉這條迴圈，這裡只是讓它不必等
    # 到下一次 wait 才發現、也不會在半路因為 eo_classify_stop 內部
    # 某個 eo_state_get 讀不到欄位而印出看起來像 bug 的內部錯誤訊
    # 息。
    local still_exists
    # shellcheck disable=SC2034 # 只需要命令替換帶來的子殼隔離與它的結束碼；欄位值本身不需要用到，理由同 _eo_ensure_field
    if still_exists="$(eo_state_get "$phase" tab_id 2>/dev/null)"; then
      :
    else
      return 0
    fi

    # "done" 這個字面值必須加引號：不加的話 shellcheck 的解析器會把它
    # 誤判成 do/done 迴圈語法的收尾字，跟這裡單純是 --until 的一個字
    # 面值參數無關（SC1010，已查證是解析器層級的假警告，加引號後同時
    # 消音也更清楚表明這是字面字串，不是語法關鍵字）。
    if wait_result="$(_eo_agent_wait "$agent" --until idle --until "done" --until blocked --timeout "$EO_WAIT_TIMEOUT_MS")"; then
      rc=0
    else
      rc=$?
    fi

    case "$rc" in
      "$_EO_WAIT_TIMEOUT_RC")
        # 外層逾時：不印任何一行，重掛外層。
        continue
        ;;
      "$_EO_WAIT_NOT_FOUND_RC")
        # 印一次 GONE（gone_muted，跟低頻掃描共用同一個報告用靜音欄
        # 位，見 _eo_scan_gone），並且把 agent_gone 設成 true——這個
        # 欄位只由這裡（邊緣迴圈自己確認 agent_not_found）設定，只由
        # _eo_phase_supervise 的放棄指紋機制清除，低頻掃描完全不
        # touch 它。main 的監督邏輯靠 agent_gone 決定不重新起一條迴
        # 圈，不是靠 gone_muted：兩者一度共用同一個欄位，導致 pane
        # 還在、但這個推導出來的 agent 名稱已經不再註冊時，低頻掃描
        # （認的是 pane_id，不是 agent 名稱）判定「這個 phase 還
        # 在」、把共用欄位解回 false，監督層的閘門被打開、重起邊緣
        # 迴圈、立刻又撞上 agent_not_found、再印一次 GONE——已被獨
        # 立審查實測：45 秒印 4 則，換算生產值約每 phase 每小時 55
        # 則，四個 phase 併行約 220 則，超過簡報定案的致命值 120，
        # 而且只要兩條通道的判讀持續不一致就永遠不會停。拆成兩個欄
        # 位後，低頻掃描的「重新出現」只解除 gone_muted（報告用），
        # 不會再打開這個重啟閘門。
        _eo_scan_gone "$phase" 0
        eo_state_set "$phase" agent_gone true
        return 0
        ;;
      0)
        local stopped_status marker event
        stopped_status="$(printf '%s' "$wait_result" | jq -r '.result.agent.agent_status')"

        # read-phase-pane.sh 失敗時一律視同 marker=none：失敗方向是
        # 安全的（頂多多派一次 investigator），真正的 GONE 由上面的
        # agent_not_found 與低頻掃描各自獨立偵測，不必在這裡重做一次
        # 判斷。
        if marker="$(bash "$SCRIPT_DIR/read-phase-pane.sh" "$phase" --marker-only 2>/dev/null)"; then
          :
        else
          marker="marker=none"
        fi

        event="$(eo_classify_stop "$phase" "$stopped_status" "$marker")"
        if [ -z "$event" ]; then
          # 自動推進（或送出失敗時的回退事件）：見
          # _eo_run_auto_push_or_fallback 的說明，那段失敗處理邏輯獨
          # 立成函式是為了讓它能在不需要 herdr 樁的情況下單獨測試。
          _eo_run_auto_push_or_fallback "$phase" "$stopped_status"
        else
          printf '%s\n' "$event"
        fi

        # 不論剛才是自動推一把還是印了事件交給 orchestrator，都要按
        # 住直到對方離開目前這個停下狀態。
        #
        # ---- 逾時必須重掛內層，絕不能落回外層 ----
        # 停下的 phase 會一直停在 done 不會自己離開（實測：對一個已
        # 經 done 的 agent 重掛外層等待，連續三次都是 5 毫秒立刻回
        # 傳）。一個等 review 的 PR-ready phase 可能在那裡停好幾個小
        # 時。如果這裡把逾時分支寫成 `continue` 外層而不是重掛這個內
        # 層 while，外層會立刻再命中同一個 done、再印一次同樣的事件
        # ——變成每兩分鐘一則的慢速事件風暴，四個 phase 各停一小時就
        # 是一百二十則重複事件，而事件過多的監看會被自動停掉，正好
        # 摧毀這支腳本存在的理由。
        while true; do
          local inner_rc
          if _eo_agent_wait "$agent" --until working --timeout "$EO_WAIT_TIMEOUT_MS" >/dev/null; then
            inner_rc=0
          else
            inner_rc=$?
          fi
          case "$inner_rc" in
            "$_EO_WAIT_TIMEOUT_RC")
              continue
              ;;
            0)
              break
              ;;
            "$_EO_WAIT_NOT_FOUND_RC")
              # 同上方外層那個分支：agent_gone 只由邊緣迴圈自己確認
              # agent_not_found 時設定，見那裡的完整說明。
              _eo_scan_gone "$phase" 0
              eo_state_set "$phase" agent_gone true
              return 0
              ;;
            *)
              # 未預期的結束碼：不是逾時、不是離開 working、不是
              # agent_not_found。main 的監督邏輯會在下一輪把這條迴
              # 圈重新起來（這是刻意的自我修復，不是本項要擋的
              # GONE 風暴——這裡沒有已經印過的事件會被重印），但這
              # 個死亡本身不該無聲無息，記一行到 stderr 供排錯。
              printf 'event-generator.sh: phase %s 的內層等待收到未預期結束碼 %s，這條迴圈即將結束（main 會重新監看）\n' \
                "$phase" "$inner_rc" >&2
              return "$inner_rc"
              ;;
          esac
        done
        ;;
      *)
        printf 'event-generator.sh: phase %s 的外層等待收到未預期結束碼 %s，這條迴圈即將結束（main 會重新監看）\n' \
          "$phase" "$rc" >&2
        return "$rc"
        ;;
    esac
  done
}

# _eo_low_freq_process_one <phase> <status> <seq> <changed_epoch>（內部輔助函式）
# 處理低頻掃描一輪裡、單一 phase 已經解析好的資料。四個參數都是呼叫
# 端（_eo_low_freq_scan_once）先解析好、算好才傳進來的純值，這個函
# 式本身不解析任何原始輸出、也不做 seq 追蹤——理由見
# _eo_low_freq_scan_once 與 _eo_track_spin_seq 的說明：這個函式會被
# 包進隔離子殼呼叫，任何需要「寫回父行程」的狀態都不能放在這裡。
_eo_low_freq_process_one() {
  local phase="$1" status="$2" seq="$3" changed_epoch="$4"

  _eo_ensure_phase_defaults "$phase"

  if [ "$status" = "ERROR" ]; then
    _eo_scan_gone "$phase" 0
    return 0
  fi
  _eo_scan_gone "$phase" 1

  # 不論這輪狀態是不是 unknown 都要呼叫：計數與解除靜音都在
  # eo_scan_unknown 內部一起處理，呼叫端不必自己另外判斷要不要歸零。
  eo_scan_unknown "$phase" "$status"

  if [ "$status" = "working" ]; then
    eo_scan_spinning "$phase" "$seq" "$changed_epoch"
  fi
}

# _eo_low_freq_scan_once（內部輔助函式）
# 低頻掃描的一輪：呼叫一次 phase-status.sh 查全部，逐行處理。
#
# ---- EO_PHASE_STATUS_SCRIPT：測試樁化 phase-status.sh 用 ----
# 跟 _eo_do_auto_push 對 send-to-phase.sh 的處理方式相同：這裡呼叫
# 的是「$SCRIPT_DIR/phase-status.sh」這個明確路徑，不是 PATH 解析的
# 裸指令名，herdr 那套樁化手法用不上。改用環境變數間接，預設值是真
# 正的路徑，測試可以換成一支假腳本（同樣不需要處理 herdr 的 JSON 回
# 應形狀，只要照 phase-status.sh 文件化的結束碼契約回傳即可）。
_eo_low_freq_scan_once() {
  local output rc stderr_file script
  local phase_kv status_kv seq_kv now

  stderr_file="$(mktemp)"
  # 函式層級的 RETURN trap：不論下面用哪一條路徑離開這個函式，暫存
  # 檔都會被清掉，不必在每個 return 之前各自補一行 rm。
  trap 'rm -f "$stderr_file"' RETURN

  # phase-status.sh 查全部模式的聚合結束碼可能是 0（全部成功）或 1
  # （掃完但至少一個 phase 失敗，見它自己的說明），兩者都要繼續處理
  # 已經拿到的那些行，不能讓聚合失敗擋掉其餘還在跑的 phase，因此這
  # 裡先關掉 -e 再呼叫，不用 if 包（if 包只測「要不要繼續」，這裡兩
  # 種結束碼都要繼續，沒有分支好測）。
  script="${EO_PHASE_STATUS_SCRIPT:-$SCRIPT_DIR/phase-status.sh}"
  set +e
  output="$(bash "$script" 2>"$stderr_file")"
  rc=$?
  set -e

  if [ "$rc" -gt 1 ]; then
    # rc 0／1 都代表「掃到了東西」；rc 大於 1 代表整次呼叫在還沒印
    # 出任何一行 phase 狀態之前就整個失敗了（例如 herdr 本身連不
    # 上），這一輪完全沒有東西可處理，跟「掃到零個 phase」是兩件不
    # 同的事——前者是 herdr 暫時不可用，三種低頻事件這一輪全部靜默
    # 停擺、下一輪 herdr 恢復後自己回來，若不留痕跡，中間完全看不出
    # 發生過什麼。
    printf 'event-generator.sh: 低頻掃描這一輪 phase-status.sh 整個失敗（結束碼 %s）：%s\n' \
      "$rc" "$(cat "$stderr_file")" >&2
  fi

  now="$(date +%s)"

  while IFS=' ' read -r phase_kv status_kv seq_kv; do
    [ -n "${phase_kv:-}" ] || continue
    local phase status seq changed_epoch
    phase="${phase_kv#phase=}"
    status="${status_kv#status=}"
    seq="${seq_kv#seq=}"

    # seq 是否變動的追蹤留在這裡（_eo_low_freq_scan_once 自己的行程
    # 本體），不在下面被隔離的子殼裡——見 _eo_track_spin_seq 開頭那
    # 段長註解：子殼寫進行程內關聯陣列的值離開子殼就消失。
    if [ "$status" = "working" ]; then
      _eo_track_spin_seq "$phase" "$status" "$seq"
      changed_epoch="${_EO_SPIN_EPOCH[$phase]}"
    else
      changed_epoch=0
    fi

    # 每個 phase 各自隔離失敗：手法跟 phase-status.sh 自己查全部模式
    # 隔離每個 phase 的失敗完全一樣（先 `set +e` 讓子殼本身的失敗不
    # 觸發本迴圈的 errexit，子殼一啟動立刻自己重新 `set -euo pipefail`
    # 讓子殼內部的 errexit 貨真價實開著）。理由相同：一個 phase 因為
    # 狀態檔缺欄位或其他原因在 _eo_low_freq_process_one 裡失敗，不能
    # 讓低頻掃描這整個常駐子行程一起死掉，那會讓所有 phase 的
    # SPINNING／GONE／UNCLASSIFIED 偵測一起失效。這裡只隔離
    # _eo_low_freq_process_one，不是整個 while 迴圈本體：上面的 seq
    # 追蹤必須留在不被隔離的這一層才寫得回去（見上）。
    set +e
    (set -euo pipefail; _eo_low_freq_process_one "$phase" "$status" "$seq" "$changed_epoch")
    set -e
  done <<<"$output"
}

# _eo_low_freq_scan_loop（內部輔助函式，以背景子行程執行）
_eo_low_freq_scan_loop() {
  while true; do
    _eo_low_freq_scan_once
    # EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 定義在 common.sh，未查證
    # 推估、首次真實跑 epic 為校準回合；同一個常數也是「低頻掃描每
    # 幾秒一輪」的權威值，不是只用在 UNCLASSIFIED 計數上。
    sleep "$EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS"
  done
}

# _eo_pidfile_path（內部輔助函式）
_eo_pidfile_path() {
  printf '%s/.tmp/epic-orchestration/event-generator.pid\n' "$(eo_main_repo)"
}

# _eo_acquire_singleton（內部輔助函式）
# 單例守衛：pidfile 記的是整個 process group 的 id，不是單一 pid
# ——main 呼叫這裡之前已經透過 _eo_ensure_own_process_group 保證自己
# 是該 group 的 leader，此時 `$$` 同時是自己的 pid 與 pgid。pidfile
# 存在且該 group 仍有任何存活成員就拒絕啟動第二個常駐產生器，以
# EO_SINGLETON_CONFLICT_EXIT_CODE（9）結束；group 已經沒有任何存活
# 成員才視為可以接手，蓋掉舊 pidfile。
#
# ---- 為什麼記錄整個 group、用「group 是否還有任何成員」判斷，不是
#      記錄單一 pid 再用 kill -0 那一個 pid（獨立審查修正輪次 3／5
#      找到的問題，這一版取代舊版）----
# 舊版記單一 pid，SIGKILL 收掉 main 之後，main 自己的 pid 確實死
# 了，但它的子行程（每個 phase 的邊緣迴圈）與孫行程（它們呼叫的
# herdr）全部繼續存活變成孤兒——已被獨立審查實測：SIGKILL 掉 main
# 後有 7 個孤兒存活，包含真正會寫 last_marker_seq 的那些行程。舊版
# `kill -0 <舊 pid>` 對已死的 main 自己那個 pid 當然不成立，於是新
# 產生器順利接手，跟孤兒同時存在、同時寫 last_marker_seq——這正是
# 「seq 只會變大」這個整條事件通道賴以判斷「標記是新是舊」的假設會
# 失效的那個情境，這道守衛存在的理由正是要擋下它，舊版卻沒有真的擋
# 下（這裡不重複舊版註解「這裡擋的正是這個情境」與「舊 pid 已死就視
# 為可以接手」前後矛盾的問題：舊版程式碼做的其實是後者，卻同時聲稱
# 做到前者）。現在用 `kill -0 -<pgid>`（對負的 pgid 送訊號 0，
# POSIX 定義為檢查該 process group 是否還有任何存活成員，不會真的
# 送出訊號）取代單一 pid 檢查：孤兒們雖然各自的直接父行程 main 已經
# 不在，但仍然留在同一個 group 裡（見 main 開頭
# _eo_ensure_own_process_group 與 _eo_cleanup 的說明：不開 job
# control，子行程與孫行程都留在同一個 group），因此只要有任何一個
# 孤兒還活著，這個檢查就會抓到，正確拒絕啟動第二個——已對
# `kill -0 -<pgid>` 的這個語意實測驗證過（對存在的 group 回傳 0、對
# 不存在的 group 回傳非 0）。這個修正同時推翻了任務七上一輪一項裁
# 定的前提：帶鎖的讀-改-寫更新函式之所以被判為延後，理由之一是「兩
# 個產生器同時存在由這道守衛擋掉」，但那個前提在舊版單一 pid 設計下
# 是假的；這一版修好守衛本身，而不是另外加鎖——加鎖只能擋住遺失更
# 新，擋不住「孤兒把序號推進之後新產生器把真正的新標記判成缺席」，
# 而後者才是致命的那一半，鎖解決不了語意層的雙寫者問題。
_eo_acquire_singleton() {
  local pidfile old_pgid
  pidfile="$(_eo_pidfile_path)"
  mkdir -p "$(dirname "$pidfile")"

  if [ -f "$pidfile" ]; then
    old_pgid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$old_pgid" ] && kill -0 -"$old_pgid" 2>/dev/null; then
      eo_die "$EO_SINGLETON_CONFLICT_EXIT_CODE" \
        "event-generator.sh: 偵測到既有的常駐產生器（含其子孫行程）仍有存活成員（process group $old_pgid，$pidfile），拒絕啟動第二個——兩個產生器同時寫 last_marker_seq 會讓『seq 只會變大』這個假設失效"
    fi
  fi

  printf '%s\n' "$$" > "$pidfile"
}

# _eo_ensure_own_process_group（內部輔助函式）
# 確保目前這個行程是自己 process group 的 leader（pgid 等於自己的
# pid）；不是的話用 `setsid --wait` 把自己整個重啟進一個獨立的新
# session（也就是新的 process group），重啟後的那個行程一定是新
# group 的 leader，再檢查一次時條件成立、直接往下執行，不會無窮遞
# 迴。main 必須在做任何其他事之前先呼叫這個函式。
#
# ---- 為什麼需要這個（Critical A，獨立審查修正輪次 3／5 找到的問
#      題）----
# 這支腳本設計上要掛在 Claude Code 的 Monitor 上跑，而它既不呼叫
# setsid、也不檢查自己是不是 group leader，是否安全完全取決於啟動
# 者恰好怎麼開它——不開 job control 時，main 與啟動它的那個行程共用
# 同一個 group 是預設行為，_eo_cleanup 對這個共用 group 廣播 TERM
# 就會連啟動者、以及同一個 group 裡任何無關的行程一起殺掉。獨立審查
# 實測過：generator、一支無關的 sleep、以及啟動腳本三者 pgid 都相
# 同，只對 generator 送一次 TERM，三者全部死亡；而 _eo_cleanup 掛在
# EXIT 上，任何離開路徑（含 errexit 死亡）都會觸發，不只 SIGTERM。
#
# ---- 為什麼用 `setsid --wait CMD`，不是 `exec setsid CMD` ----
# 直接 `exec setsid CMD` 有個副作用：setsid() 這個系統呼叫要求呼叫
# 者不能已經是自己 process group 的 leader，若呼叫端已經是（不常
# 見，但不能排除），setsid 這個外部工具必須先 fork 出一個子行程才能
# 成功呼叫 setsid()——而 fork 之後，父行程（也就是 exec 換上去、原
# 本 Monitor 在追蹤的那個 pid）預設會立刻結束，不等子行程。Monitor
# 若是靠「行程結束」判斷串流已經停止，就會在真正的常駐邏輯都還沒開
# 始跑的時候，誤判成串流已經結束。改用 `setsid --wait CMD`（不
# exec，讓目前這個 bash 繼續存在、以前景方式呼叫它）：不論 setsid
# 內部要不要 fork，`--wait` 都讓外層行程一直等到 CMD 真正結束才返
# 回、也才真正終止；CMD 的 stdout 是從外層行程繼承來的同一個檔案描
# 述符，不需要另外接管線，Monitor 追蹤的 pid 全程存活、也全程看得到
# CMD 的輸出，直到真正該結束的時候才結束。已用獨立重現腳本驗證：一
# 個會先印一行、睡數秒、再印一行的內層腳本，外層在 `setsid --wait`
# 返回前那整段期間都還在等待（藉由外層自己緊接著寫的下一行只在內層
# 完全跑完之後才出現來確認），兩行輸出都正確經由外層原本的 stdout
# 重導向被完整收下；也驗證過 `setsid CMD &`（不帶 --wait）確實會讓
# 實際執行內容的那個行程成為自己 pgid 等於 pid 的新 group leader。
_eo_ensure_own_process_group() {
  if [ "$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')" != "$$" ]; then
    setsid --wait bash "${BASH_SOURCE[0]}"
    exit $?
  fi
}

# _eo_cleanup（內部輔助函式，掛在 EXIT trap 上）
# 不論這個行程怎麼結束（正常、或被 _eo_signal_exit 呼叫 exit），都在
# 這裡做一次性的善後：移除 pidfile、把整個 process group 一次收掉。
#
# ---- 為什麼對整個 group 廣播是安全的 ----
# main 在呼叫這裡之前已經透過 _eo_ensure_own_process_group 保證自己
# 是一個獨立、新建 session 的 process group leader（見該函式的說
# 明），這個 group 裡只會有本行程自己與它之後起的子孫（每個 phase
# 的邊緣迴圈、低頻掃描，以及它們呼叫的 herdr）——不開 job control
# 時，子行程與孫行程預設就跟父行程共用同一個 group（已用獨立重現腳
# 本驗證：三層 `ps` 顯示 pgid 相同），因此對這個 group 送一次訊號就
# 能連孫行程一起收，不必逐一記錄、逐一收拾每個子行程的 pid。這與早
# 先版本「不開 set -m」的推理不同：早先版本以為「不開 job control 就
# 安全」，但那只保證子孫共用同一個 group，沒有保證那個 group 不會被
# 啟動者或其他無關行程共用——真正的安全性來自 main 主動把自己隔進一
# 個新 group，不是「不開 set -m」這件事本身。
#
# ---- 為什麼要先關掉自己的 trap，再對含自己在內的整個 group 送訊號 ----
# 已用獨立最小重現腳本驗證：若不先關掉 TERM／INT 的攔截，對包含本行
# 程自己在內的整個 process group 送 TERM，這個行程自己還開著的 trap
# 會把這個自己送出的訊號重新攔下、再次呼叫同一個 handler，變成無窮
# 迴圈（重現腳本裡 "cleanup fired" 訊息無限重複印出）。先
# `trap - TERM INT` 拿掉攔截，同一段 kill 之後三層行程（main、子行
# 程、孫行程）乾淨結束、訊息只印一次。
_eo_cleanup() {
  rm -f "$(_eo_pidfile_path)" 2>/dev/null || true

  local mypgid
  mypgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')"
  if [ -n "$mypgid" ]; then
    trap - TERM INT
    kill -TERM -"$mypgid" 2>/dev/null || true
  fi
}

# _eo_signal_exit（內部輔助函式，掛在 INT／TERM trap 上）
# 只負責確保這個行程真的結束：呼叫 exit 會自動觸發上面掛在 EXIT 的
# _eo_cleanup，實際清理工作留給它做，這裡不重複。
#
# ---- 為什麼一定要有這個 exit，不能只用 _eo_cleanup 當 INT／TERM 的
#      handler ----
# 早先版本把 EXIT、INT、TERM 三個訊號綁到同一個 handler，而那個
# handler 尾端沒有 exit。bash 收到訊號、trap 的 handler 執行完之
# 後，若 handler 本身沒有明確結束行程，執行會恢復到原本被打斷的地
# 方（例如恢復 sleep、恢復 main 的 while 迴圈）——SIGTERM 因此完全
# 停不掉這支常駐腳本，已用獨立最小重現腳本驗證：沒有這個 exit，逾時
# 送 TERM 後行程仍在跑；加上這個 exit 之後，行程與其背景子行程、孫
# 行程全部確實結束。獨立審查另外指出這個問題還有一個更嚴重的併發後
# 果：main 對低頻掃描沒有監督重啟（早先版本），SIGTERM 收到後
# _eo_cleanup 把子行程都殺了，但因為沒有 exit，main 的 while 迴圈會
# 恢復執行，下一輪又把 phase 迴圈重新起回來（main 有監督重啟這
# 段），變成「送了 TERM 卻停不下來、只是把低頻掃描永久殺死」的半盲
# 活屍——低頻掃描沒有監督重啟，一旦被這樣殺掉就再也不會回來。這一
# 版把低頻掃描也納入 main 的監督重啟（見下方 main），並修好這裡的
# exit，兩處要一起看才是完整的修法。
_eo_signal_exit() {
  exit 0
}

# _eo_phase_fingerprint <phase>（內部輔助函式）
# 印出這個 phase 目前狀態記錄的一份簡單指紋（座標三欄位加八個邊緣
# 觸發欄位，串成一個字串）。用在 _eo_phase_supervise 判斷「放棄重起
# 之後，狀態記錄是不是有變動」——包含座標欄位是刻意的：操作者若把這
# 個卡住的 phase 關掉、重新 start-phase 一次，tab_id／pane_id 會換
# 新，這正是「值得恢復監督」的訊號。任何一個欄位讀不到（缺漏）都當
# 空字串處理，不因此讓指紋計算本身失敗。
_eo_phase_fingerprint() {
  local phase="$1" field value out=""
  for field in tab_id pane_id agent_name last_marker_seq held_by_orchestrator \
    auto_push_count unknown_rounds spinning_muted gone_muted unclassified_muted \
    agent_gone; do
    if value="$(eo_state_get "$phase" "$field" 2>/dev/null)"; then
      :
    else
      value=""
    fi
    out="${out}${field}=${value};"
  done
  printf '%s' "$out"
}

# _eo_phase_supervise <phase>（內部輔助函式）
# main 主迴圈每輪對每個列在狀態檔裡的 phase 呼叫一次，決定要不要
# （重）啟動它的邊緣迴圈。依序：
#   1. 先前已經放棄重起（_EO_PHASE_GIVEUP_FINGERPRINT 非空，不論放
#      棄的原因是 agent_gone 還是連續重起超過門檻，見步驟 2 與步驟
#      4）：比對目前的狀態指紋，沒變就繼續放棄；變了才清掉放棄標
#      記、歸零重起計數、把 agent_gone 重設回 false，恢復正常監
#      督——這是本函式唯一的恢復入口，agent_gone 與 RESPAWN-LIMIT
#      兩種放棄共用同一套指紋比對。
#   2. agent_gone 已經是 true：邊緣迴圈自己確認過 agent_not_found，
#      這是自願結束、不是異常死亡，不重新起一條——否則會變成事件風
#      暴（見 _eo_phase_edge_loop 裡對應分支的說明；這裡刻意不是檢
#      查 gone_muted，理由見 _eo_scan_gone 的說明：那個欄位會被低頻
#      掃描的「重新出現」解除，若拿它當重啟閘門會在兩條通道判讀不
#      一致時形成永不停止的重複）。第一次偵測到就順便記錄放棄指
#      紋，供步驟 1 比對。
#   3. 子行程還活著（kill -0 成立）：健康，把連續重起計數歸零。
#   4. 子行程不在了，且先前有記錄過 PID（代表這不是第一次啟動，是
#      死掉之後要重起）：套用退避——連續重起次數每次加倍延遲下次允
#      許重起的時間，超過 EO_PHASE_RESPAWN_GIVEUP_THRESHOLD 次就放
#      棄，印一則 RESPAWN-LIMIT 事件交回 orchestrator、記錄當下的狀
#      態指紋，之後每輪都在步驟 1 被擋下，直到指紋改變。
#   5. 通過以上檢查（含第一次啟動，不受退避規則約束）：(重)啟動
#      _eo_phase_edge_loop。
#
# ---- 為什麼需要這一整套，不能只「不在了就重起」----
# 早先版本的「不在了就重起」在死亡原因是持續性的情況下會變成無窮迴
# 圈，而且後果分兩種、兩種都不好：死在印出事件之前的入口（例如
# _eo_agent_wait 內部的等待失敗、解析回應失敗被 errexit 帶走）重起
# 不會產生任何 stdout 事件，只有 stderr 噪音——監看端不會被自動停
# 掉，但 orchestrator 也永遠收不到這個 phase 的任何消息，那就是失明
# 本身，只是變吵了；死在印出事件之後的入口（內層把結束碼原樣回傳那
# 個分支）重起之後外層立刻再命中同一個停下，標記序號已經推進過，會
# 印出標記缺席那種事件，變成另一種風暴。退避＋放棄把「無聲每 5 秒一
# 次」換成「有界、可見、而且會升級」。
_eo_phase_supervise() {
  local p="$1"

  if [ -n "${_EO_PHASE_GIVEUP_FINGERPRINT[$p]:-}" ]; then
    local current_fp
    current_fp="$(_eo_phase_fingerprint "$p")"
    if [ "$current_fp" = "${_EO_PHASE_GIVEUP_FINGERPRINT[$p]}" ]; then
      return 0
    fi
    unset '_EO_PHASE_GIVEUP_FINGERPRINT[$p]'
    _EO_PHASE_RESPAWN_COUNT[$p]=0
    eo_state_set "$p" agent_gone false
  fi

  local agent_gone
  if agent_gone="$(eo_state_get "$p" agent_gone 2>/dev/null)" && [ "$agent_gone" = "true" ]; then
    _EO_PHASE_GIVEUP_FINGERPRINT[$p]="$(_eo_phase_fingerprint "$p")"
    return 0
  fi

  if [ -n "${_EO_PHASE_PIDS[$p]:-}" ] && kill -0 "${_EO_PHASE_PIDS[$p]}" 2>/dev/null; then
    _EO_PHASE_RESPAWN_COUNT[$p]=0
    return 0
  fi

  if [ -n "${_EO_PHASE_PIDS[$p]:-}" ]; then
    local now_epoch next_allowed
    now_epoch="$(date +%s)"
    next_allowed="${_EO_PHASE_NEXT_RESPAWN_EPOCH[$p]:-0}"
    if [ "$now_epoch" -lt "$next_allowed" ]; then
      return 0
    fi

    local respawn_count delay
    respawn_count=$(( ${_EO_PHASE_RESPAWN_COUNT[$p]:-0} + 1 ))
    _EO_PHASE_RESPAWN_COUNT[$p]=$respawn_count

    if [ "$respawn_count" -gt "$EO_PHASE_RESPAWN_GIVEUP_THRESHOLD" ]; then
      printf 'phase=%s RESPAWN-LIMIT count=%s\n' "$p" "$respawn_count"
      _EO_PHASE_GIVEUP_FINGERPRINT[$p]="$(_eo_phase_fingerprint "$p")"
      return 0
    fi

    delay=$(( EO_PHASE_POLL_SECONDS * (1 << (respawn_count - 1)) ))
    if [ "$delay" -gt "$EO_PHASE_RESPAWN_BACKOFF_MAX_SECONDS" ]; then
      delay="$EO_PHASE_RESPAWN_BACKOFF_MAX_SECONDS"
    fi
    _EO_PHASE_NEXT_RESPAWN_EPOCH[$p]="$(( now_epoch + delay ))"
  fi

  _eo_phase_edge_loop "$p" &
  _EO_PHASE_PIDS[$p]=$!
}

# _eo_forget_phase <phase>（內部輔助函式）
# 收掉一個已經不在狀態檔清單裡的 phase：若還記錄著存活的子行程 pid
# 就送 TERM 直接結束它，並把這個 phase 從全部行程內關聯陣列裡清乾
# 淨（Medium C，獨立審查修正輪次 3／5 找到的問題）。
#
# ---- 為什麼需要這個 ----
# phase 的記錄被 close-phase.sh 呼叫 eo_state_remove_phase 移除之
# 後，若不主動收掉，有兩個後果：(1) 那條邊緣迴圈會繼續跑到它自己下
# 一次 wait 返回為止（最長 EO_WAIT_TIMEOUT_MS，也就是最長兩分鐘），
# 之後才會因為讀不到狀態記錄而死掉，讀起來像故障，其實是成功收尾的
# 正常後果；(2) pid 陣列從不清除，若之後又有新的 phase 重新使用同一
# 個編號，main 會看到殘留的存活 pid 誤判成「已在監看」而不起新迴
# 圈，那筆重建的記錄就一直只有三個座標欄位。這裡主動 kill 掉還存活
# 的子行程、清空全部相關陣列，兩個後果都不會發生。
#
# ---- 為什麼直接 kill 這個子行程是安全的、不會意外觸發整個產生器的
#      清理邏輯 ----
# `_eo_phase_edge_loop "$p" &` 這個背景子行程是用 fork 產生的，會繼
# 承 main 當下已經註冊好的 trap 設定（含掛在 EXIT 上的 _eo_cleanup
# 與掛在 INT／TERM 上的 _eo_signal_exit），但已用獨立重現腳本驗證
# 過：對一個「只是繼承了 trap 設定、自己從未真的執行過對應訊號處理
# 邏輯」的背景子行程送預設訊號（TERM，無自訂 handler 主動攔截時的
# 預設處置是立即終止），它會直接終止，不會執行繼承來的 trap——重現
# 腳本裡子行程被 kill 之後，「EXIT-trap 已觸發」與「TERM-trap 已觸
# 發」兩則訊息都只在父行程自己自然結束時各印一次，從未在子行程的真
# 實 pid 下出現過。因此這裡對單一子行程送 kill，不會意外連鎖觸發整
# 支產生器的 process group 廣播清理。
_eo_forget_phase() {
  local p="$1"
  if [ -n "${_EO_PHASE_PIDS[$p]:-}" ]; then
    kill "${_EO_PHASE_PIDS[$p]}" 2>/dev/null || true
  fi
  unset '_EO_PHASE_PIDS[$p]' '_EO_PHASE_RESPAWN_COUNT[$p]' \
    '_EO_PHASE_NEXT_RESPAWN_EPOCH[$p]' '_EO_PHASE_GIVEUP_FINGERPRINT[$p]' \
    '_EO_SPIN_SEQ[$p]' '_EO_SPIN_EPOCH[$p]'
}

# main（無參數）
# 常駐主迴圈：先確保自己是獨立 process group 的 leader（見
# _eo_ensure_own_process_group），再取得單例守衛，起低頻掃描一次，
# 之後每 EO_PHASE_POLL_SECONDS 秒重讀狀態檔，並且：
#   - 若低頻掃描的子行程已經不在了（不論是異常死亡還是先前沒能起
#     來），重新起一條——跟 phase 迴圈用同一套「不在了就重起」邏
#     輯，早先版本只在 main 開頭起一次，一旦死掉就永久消失，SIGTERM
#     誤用的後果見 _eo_signal_exit 的說明。
#   - 對每個列在狀態檔裡的 phase 呼叫 _eo_phase_supervise，把「要不
#     要（重）啟動」的判斷交給它（含 agent_gone 跳過、退避、放棄門
#     檻，見該函式的說明）。
#   - 讀完這一輪的清單後，把已經不在清單內、但行程內還記錄著的
#     phase 交給 _eo_forget_phase 收掉（Medium C）。
main() {
  _eo_ensure_own_process_group
  _eo_acquire_singleton

  trap '_eo_cleanup' EXIT
  trap '_eo_signal_exit' INT TERM

  while true; do
    if [ -z "${_EO_LOW_FREQ_PID:-}" ] || ! kill -0 "$_EO_LOW_FREQ_PID" 2>/dev/null; then
      _eo_low_freq_scan_loop &
      _EO_LOW_FREQ_PID=$!
    fi

    local phases p

    # 狀態檔還不存在（generator 比第一個 start-phase 先起）時
    # eo_state_phases 會以 5 結束；這裡接住，視同「目前沒有任何
    # phase」，不是本迴圈的錯誤。
    if phases="$(eo_state_phases 2>/dev/null)"; then
      :
    else
      phases=""
    fi

    local -A current_phase_set
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      current_phase_set[$p]=1
      _eo_phase_supervise "$p"
    done <<<"$phases"

    for p in "${!_EO_PHASE_PIDS[@]}"; do
      if [ -z "${current_phase_set[$p]:-}" ]; then
        _eo_forget_phase "$p"
      fi
    done

    sleep "$EO_PHASE_POLL_SECONDS"
  done
}

# EO_GENERATOR_NO_MAIN：設定時只定義上面這些函式就返回，供測試
# source 進自己的行程單獨呼叫三個決策函式。不接受任何參數——帶了參
# 數視為呼叫端用錯，以 2 結束；這個檢查刻意放在 eo_require_herdr_env
# 之後、main 之前，跟其餘六支腳本「先查環境前提、再驗參數」的順序
# 一致。
if [ -z "${EO_GENERATOR_NO_MAIN:-}" ]; then
  eo_require_herdr_env
  if [ "$#" -gt 0 ]; then
    eo_die 2 "event-generator.sh: 不接受任何參數，收到：$*"
  fi
  main
fi
