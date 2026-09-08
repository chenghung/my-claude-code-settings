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
# ---- 測試方式：EO_GENERATOR_NO_MAIN ----
# 本檔是常駐迴圈，不能整支跑進測試。設定 EO_GENERATOR_NO_MAIN 時，本
# 檔只定義函式就返回，不進入 main；測試藉此把本檔直接 source 進自己
# 的行程，單獨呼叫可測的函式並斷言其行為。凡是不需要 herdr 樁就測得
# 起來的串接層判斷（狀態檔欄位補齊、seq 追蹤的行程內記憶、
# EO_GENERATOR_DRY_RUN 開關），都必須有對應測試——這條規則本身是這
# 一輪修正的直接教訓：早先版本裡好幾個嚴重問題，正是因為決策函式各
# 自測起來都對、但串接它們的膠水程式碼從未被任何測試碰過。
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

# ---- 常駐迴圈用的行程內狀態（不落地狀態檔，隨本行程結束而消失）----
declare -A _EO_PHASE_PIDS    # phase -> 該 phase 邊緣迴圈子行程的 PID
_EO_LOW_FREQ_PID=""          # 低頻掃描子行程的 PID
declare -A _EO_SPIN_SEQ      # phase -> 低頻掃描上次觀測到的 state_change_seq
declare -A _EO_SPIN_EPOCH    # phase -> 上面那個 seq 第一次被觀測到的 epoch 秒

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
# 確保低頻掃描與邊緣迴圈依賴的七個欄位都存在。呼叫端（_eo_phase_edge_loop
# 起步時、_eo_low_freq_process_one 每次處理某個 phase 時）各自獨立呼
# 叫一次，成本是最多七次 `jq -e` 查詢，換來不必假設有任何人已經初始
# 化過這些欄位。
#
# 下面七個預設值已核對過與 constraints.md 狀態檔 schema 一致：三個
# 靜音欄位（spinning_muted／gone_muted／unclassified_muted）schema 裡
# 就是 false，直接採用；unknown_rounds schema 範例本來就是 0，直接
# 採用；last_marker_seq／auto_push_count 兩個計數欄位 schema 範例分
# 別是 17／3，但那是一個「已經跑過一陣子」的 phase 的示範值，不是初
# 始值——一個剛起步、還沒看過任何標記、還沒自動推過的 phase，這兩個
# 計數本來就該是 0，跟 schema 描述的欄位語意（累計次數）並不衝突；
# held_by_orchestrator schema 範例是 false，直接採用。
_eo_ensure_phase_defaults() {
  local phase="$1"
  _eo_ensure_field "$phase" last_marker_seq 0
  _eo_ensure_field "$phase" held_by_orchestrator false
  _eo_ensure_field "$phase" auto_push_count 0
  _eo_ensure_field "$phase" unknown_rounds 0
  _eo_ensure_field "$phase" spinning_muted false
  _eo_ensure_field "$phase" gone_muted false
  _eo_ensure_field "$phase" unclassified_muted false
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
# GONE 的邊緣觸發，兩條通道共用同一個 gone_muted 欄位：外層／內層邊
# 緣迴圈偵測到 agent_not_found 時呼叫（present=0），低頻掃描見到
# phase-status.sh 查全部模式回報這個 phase 是 ERROR 時也呼叫
# （present=0）——同一次消失不論哪條通道先看到，都只印一次；present=1
# 只會由低頻掃描呼叫，用來在 phase 重新出現於查詢結果時解除靜音（邊
# 緣迴圈本身沒有「重新出現」這個概念：一旦 agent_not_found，那條迴
# 圈就結束了）。
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
_eo_do_auto_push() {
  local phase="$1"
  if [ -n "${EO_GENERATOR_DRY_RUN:-}" ]; then
    printf 'phase=%s DRY-RUN-AUTO-PUSH\n' "$phase" >&2
    return 0
  fi
  bash "$SCRIPT_DIR/send-to-phase.sh" "$phase" "$EO_AUTO_PUSH_TEXT" >/dev/null 2>&1
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
        # 邊緣觸發、與低頻掃描共用同一個 gone_muted 欄位（見
        # _eo_scan_gone）：main 的監督邏輯會檢查這個欄位，已經印過
        # GONE 的 phase 不會被重新起一條迴圈，避免「子行程結束、5
        # 秒後重起、外層立刻再命中同一個 agent_not_found、再印一次
        # GONE」的事件風暴——獨立審查實測過一個已消失的 phase 在這
        # 個修法之前 79 秒印 16 則、換算每小時 720 則，是簡報自己定
        # 案的「致命值」120 則的 6 倍，而且只需要一個 phase。
        _eo_scan_gone "$phase" 0
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
          if _eo_do_auto_push "$phase"; then
            : # 自動推進成功，orchestrator 不必知道這次停下
          else
            # 自動推進送出失敗（agent_blocked、握手逾時等）：
            # eo_classify_stop 判定過這是 working-ok 且該自動推進，
            # 會走到這裡的必然是 state=working-ok，因此可以直接印出
            # 對應的 stopped 事件。不能靜默吞掉這個失敗——
            # eo_classify_stop 已經把 last_marker_seq 推進過，若這裡
            # 什麼都不印，這個 phase 會直接卡進下面的內層
            # wait -- until working 永遠等不到（沒有人真的送出東西
            # 讓它離開 done），下一輪外層 wait 就算重新命中同一個標
            # 記也只會判成 marker=none——沒有回退路徑，只能在這裡當
            # 下就把控制權交還給 orchestrator（獨立審查指出舊版註解
            # 宣稱「下一輪外層等待會再次看到同樣的停下狀態」，但程
            # 式碼並不提供那個回退路徑，是註解與行為不符）。
            printf 'phase=%s stopped=%s marker=working-ok\n' "$phase" "$stopped_status"
          fi
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
              _eo_scan_gone "$phase" 0
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
_eo_low_freq_scan_once() {
  local output rc stderr_file
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
  set +e
  output="$(bash "$SCRIPT_DIR/phase-status.sh" 2>"$stderr_file")"
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
# 單例守衛：pidfile 存在且其中記的 pid 還活著就拒絕啟動第二個常駐產
# 生器，以 EO_SINGLETON_CONFLICT_EXIT_CODE（9）結束。
#
# 為什麼需要這個：SIGKILL 沒辦法被攔截，即使 Critical 3 的訊號處理
# 修好了，操作者仍然可能直接 SIGKILL 掉一支卡住的產生器；被 SIGKILL
# 收掉的行程不會執行 EXIT trap，子行程與孫行程會變成孤兒繼續跑（見
# 任務報告 High 7）。孤兒不會因為自動推進那條路徑不印任何東西而收到
# SIGPIPE 死掉，會一直存活；這時如果重啟一支新的產生器，舊的孤兒與
# 新產生器會同時寫 last_marker_seq——「seq 只會變大」是整條事件通道
# 判斷「標記是新是舊」的唯一依據，兩個寫者同時存在就不成立了。這裡
# 擋的正是這個「同時有兩個產生器」的情境，不是 SIGKILL 本身（那個不
# 可能從腳本層擋下）。
#
# 舊 pid 已死（例如上一個產生器被 SIGKILL 收掉、pidfile 沒機會清
# 掉）就視為可以接手，蓋掉舊 pidfile——不會誤判成「永遠卡死、再也
# 起不來第二個」。
_eo_acquire_singleton() {
  local pidfile old_pid
  pidfile="$(_eo_pidfile_path)"
  mkdir -p "$(dirname "$pidfile")"

  if [ -f "$pidfile" ]; then
    old_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      eo_die "$EO_SINGLETON_CONFLICT_EXIT_CODE" \
        "event-generator.sh: 偵測到既有的常駐產生器仍在跑（pid $old_pid，$pidfile），拒絕啟動第二個——兩個產生器同時寫 last_marker_seq 會讓『seq 只會變大』這個假設失效"
    fi
  fi

  printf '%s\n' "$$" > "$pidfile"
}

# _eo_cleanup（內部輔助函式，掛在 EXIT trap 上）
# 不論這個行程怎麼結束（正常、或被 _eo_signal_exit 呼叫 exit），都在
# 這裡做一次性的善後：移除 pidfile、把整個 process group 一次收掉。
#
# ---- 為什麼不開 job control（不用 set -m）----
# 早先版本開了 `set -m`，讓每個用 `&` 起的背景子行程各自落在自己的
# process group，理由是想靠 `kill -- -<pid>` 連孫行程一起收。獨立審
# 查指出代價：對 main 送 SIGKILL（SIGTERM 修好之前，實務上要停掉卡
# 住的產生器就只能 SIGKILL，而 SIGKILL 繞過 EXIT trap，不可能靠腳本
# 層的清理邏輯攔下）時，每個背景子行程已經是自己 group 的
# leader，訊號到不了它們，四個 bash 加上牠們各自呼叫的 herdr 孫行程
# 全部存活變成孤兒。拿掉 `set -m` 之後，bash 沒開 job control 時的預
# 設行為是背景工作與父行程共用同一個 process group（已用獨立最小重
# 現腳本驗證：main、背景子行程、子行程呼叫的孫行程三層，`ps` 顯示三
# 者 pgid 相同），對整個 group 送一次訊號就能連孫行程一起收，不必逐
# 一記錄、逐一收拾每個子行程的 pid，兩種好處（連孫行程一起收、群組
# 訊號自然涵蓋子行程）因此可以同時擁有，不必二選一。
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

# main（無參數）
# 常駐主迴圈：先取得單例守衛，起低頻掃描一次，之後每
# EO_PHASE_POLL_SECONDS 秒重讀狀態檔，並且：
#   - 若低頻掃描的子行程已經不在了（不論是異常死亡還是先前沒能起
#     來），重新起一條——跟 phase 迴圈用同一套「不在了就重起」邏
#     輯，這是這一輪修正新增的部分：早先版本只在 main 開頭起一次，
#     一旦死掉就永久消失，SIGTERM 誤用的後果見上面 _eo_signal_exit
#     的說明。
#   - 對每個列在狀態檔裡的 phase，先看 gone_muted 是不是已經是
#     true——是的話代表這個 phase 已經自願印過 GONE 結束了它的邊緣
#     迴圈，不是異常死亡，不重新起一條，否則會變成事件風暴（見
#     _eo_phase_edge_loop 裡對應分支的說明）；不是 true 才照舊用
#     kill -0 檢查對應的子行程是否還活著、不在了才重起。
main() {
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

    while IFS= read -r p; do
      [ -n "$p" ] || continue

      local gone_muted
      if gone_muted="$(eo_state_get "$p" gone_muted 2>/dev/null)" && [ "$gone_muted" = "true" ]; then
        continue
      fi

      if [ -z "${_EO_PHASE_PIDS[$p]:-}" ] || ! kill -0 "${_EO_PHASE_PIDS[$p]}" 2>/dev/null; then
        _eo_phase_edge_loop "$p" &
        _EO_PHASE_PIDS[$p]=$!
      fi
    done <<<"$phases"

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
