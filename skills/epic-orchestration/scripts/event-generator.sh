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
# 每個 phase 一條迴圈，以子行程執行；每輪重讀狀態檔決定監看清單，派
# 工與收尾都不必重啟本腳本。Monitor 只吃單一指令，動態增減監看對象
# 沒有現成機制可借，本腳本得自己起停這些子行程（見 main／_eo_cleanup）。
#
# 每條邊緣迴圈分外層／內層兩段：
#   外層  等 idle／done／blocked 其中之一（逾時 EO_WAIT_TIMEOUT_MS）
#     agent_not_found → 印 GONE，結束這條迴圈
#     timeout         → 不印任何一行，重掛外層
#     其餘             → 抓標記行，交給 eo_classify_stop 分類
#   內層  印出事件（或自動推一把）之後，反覆等對方離開 working
#     timeout         → 重掛內層，絕不落回外層（見 _eo_phase_edge_loop
#                        內那段長註解——這是整支腳本最容易寫錯的地方）
#     working 已離開  → 回外層重掛
#     agent_not_found → 印 GONE，結束這條迴圈
#
# 低頻掃描每 EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 秒一輪 phase-status.sh，
# 只處理事件通道抓不到的三種、且全部邊緣觸發（印過就靜音，直到條件
# 反轉才解除）：
#   working 但 state_change_seq 久未變化  → SPINNING
#   phase 不在這輪查詢結果裡              → GONE（低頻掃描版，跟外層
#                                            wait 的 agent_not_found 各
#                                            自獨立觸發，互為備援）
#   狀態連續多輪都是 unknown              → UNCLASSIFIED
#
# ---- 測試方式：EO_GENERATOR_NO_MAIN ----
# 本檔是常駐迴圈，不能整支跑進測試。設定 EO_GENERATOR_NO_MAIN 時，本
# 檔只定義函式就返回，不進入 main；測試藉此把本檔直接 source 進自己
# 的行程，單獨呼叫 eo_classify_stop／eo_scan_spinning／eo_scan_unknown
# 三個決策函式並斷言其行為。函式名與參數順序是測試唯一的依據。

set -euo pipefail

# 開 job control（monitor mode）純粹是為了讓每個用 `&` 起的背景子行
# 程各自落在自己的 process group：_eo_cleanup 收到訊號要善後時，才能
# 用 `kill -- -<pid>` 連同該子行程自己再往下呼叫的 herdr 子行程一併
# 終止，不只是砍掉最上層那一層 bash。非互動 shell 預設不開 job
# control，這裡明講原因，避免之後有人看到 `set -m` 覺得多餘而拿掉。
set -m

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

# _eo_ensure_field <phase> <field> <json_default>（內部輔助函式）
# 欄位已存在就不動，不存在才補上預設值。
#
# 為什麼需要這個：constraints.md 的狀態檔 schema 列出
# last_marker_seq／held_by_orchestrator／auto_push_count／
# unknown_rounds／spinning_muted／gone_muted／unclassified_muted 七個
# 欄位，但目前六支操作腳本裡沒有任何一支在 phase 剛啟動時把它們寫進
# 狀態檔（start-phase.sh 只寫 tab_id／pane_id／agent_name）。
# eo_state_get 對不存在的欄位一律以 5 結束（見 common.sh），若不在
# 這裡自己補齊，事件產生器第一次替任何 phase 分類就會因為欄位缺漏
# 讓那條邊緣迴圈的子行程悄悄死掉——剛好重現這個專案要修的那種「監
# 控視野漏判」。
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
  if ! eo_state_get "$phase" "$field" >/dev/null 2>&1; then
    eo_state_set "$phase" "$field" "$default"
  fi
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
# <停下狀態> 是 idle／done／blocked 三者之一；<標記行> 是
# read-phase-pane.sh --marker-only 的輸出：要嘛是
# `[PHASE <n>] seq=<N> state=<STATE...>`，要嘛是抓不到標記行時的哨
# 兵字串 `marker=none`。
eo_classify_stop() {
  local phase="$1" stopped="$2" marker_line="$3"
  local pattern seq state_str last_seq held auto_count

  # 解析標記行。抓不到就直接視同 marker=none，不進 seq 比對——沒有
  # seq 可比，比較本身沒有意義。這個正規表示式同時涵蓋字面上的哨兵
  # 字串 `marker=none`：那個字串本來就不會匹配 `^\[PHASE ...`。
  pattern='^\[PHASE [0-9]+\] seq=([0-9]+) state=(.*)$'
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
# EO_SPINNING_SECONDS 就印一次 SPINNING，印過就靜音直到 seq 變動、
# elapsed 掉回門檻以下才解除。
#
# 第二個參數（目前 state_change_seq）本身不影響這裡的決策：真正決定
# 要不要印的只有第三個參數算出來的 elapsed。「seq 是否變動」這件事
# 由呼叫端（_eo_low_freq_process_one）自己用行程內的關聯陣列追蹤，
# 變動時才把 epoch 重設成當下時間再傳進來——第二個參數留在介面裡是
# 給呼叫端那一行程式碼自我說明用的，不是決策函式需要的輸入。
eo_scan_spinning() {
  local phase="$1" changed_epoch="$3"
  local now elapsed muted

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
# 邊緣觸發：狀態連續 EO_UNCLASSIFIED_ROUNDS 輪都是 unknown 才印一次
# UNCLASSIFIED，印過就靜音直到狀態變成別的才解除。呼叫端每輪都要
# 呼叫本函式（不論這輪狀態是不是 unknown），讓計數與解除靜音都在同
# 一個地方處理，呼叫端不必自己另外判斷「要不要歸零」。
eo_scan_unknown() {
  local phase="$1" status="$2"
  local rounds muted

  if [ "$status" = "unknown" ]; then
    rounds="$(eo_state_get "$phase" unknown_rounds)"
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
# 低頻掃描版的 GONE 邊緣觸發：訊號來自 phase-status.sh 查全部模式回
# 報這個 phase 那一行是 ERROR（多半是 pane 已經不在 snapshot 裡），
# 跟外層 wait 迴圈那條 agent_not_found 的 GONE 各自獨立觸發、互為備
# 援——外層迴圈只在「正在等待」的當下才觀測得到 agent_not_found，這
# 裡則是每 EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 秒主動查一次，兩者
# 誰先看到誰先印。
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
        printf 'phase=%s GONE\n' "$phase"
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
          # eo_classify_stop 已經確認 working-ok、未達自動推進上限、
          # 也沒被 orchestrator 持有——這裡才是真的送出下行的地方。
          # 對方目前是停下中（idle／done），用 send-to-phase.sh 的預
          # 設握手模式，不是 --no-handshake（那是給做事中的對象廣播
          # 用的）。送出失敗（agent_blocked、握手逾時）不當成本迴圈
          # 的錯誤：安靜略過，下一輪外層 wait 會再次看到同樣的停下狀
          # 態，重新走一次分類判斷。
          bash "$SCRIPT_DIR/send-to-phase.sh" "$phase" "$EO_AUTO_PUSH_TEXT" >/dev/null 2>&1 || true
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
              printf 'phase=%s GONE\n' "$phase"
              return 0
              ;;
            *)
              return "$inner_rc"
              ;;
          esac
        done
        ;;
      *)
        return "$rc"
        ;;
    esac
  done
}

# _eo_low_freq_process_one <phase= 開頭的欄位> <status= 開頭的欄位> <seq= 開頭的欄位> <now>（內部輔助函式）
# 處理 phase-status.sh 查全部模式輸出的一行。三個欄位參數刻意保留
# `phase=`／`status=`／`seq=` 前綴再由這裡自己剝掉，不是在呼叫端先
# 剝好——這樣呼叫端的 `IFS=' ' read` 不必假設欄位順序以外的任何格
# 式，剝前綴這件事集中在同一個地方做。
_eo_low_freq_process_one() {
  local phase_kv="$1" status_kv="$2" seq_kv="$3" now="$4"
  local phase status seq

  phase="${phase_kv#phase=}"
  status="${status_kv#status=}"
  seq="${seq_kv#seq=}"

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
    # seq 是否變動由這裡自己用行程內的關聯陣列追蹤：變動就把「上次
    # 變動的 epoch」重設成現在，沒變動就沿用舊的 epoch，這樣
    # eo_scan_spinning 才能算出「久未變化」是多久。這兩個陣列只存在
    # 本行程記憶體裡，隨事件產生器重啟而歸零——重啟後最多延遲一個
    # EO_SPINNING_SECONDS 視窗才會再次判定 SPINNING，可接受，門檻本
    # 身也還在等第一次真實跑 epic 校準。
    if [ "${_EO_SPIN_SEQ[$phase]:-}" != "$seq" ]; then
      _EO_SPIN_SEQ[$phase]="$seq"
      _EO_SPIN_EPOCH[$phase]="$now"
    fi
    eo_scan_spinning "$phase" "$seq" "${_EO_SPIN_EPOCH[$phase]}"
  fi
}

# _eo_low_freq_scan_once（內部輔助函式）
# 低頻掃描的一輪：呼叫一次 phase-status.sh 查全部，逐行隔離處理。
_eo_low_freq_scan_once() {
  local output now
  local phase_kv status_kv seq_kv

  # phase-status.sh 查全部模式的聚合結束碼可能是 0（全部成功）或 1
  # （掃完但至少一個 phase 失敗，見它自己的說明），兩者都要繼續處理
  # 已經拿到的那些行，不能讓聚合失敗擋掉其餘還在跑的 phase，因此這
  # 裡先關掉 -e 再呼叫，不用 if 包（if 包只測「要不要繼續」，這裡兩
  # 種結束碼都要繼續，沒有分支好測）。
  set +e
  output="$(bash "$SCRIPT_DIR/phase-status.sh" 2>/dev/null)"
  set -e

  now="$(date +%s)"

  while IFS=' ' read -r phase_kv status_kv seq_kv; do
    [ -n "${phase_kv:-}" ] || continue
    # 每個 phase 各自隔離失敗：手法跟 phase-status.sh 自己查全部模式
    # 隔離每個 phase 的失敗完全一樣（先 `set +e` 讓子殼本身的失敗不
    # 觸發本迴圈的 errexit，子殼一啟動立刻自己重新 `set -euo pipefail`
    # 讓子殼內部的 errexit 貨真價實開著）。理由相同：一個 phase 因為
    # 狀態檔缺欄位或其他原因在 _eo_low_freq_process_one 裡失敗，不能
    # 讓低頻掃描這整個常駐子行程一起死掉，那會讓所有 phase 的
    # SPINNING／GONE／UNCLASSIFIED 偵測一起失效。
    set +e
    (set -euo pipefail; _eo_low_freq_process_one "$phase_kv" "$status_kv" "$seq_kv" "$now")
    set -e
  done <<<"$output"
}

# _eo_low_freq_scan_loop（內部輔助函式，以背景子行程執行）
_eo_low_freq_scan_loop() {
  while true; do
    _eo_low_freq_scan_once
    sleep "$EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS"
  done
}

# _eo_cleanup（內部輔助函式，掛在 trap 上）
# 本行程結束（含收到 INT／TERM）時，把還在跑的子行程——每個 phase
# 的邊緣迴圈、低頻掃描——一併終止，不留孤兒行程繼續佔用 herdr wait。
# `kill -- -"$pid"` 打的是整個 process group（見檔頭 `set -m` 那段
# 說明），連該子行程自己再往下呼叫的 herdr 子行程也一起收掉；萬一那
# 個 pid 已經不是自己的 process group leader（例如某個極端時序下
# job control 沒趕上），退回對單一 pid 送 TERM。EXIT 與 INT／TERM 共
# 用同一個 handler，訊號路徑下 _eo_cleanup 可能被呼叫兩次（一次因為
# 訊號本身、一次因為訊號導致的正常結束又觸發 EXIT），但函式本身對
# 已經死掉的行程重複操作是無害的（kill／wait 對不存在的 pid 都只是
# 安靜失敗），不特地加旗標避免重入。
_eo_cleanup() {
  local pid
  for pid in "${_EO_PHASE_PIDS[@]:-}" "${_EO_LOW_FREQ_PID:-}"; do
    [ -n "$pid" ] || continue
    kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}

# main（無參數）
# 常駐主迴圈：起低頻掃描一次，之後每 EO_PHASE_POLL_SECONDS 秒重讀狀
# 態檔，替清單裡還沒有自己迴圈在跑的 phase 各起一條 _eo_phase_edge_loop。
# 派工後新出現的 phase 下一輪就會被接住；已經在跑的 phase 不會被重
# 複起第二條迴圈（用 kill -0 檢查對應的子行程是否還活著）。
main() {
  # HERDR_ENV 前提檢查在下方呼叫 main 之前（同一個 if 區塊裡）已經做
  # 過一次，這裡不重做——main 目前只有那唯一一個呼叫點。
  trap '_eo_cleanup' EXIT INT TERM

  _eo_low_freq_scan_loop &
  _EO_LOW_FREQ_PID=$!

  while true; do
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
