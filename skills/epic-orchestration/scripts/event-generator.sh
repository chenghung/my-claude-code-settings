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
# _eo_cleanup）。
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
# eo_classify_stop 產生的事件行有四種：
#   phase=<編號> stopped=<idle|done|blocked> marker=<標記行或 none>
#   phase=<編號> AUTO-PUSH-LIMIT count=<次數>
#   phase=<編號> AGENT-RESTARTED seq=<畫面上的序號>（規格第十四節，
#     標記序號倒退代表 phase agent 中途重啟過，見 eo_classify_stop
#     裡那一段）
#   （不印任何一行）＝ 判定為自動推進，編排端完全看不到這次停下
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
# ---- 存活契約：這支腳本不重起自己，也不重起自己的子行程 ----
# 規格第七節「通道死掉不是靜默的」已經把重掛責任指派給編排端：
# Monitor 的串流結束會另外送一則通知（實測），orchestrator 收到就立
# 刻重掛一次並向使用者報一行；真正無聲的只剩「重掛也失敗」，那要據
# 實升級。既然那條偵測與重掛路徑已經存在，本腳本就不再自己實作第二
# 套——早先版本加過 setsid 自我重啟、process group 廣播、pidfile 單
# 例守衛、指數退避與放棄門檻，那疊機制正是把規格已指派給編排端的職
# 責又實作了一次，而三輪審查裡的每一個 Critical 都出自它、或出自為
# 了修它而加的下一層。看到這段不要以為是漏了該補：拿掉是刻意的。
#
# 落實成邊緣迴圈的結束碼契約：
#   0    自願結束——已印過 GONE，或這個 phase 已不在狀態檔（收尾）。
#        main 記住不再重起。
#   非 0 異常——main 印一行 stderr 診斷，並以同一個碼結束整支腳本，
#        讓串流結束、由編排端重掛。一個 phase 的壞記錄因此會停掉全
#        部監看，這是刻意的取捨：換成「一次、可見、走既有通道」，
#        取代早先「無聲每 5 秒重試一次、永無上界」。
# 低頻掃描那條子行程套同一規則，只是它不該有自願結束，任何結束都算
# 異常。
#
# 唯一的恢復入口：已自願結束（印過 GONE）的 phase，若之後讀到的
# pane 識別碼與當時不同，代表它換了新 pane 復活，重新起一條迴圈。沒
# 有這一步，一個印過 GONE 的 phase 就再也不會被重新監看。這個判斷只
# 讀 pane 識別碼、只存在行程記憶、不寫狀態檔、不與任何靜音欄位耦
# 合——早先版本把重起閘門與報告靜音放在同一個會被低頻掃描改寫的欄
# 位上，造成永不停止的重複，那個形狀在這裡結構上不可能重現。
#
# ---- 測試方式：EO_GENERATOR_NO_MAIN ----
# 本檔是常駐迴圈，但「不能整支跑進測試」只對「在測試行程自己裡面跑」
# 成立：測試可以、而且必須把整支起成獨立的背景行程來驗證常駐行為（見
# 測試檔的端對端段落）。這個任務最大的教訓正是這件事——早先為訊號處
# 理補的回歸測試不跑 main，而是另外寫一支「結構相同」的腳本並先手動
# setsid，把真正的病灶整段跳過，所以它必然通過而生產路徑照樣壞掉。凡
# 是驗證串接層的測試，都要執行生產程式碼那一份。
#
# 設定 EO_GENERATOR_NO_MAIN 時，本檔只定義函式就返回，不進入 main；
# 測試藉此把本檔直接 source 進自己的行程，單獨呼叫可測的函式並斷言其
# 行為。凡是不需要 herdr 樁就測得起來的串接層判斷（狀態檔欄位補齊、
# seq 追蹤的行程內記憶、EO_GENERATOR_DRY_RUN 開關、行程內追蹤的清
# 理、親子確認），都必須有對應測試——這條規則本身是修正過程的直接教
# 訓：早先版本裡好幾個嚴重問題，正是因為決策函式各自測起來都對、但
# 串接它們的膠水程式碼從未被任何測試碰過。這條規則同樣適用於呼叫本
# 專案自己另一支姊妹腳本（send-to-phase.sh、phase-status.sh、
# read-phase-pane.sh）的路徑：那些不是外部二進位，樁化的難度跟樁化
# herdr 完全不同量級，不能以「這條路徑要呼叫別的腳本」為理由跟「需要
# herdr 樁」混為一談而免測——見 EO_SEND_TO_PHASE_SCRIPT／
# EO_PHASE_STATUS_SCRIPT／EO_READ_PHASE_PANE_SCRIPT 三個環境變數。
#
# ---- EO_GENERATOR_DRY_RUN：把「測不了」變成「測得了」----
# 這支腳本唯一會主動對真實 agent 送下行的動作，是自動推進時呼叫
# send-to-phase.sh（見 _eo_do_auto_push）。設定 EO_GENERATOR_DRY_RUN
# 時完全不呼叫 send-to-phase.sh，改在 stderr 印一行可辨識的觀察行；
# 這不只是安全考量（測試與人工排錯都不該真的碰真實 agent），也讓這
# 段原本零測試覆蓋的迴圈層變得可以在完全不需要 herdr 樁的情況下驗證
# ——見上方「測試方式」那條規則。
#
# ---- 刻意不做單例守衛，以及它留下的窗口 ----
# 兩個產生器同時寫 last_marker_seq 會讓「seq 只會變大」這個判讀假設
# 失效，但本檔刻意不設 pidfile 單例守衛。守衛的代價是把操作者鎖在門
# 外——pidfile 指著一個還有存活成員的群組時，新產生器一律被拒，操作
# 者必須自己找出並收掉孤兒才能恢復。改成在源頭讓雙寫者無法長期存
# 在：main 被 SIGKILL（繞過所有 trap）時，每條邊緣迴圈在自己下一次
# 外層迭代開頭會發現 main 已經不在而自行結束（見
# _eo_phase_edge_loop 裡的親代存活檢查）。
#
# 殘餘暴露面，講明白不藏：最長一個 wait 週期（EO_WAIT_TIMEOUT_MS，
# 120 秒）的窗口內，尚未發現 main 已死的孤兒子行程與新起的產生器可
# 能同時寫標記序號。後果是新產生器把一個真正的新標記判成序號不夠
# 大、印出 marker=none、白派一次調查者。那是刻意選的安全失敗方向，
# 而且看得見——不是無聲漏判，也不需要操作者去收拾行程。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 重複 source 的風險：common.sh 用 readonly 定義門檻常數 ----
# 測試的做法是把本檔直接 source 進「已經 source 過 common.sh」的那個
# 測試行程（見檔頭「測試方式」），不是像其餘七支腳本那樣用 `bash
# foo.sh` 開新子行程執行。若這裡跟其餘七支腳本一樣無條件
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
# 逐字照抄或加校準註記。也正因為它不是門檻，這裡刻意讓它可以被環境
# 變數覆寫：端對端測試要跑真實的 main（不是另外寫一支結構相同的腳
# 本——見檔頭「測試方式」），把輪詢調快才能在幾秒內驗證「移除的
# phase 會被收掉」這類跨輪行為。這個覆寫只適用於本值；
# EO_WAIT_TIMEOUT_MS 與 common.sh 那三個待校準門檻一律不得為了測試
# 而壓縮。
readonly EO_PHASE_POLL_SECONDS="${EO_PHASE_POLL_SECONDS:-5}"
# 這個值直接進 sleep，而它的來源是環境變數，跟狀態檔的數值欄位一樣不
# 可信：外界殘留的匯出值會靜靜改掉生產節奏，而 0 會讓主輪詢變成不睡
# 的忙迴圈。所以比照 _eo_require_int 對狀態檔欄位的處理先驗證是純數
# 字，再要求至少 1 秒。這裡不能呼叫 _eo_require_int——它定義在下面，
# 而這段在載入期就要跑。
case "$EO_PHASE_POLL_SECONDS" in
  ''|*[!0-9]*)
    eo_die 2 "event-generator.sh: EO_PHASE_POLL_SECONDS 必須是純數字秒數，收到：$EO_PHASE_POLL_SECONDS"
    ;;
esac
if [ "$EO_PHASE_POLL_SECONDS" -lt 1 ]; then
  eo_die 2 "event-generator.sh: EO_PHASE_POLL_SECONDS 至少要 1 秒（0 會讓主輪詢變成忙迴圈），收到：$EO_PHASE_POLL_SECONDS"
fi

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
declare -A _EO_PHASE_DONE    # phase -> 非空代表那條迴圈已自願結束，不再重起
declare -A _EO_PHASE_DONE_PANE  # phase -> 自願結束當下的 pane 識別碼（唯一的恢復入口，見檔頭）
_EO_LOW_FREQ_PID=""          # 低頻掃描子行程的 PID
declare -A _EO_SPIN_SEQ      # phase -> 低頻掃描上次觀測到的 state_change_seq
declare -A _EO_SPIN_EPOCH    # phase -> 上面那個 seq 第一次被觀測到的 epoch 秒

# main 自己的 pid，在 main 開頭設定，之後 fork 出去的每條子行程都會
# 繼承這份值。子行程用它判斷「產生器本體是否還在」（見
# _eo_phase_edge_loop 的親代存活檢查），main 自己用它確認一個記錄下
# 來的 pid 是否仍是自己的子行程（見 _eo_kill_own_child）。
_EO_MAIN_PID=""

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
# 這七個就是全部——constraints.md schema 列的就是這七個，本檔不再自
# 己多加第八個欄位。早先版本加過一個 agent_gone 當「這條迴圈該不該
# 被重起」的閘門，那是為了配合已經拿掉的監督重起層而存在的；現在
# 「不重起」由 main 的行程內記憶處理（見檔頭的存活契約），不需要落
# 地到狀態檔。
#
# ---- 呼叫端必須先確認記錄存在 ----
# 本函式只補欄位，不判斷這筆記錄該不該存在：eo_state_set 對不存在的
# phase 會以 `.phases[$p] //= {}` 建出新記錄，因此對一個已經被收尾移
# 除的 phase 呼叫本函式，會生出一筆「八個非座標欄位、零個座標欄位」
# 的殘骸記錄，而且它會出現在 eo_state_phases 的結果裡，讓 main 下一
# 輪又把它當成待監看的 phase。獨立審查對真實 jq 重現過。所以每個呼
# 叫點都必須先過 _eo_phase_record_exists（見 _eo_phase_edge_loop 與
# _eo_low_freq_process_one）。
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

# _eo_phase_record_exists <phase>（內部輔助函式）
# 這個 phase 在狀態檔裡還有記錄嗎？以座標欄位 tab_id 為準：它由
# start-phase.sh 在建立記錄時就寫入，收尾時整筆記錄被
# eo_state_remove_phase 移除，因此它的存在等同「這筆記錄還在」。刻意
# 不用非座標欄位判斷——那些是讀取端補上的，補了反而會讓一筆殘骸記錄
# 看起來像還在。
#
# eo_state_get 讀不到就 eo_die，也就是真正的 exit，所以這裡把它包進
# `( )` 子殼：exit 只終止子殼，函式拿到的是子殼的結束碼。理由與
# _eo_ensure_field 上方那一大段完全相同，不重複。
_eo_phase_record_exists() {
  ( eo_state_get "$1" tab_id ) >/dev/null 2>&1
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

  # ---- 序號變小＝phase agent 中途重啟過（規格第十四節，中斷恢復）----
  # 「沒有變大」有兩種，規格第十四節明文要求分開處理，不能合成一條
  # `-le` 比較：
  #   相等（或只是沒變大）→ 上一回合的標記還留在畫面上，等同標記缺
  #                          席，見下面那個分支。
  #   比記住的值小        → 標記序號每回合遞增，不可能自己倒退，所以
  #                          這代表這個 phase agent 中途重啟過、計數
  #                          從頭開始。
  # 不分開的後果規格也寫明了，而且是永久性的：基準不重設，之後每一
  # 次比對都會落在「沒有變大」，這個 phase 從此每次停下都被判成標記
  # 缺席，每一次都讓編排端白派一次調查者。而 phase agent 重啟不是罕
  # 見情形——規格第十四節整節存在就是因為它會發生。
  #
  # 規則照規格：以當下這個值重設基準，並印一則事件交回編排端，讓它
  # 派一次調查者查明重啟原因。重設之後這一輪就結束，不把這則標記當
  # 成新標記往下分類——基準有沒有真的生效，看的是下一輪：下一則真正
  # 遞增的標記會被正確判成新的。
  #
  # auto_push_count 刻意不動：本函式只有「交回編排端並產生事件行」那
  # 條最終路徑會歸零它，其餘提早返回的路徑（含標記缺席）都不碰，這
  # 裡比照那些提早返回的路徑。重啟之後沿用既有的累計次數也是保守的
  # 方向——這個 phase 已經消耗掉的自動推進次數不因為它重啟就一筆勾
  # 銷。
  if [ "$seq" -lt "$last_seq" ]; then
    eo_state_set "$phase" last_marker_seq "$seq"
    printf 'phase=%s AGENT-RESTARTED seq=%s\n' "$phase" "$seq"
    return 0
  fi

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
# GONE 事件的邊緣觸發，而且是純粹的「要不要印這一行」報告用靜音——
# 這個欄位不決定任何行程要不要被起停。兩條通道共用同一個 gone_muted
# 欄位：外層／內層邊緣迴圈偵測到 agent_not_found 時呼叫（present=0），
# 低頻掃描見到 phase-status.sh 查全部模式回報這個 phase 是 ERROR 時
# 也呼叫（present=0）——同一次消失不論哪條通道先看到，都只印一次；
# present=1 只會由低頻掃描呼叫，用來在 phase 重新出現於查詢結果時解
# 除這個報告用的靜音。
#
# ---- 為什麼「報告靜音」不能同時當「要不要重起迴圈」的閘門 ----
# 兩條通道認的是不同識別碼：邊緣迴圈等的是 eo_agent_name 推導出來的
# agent 名稱，低頻掃描比對的是狀態檔的 pane 識別碼是否還在 snapshot
# 裡。pane 還在、但那個 agent 名稱已經不再註冊時，低頻掃描的
# present=1 會把這個欄位解回 false；早先版本把同一個欄位也當成「main
# 該不該重起這條迴圈」的閘門，於是閘門被打開、重起、立刻又撞上
# agent_not_found、再印一次 GONE，兩個判讀只要持續不一致就永遠不會
# 停（獨立審查實測：45 秒印 4 則，換算四個 phase 併行約每小時 220
# 則，超過致命值 120）。後來拆成兩個欄位仍然沒有解決，因為新欄位還
# 留在重起判斷的輸入裡。現在的做法是根本沒有重起這件事：邊緣迴圈印
# 完 GONE 就以 0 結束，main 記在行程內、永不重起（見檔頭的存活契
# 約）。低頻掃描要怎麼改寫這個欄位都無所謂，它打不開任何東西——這
# 才是那個無界重複在結構上不可能重現的原因。
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
#
# 結束碼就是檔頭那份存活契約：0 代表自願結束（印過 GONE，或這個
# phase 已不在狀態檔），main 據此記住不再重起；任何非 0 都是異常，
# main 會印一行診斷並結束整支腳本、讓編排端重掛。
_eo_phase_edge_loop() {
  # 進入時重下安全選項：這條迴圈是以背景子行程執行的，而子行程繼承的
  # 選項狀態取決於 main fork 它的當下——main 那一側刻意用 set +e 包住
  # 呼叫（理由見 main 裡那段長註解：唯一修得掉「if 條件豁免會終生傳染
  # 給子行程」的組合，就是「fork 在 set +e 下」加「子行程重下」兩者一
  # 起做）。這一行是那個組合的後半，單獨存在沒有用，也不能省。
  set -euo pipefail

  local phase="$1"
  local agent

  # 先確認記錄存在，才補預設值——順序不能反。反過來的話，對一個已
  # 被收尾移除的 phase 呼叫本函式（main 讀到清單與這裡真正執行之間
  # 有時間差，close-phase.sh 可能剛好在這個空隙裡移除記錄）會由
  # _eo_ensure_phase_defaults 生出一筆沒有任何座標欄位的殘骸記錄，
  # 而那筆記錄會出現在 eo_state_phases 裡、讓 main 下一輪又把它當成
  # 待監看的 phase，永久留在狀態檔。理由詳見
  # _eo_ensure_phase_defaults 上方「呼叫端必須先確認記錄存在」。
  _eo_phase_record_exists "$phase" || return 0
  agent="$(eo_agent_name "$phase")"
  _eo_ensure_phase_defaults "$phase"

  while true; do
    local wait_result rc

    # 每次外層迴圈重新開始前，先確認這個 phase 還在狀態檔裡——它可
    # 能在等待期間被收尾移除（close-phase.sh 呼叫
    # eo_state_remove_phase）。找不到就以 0 安靜結束這條迴圈，不印任
    # 何驚動人的訊息：這是成功收尾的正常後果，不是故障。main 下一輪
    # 也會呼叫 _eo_forget_phase 收掉這條迴圈，這裡只是讓它不必等到下
    # 一次 wait 返回才發現（最長兩分鐘），也不會在半路因為
    # eo_classify_stop 內部某個 eo_state_get 讀不到欄位而印出看起來
    # 像 bug 的內部錯誤訊息。
    _eo_phase_record_exists "$phase" || return 0

    # 親代存活檢查：產生器本體（main）若被 SIGKILL 收掉，所有 trap
    # 都繞過了，這條子行程會變成孤兒被 reparent、繼續寫狀態檔、繼續
    # 對真實 agent 自動推進。本檔刻意不設 pidfile 單例守衛（理由見檔
    # 頭），代價由這一行承擔：main 不在了就自行結束，孤兒最長只活到
    # 自己這一次 wait 返回為止，而不是永久。用 kill -0 而不是查
    # /proc 或 ps：不需要外部工具，也不需要知道自己被 reparent 到
    # 誰。已知限制是 pid 若被回收再指派給別的行程，這個檢查會誤判成
    # 「main 還在」，那只是讓孤兒多活一個 wait 週期，方向是安全的。
    if [ -n "${_EO_MAIN_PID:-}" ] && ! kill -0 "$_EO_MAIN_PID" 2>/dev/null; then
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
        # 位，見 _eo_scan_gone），然後以 0 結束這條迴圈：這是自願結
        # 束，main 會記住不再重起（見檔頭的存活契約）。這裡不再往狀
        # 態檔寫任何「不要重起我」的旗標——那個旗標一度存在，是為了
        # 配合已經拿掉的監督重起層；把它留在狀態檔裡，低頻掃描與邊
        # 緣迴圈對「這個 phase 還在不在」的兩種判讀就又有機會互相打
        # 架，而那正是無界重複的來源。
        #
        # 印之前要再確認一次記錄還在：正常收尾（close-phase.sh 關掉
        # tab 之後移除記錄）會同時造成「agent 找不到」與「記錄不
        # 在」，而 _eo_scan_gone 會 eo_state_set 寫 gone_muted，對一
        # 筆已經不存在的記錄寫下去就是生出一筆只有 gone_muted、零個座
        # 標欄位的殘骸——它會出現在列舉結果裡，所以 main 每輪都當它是
        # 清單內的 phase、清理永遠不會為它執行；而它沒有 pane 識別
        # 碼，所以恢復入口的比對永遠相等、永久不被監看。已在完全正常
        # 的收尾路徑上重現過。記錄不在就直接以 0 結束，連 GONE 都不必
        # 印：那不是消失，那是收尾。
        _eo_phase_record_exists "$phase" || return 0
        _eo_scan_gone "$phase" 0
        return 0
        ;;
      0)
        local stopped_status marker event classify_rc
        stopped_status="$(printf '%s' "$wait_result" | jq -r '.result.agent.agent_status')"

        # read-phase-pane.sh 失敗時一律視同 marker=none：失敗方向是
        # 安全的（頂多多派一次 investigator），真正的 GONE 由上面的
        # agent_not_found 與低頻掃描各自獨立偵測，不必在這裡重做一次
        # 判斷。
        #
        # EO_READ_PHASE_PANE_SCRIPT 與 EO_SEND_TO_PHASE_SCRIPT／
        # EO_PHASE_STATUS_SCRIPT 同一個用途、同一個理由（見
        # _eo_do_auto_push 上方那段）：這裡呼叫的是明確路徑而不是 PATH
        # 解析的裸指令名，樁化 herdr 那套手法用不上，所以留一個環境變
        # 數讓測試換成假腳本。這條路徑特別需要它：read-phase-pane.sh
        # 自己還會做 workspace 守衛（要 HERDR_WORKSPACE_ID 與一次
        # herdr tab list），若不換掉，任何想驗證「拿到標記行之後怎麼
        # 分類」的測試都會先卡在守衛上、拿到 marker=none，測到的是另
        # 一條分支。
        local read_pane_script="${EO_READ_PHASE_PANE_SCRIPT:-$SCRIPT_DIR/read-phase-pane.sh}"
        if marker="$(bash "$read_pane_script" "$phase" --marker-only 2>/dev/null)"; then
          :
        else
          marker="marker=none"
        fi

        # ---- 「分類失敗」與「判定為自動推進」必須分得開 ----
        # eo_classify_stop 用「印出空字串」表示判定為自動推進，而它失
        # 敗時 stdout 也是空的，兩者只差在結束碼。舊版寫成裸賦值
        # `event="$(...)"` 再判 `[ -z "$event" ]`，等於把這兩件事混成
        # 同一個分支，而且完全依賴 errexit 去攔下失敗——那個依賴不成
        # 立。已對真實 bash 量測：函式被包在命令替換裡呼叫時，它內部
        # 「賦值＋命令替換」的失敗不會中止它（同一個函式裸呼叫時會，
        # 命令替換內的單純指令失敗也會），所以 eo_classify_stop 會一
        # 路跑到真正 exit 的那一行才停。因此這裡改成顯式檢查結束碼，
        # 不假設 errexit 會替我們攔下任何東西。本檔每一個決策函式的呼
        # 叫點都套用同一個寫法。
        if event="$(eo_classify_stop "$phase" "$stopped_status" "$marker")"; then
          classify_rc=0
        else
          classify_rc=$?
        fi

        if [ "$classify_rc" -ne 0 ]; then
          # 分類失敗最常見的原因就是這個 phase 在本次迭代中途被收尾
          # 移除（eo_classify_stop 讀 last_marker_seq 時記錄已經不
          # 在），那是正常收尾、不是故障，以 0 安靜結束即可；記錄還
          # 在卻分類失敗才是真的異常（例如狀態檔數值欄位被寫壞），
          # 交給檔頭的存活契約處理：印一行診斷、以非 0 結束，讓 main
          # 結束整支腳本、由編排端重掛。無論哪一種都不會走到自動推
          # 進——絕不能對一個分類失敗的 phase 送下行。
          if ! _eo_phase_record_exists "$phase"; then
            return 0
          fi
          printf 'event-generator.sh: phase %s 的停下分類以結束碼 %s 失敗，狀態記錄仍存在，視為異常\n' \
            "$phase" "$classify_rc" >&2
          return "$classify_rc"
        fi

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
              # 同上方外層那個分支：先確認記錄還在（否則
              # _eo_scan_gone 的寫入會生出殘骸記錄，完整理由見那
              # 裡），再印一次 GONE、以 0 自願結束。
              _eo_phase_record_exists "$phase" || return 0
              _eo_scan_gone "$phase" 0
              return 0
              ;;
            *)
              # 未預期的結束碼：不是逾時、不是離開 working、不是
              # agent_not_found。依存活契約以非 0 結束，讓 main 結束
              # 整支腳本、由編排端重掛一次。這裡記一行到 stderr 是為
              # 了讓「為什麼整支結束了」在排錯時看得見。
              printf 'event-generator.sh: phase %s 的內層等待收到未預期結束碼 %s，視為異常\n' \
                "$phase" "$inner_rc" >&2
              return "$inner_rc"
              ;;
          esac
        done
        ;;
      *)
        # 同內層那個分支：異常，交給存活契約。
        printf 'event-generator.sh: phase %s 的外層等待收到未預期結束碼 %s，視為異常\n' \
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

  # 先確認記錄存在再補預設值，順序不能反：phase-status.sh 印出這一行
  # 到這裡真正處理它之間有時間差，記錄可能已經被收尾移除，而
  # _eo_ensure_phase_defaults 對不存在的 phase 會生出一筆殘骸記錄
  # （理由見它上方的說明）。這條路徑與 _eo_phase_edge_loop 起步那條
  # 是同一個缺陷的兩個入口，要一起修。
  _eo_phase_record_exists "$phase" || return 0

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

  # 這一輪查詢結果裡出現過的 phase，供函式尾端決定要忘掉哪些 seq 追
  # 蹤。宣告在函式層級（每次呼叫都是一個新的區域變數實例，所以每輪本
  # 來就是空的），不是在下面的 while 迴圈裡——理由與 main 那個
  # current_phase_set 完全相同：bash 對已存在的關聯陣列再宣告一次不會
  # 重置它。
  local -A seen_this_round

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
    local process_rc=$?
    set -e

    # 隔離子殼失敗時記一行：隔離讓這一輪繼續處理其餘 phase 是對的，
    # 但 `set +e` 會把失敗整個吞掉，那個 phase 就每 60 秒無聲地從三
    # 種低頻事件裡掉出去一次，沒有任何痕跡。低頻掃描這三個決策函式
    # （_eo_scan_gone／eo_scan_unknown／eo_scan_spinning）都是裸呼
    # 叫，失敗會被子殼自己的 errexit 攔下並反映在這個結束碼上——這
    # 是「每個決策函式的呼叫點都要顯式處理失敗」在這條路徑上的落
    # 點，與 _eo_phase_edge_loop 裡對 eo_classify_stop 的顯式檢查是
    # 同一條規則。這裡刻意只記錄、不升級成整支結束：低頻掃描是輔助
    # 通道，單一 phase 的狀態欄位壞掉不該停掉所有 phase 的事件推送。
    if [ "$process_rc" -ne 0 ]; then
      printf 'event-generator.sh: 低頻掃描處理 phase %s 時以結束碼 %s 失敗，這一輪跳過它（其餘 phase 不受影響）\n' \
        "$phase" "$process_rc" >&2
    fi

    seen_this_round[$phase]=1
  done <<<"$output"

  # ---- 這一輪沒出現的 phase，把它的 seq 追蹤忘掉 ----
  # 這兩個關聯陣列只有本行程（低頻掃描子行程）寫得到，所以也只有本行
  # 程忘得掉：main 的 _eo_forget_phase 跑在另一個行程、另一份記憶體，
  # 在那裡 unset 這兩個 key 是恆為無操作的（早先版本就是那樣寫的，測
  # 試之所以看起來通過，是因為測試在自己的行程裡先給這兩個陣列賦過
  # 值，斷言的是一條生產上不可能發生的路徑）。不忘掉的後果是同一個
  # phase 編號日後被重用時沿用舊的變動時間戳，讓經過時間一開始就超過
  # SPINNING 門檻、提前印出事件；順帶也讓這兩個陣列在長時間執行下只
  # 增不減。
  local tracked
  for tracked in "${!_EO_SPIN_SEQ[@]}"; do
    if [ -z "${seen_this_round[$tracked]:-}" ]; then
      unset '_EO_SPIN_SEQ[$tracked]' '_EO_SPIN_EPOCH[$tracked]'
    fi
  done
}

# _eo_low_freq_scan_loop（內部輔助函式，以背景子行程執行）
_eo_low_freq_scan_loop() {
  # 理由同 _eo_phase_edge_loop 開頭：背景迴圈自己重下安全選項，讓這條
  # 迴圈的 errexit 保證是本地的，不取決於 main fork 它的當下處在什麼
  # 上下文。
  set -euo pipefail

  while true; do
    _eo_low_freq_scan_once
    # EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 定義在 common.sh，未查證
    # 推估、首次真實跑 epic 為校準回合；同一個常數也是「低頻掃描每
    # 幾秒一輪」的權威值，不是只用在 UNCLASSIFIED 計數上。
    sleep "$EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS"
  done
}

# _eo_kill_own_child <pid>（內部輔助函式）
# 收掉一個由本行程 fork 出來的子行程，連同它此刻正卡著的孫行程（幾
# 乎總是一次 herdr 呼叫）。
#
# ---- 為什麼先確認親子關係才送訊號 ----
# 記錄下來的 pid 可能早就結束、而那個號碼被作業系統回收再指派給一個
# 毫不相干的行程；直接 kill 就會打到它。這裡先讀 /proc/<pid>/status
# 的 PPid 確認它現在仍然是本行程的子行程：不用 ps（`ps` 對不存在的
# pid 是空輸出加非 0 結束碼，任何拿它的輸出做字串比較的條件都會在
# ps 失敗時得到「不相等」而誤判——早先版本的 process group 判斷就是
# 這樣寫壞的），也不用 kill -0（那只答得出「這個號碼上有行程」，答
# 不出「是不是我的」）。/proc 目錄不存在就代表那個 pid 已經不在，本
# 來就沒有東西該殺，直接返回是正確的失敗方向。
#
# ---- 為什麼要收整個子樹，不只是那個子行程本身 ----
# 已實測：一條卡在前景指令裡的背景子行程收到 TERM 會立刻死掉（bash
# 在子殼裡把繼承來的 trap 一律重設回預設處置，所以不會被自訂 handler
# 延後），但它底下的行程收不到任何訊號，會被 reparent 之後繼續跑到自
# 己逾時。而這棵子樹比直覺深：邊緣迴圈等一次 herdr 的實際形狀是
#   邊緣迴圈 → `wait_result="$( _eo_agent_wait ... )"` 的子殼
#             → `output="$( herdr ... )"` 的子殼 → herdr → 它的子行程
# 也就是四層以上（已用 `ps -o pid=,ppid=` 對真實執行中的產生器逐層核
# 對過）。只收「子行程加它的直接子行程」會留下更深的那幾層，實測每個
# phase 會殘留兩個仍在跑的行程；「送一次 TERM 之後整棵樹在數秒內結
# 束」是這支腳本的驗收條件之一，所以這裡要走完整棵子樹。
_eo_kill_own_child() {
  local pid="$1" ppid victims v
  [ -n "$pid" ] || return 0

  ppid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  [ "$ppid" = "$_EO_MAIN_PID" ] || return 0

  # 先把整棵子樹列出來，才開始送訊號：一旦上層先死，底下的行程就被
  # reparent，pgrep -P 再也問不出它們屬於誰。
  victims="$(_eo_descendants_deepest_first "$pid")"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    kill -TERM "$v" 2>/dev/null || true
  done <<<"$victims"
}

# _eo_descendants_deepest_first <pid>（內部輔助函式）
# 每行印一個 pid：<pid> 的全部子孫，最深的先印，最後才是 <pid> 自己。
#
# ---- 遞迴的終止條件刻意掛在「沒有子行程」而不是任何外部工具的成敗
#      ----
# pgrep 查不到子行程時輸出空字串，這一層就不再往下遞迴。萬一 pgrep
# 本身不可用，得到的同樣是空字串，於是遞迴立刻停止、只是少收幾層行
# 程——方向是安全的。這一點要跟早先版本那個「掛在 ps 上的遞迴」分清
# 楚：那個寫法是把終止條件寫成「ps 的輸出等於自己的 pid」，ps 失敗時
# 輸出空字串、條件恆為不相等，於是每一層都再包一層，形成沒有上界的
# 行程鏈。差別就在工具失效時條件往哪一邊倒。
_eo_descendants_deepest_first() {
  local pid="$1" kid kids
  kids="$(pgrep -P "$pid" 2>/dev/null || true)"
  while IFS= read -r kid; do
    [ -n "$kid" ] || continue
    _eo_descendants_deepest_first "$kid"
  done <<<"$kids"
  printf '%s\n' "$pid"
}

# _eo_cleanup（內部輔助函式，掛在 EXIT trap 上）
# 不論這個行程怎麼結束（正常、異常、或被 _eo_signal_exit 呼叫
# exit），都在這裡把自己起的子行程與它們的孫行程逐一收掉。
#
# ---- 為什麼是逐一收，不是對 process group 廣播 ----
# 廣播看起來更省事，實際上不安全：不開 job control 時 main 與「啟動
# 它的那個行程」共用同一個 process group，對自己所在的 group 送
# TERM 會連啟動者、以及那個 group 裡任何無關行程一起殺掉（獨立審查
# 實測過：generator、一支無關的 sleep、啟動腳本三者 pgid 相同，只對
# generator 送一次 TERM，三者全部死亡）。早先版本為了讓廣播變安全，
# 改用 setsid 把自己重啟進獨立 session，結果是外層被 TERM 殺掉之後
# 內層變孤兒繼續跑——把「TERM 停不掉常駐迴圈」這個已修過的問題從另
# 一個入口帶了回來（同樣實測重現）。逐一收沒有這個兩難：只碰確認過
# 是自己子行程的 pid，波及範圍在結構上不可能超出自己的子孫，也不需
# 要 setsid、不需要知道自己的 pgid。已實測這個形狀：七個行程的樹
# （main、三條迴圈、三個孫行程），對 main 送一次 TERM，1034 毫秒內
# 全數結束，啟動者本身完全不受影響。
#
# 這裡也不再需要「先 trap - TERM INT 再送訊號」那一步——那是廣播時
# 才有的問題（自己送給整個 group 的訊號會被自己的 trap 再攔一次，形
# 成無窮迴圈，已實測重現）。現在送出的訊號不含自己，沒有這個迴圈。
_eo_cleanup() {
  local p
  for p in "${!_EO_PHASE_PIDS[@]}"; do
    _eo_kill_own_child "${_EO_PHASE_PIDS[$p]}"
  done
  _eo_kill_own_child "${_EO_LOW_FREQ_PID:-}"
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
# 行程全部確實結束。
_eo_signal_exit() {
  exit 0
}

# _eo_phase_watch <phase>（內部輔助函式）
# main 主迴圈每輪對每個列在狀態檔裡的 phase 呼叫一次，決定要不要
# （重）啟動它的邊緣迴圈。這是整份存活契約（見檔頭）的落點，依序：
#   1. 這條迴圈已自願結束過：比對現在的 pane 識別碼與當時記下的那
#      個。相同就什麼都不做；不同代表這個 phase 換了新 pane 復活
#      （操作者重新 start-phase 過），清掉標記重新起一條。這是唯一
#      的恢復入口；沒有它，一個印過 GONE 的 phase 就再也不會被重新
#      監看。
#   2. 子行程還活著：什麼都不做。
#   3. 子行程已經不在了、而且先前記錄過它的 pid：用 wait 取它的結束
#      碼。0 是自願結束，記下標記與當時的 pane 識別碼，不再重起；非
#      0 是異常，回傳那個碼讓 main 結束整支腳本。
#   4. 以上都不適用（也就是第一次看到這個 phase）：起一條邊緣迴圈。
#
# ---- 為什麼用 wait 而不是查狀態檔判斷「是自願還是異常」----
# 已實測：對一個已經結束的背景子行程呼叫 `wait <pid>`，bash 仍然回
# 傳它真正的結束碼（不會因為行程已經消失就取不到）。用結束碼的關鍵
# 好處是這條通道只有邊緣迴圈自己寫得到——若改成讀狀態檔某個欄位來
# 判斷，那個欄位就會同時被低頻掃描寫到，而「重起判斷的輸入被另一條
# 認不同識別碼的通道改寫」正是先前那個無界重複的成因。拿不到結束碼
# （wait 回 127，代表 bash 已經把這個子行程的紀錄丟掉）一律當異常處
# 理：失明是這支腳本存在的理由要消滅的東西，寧可整支結束讓編排端重
# 掛，也不要靜靜地不再監看某個 phase。
_eo_phase_watch() {
  local phase="$1" pane rc

  if [ -n "${_EO_PHASE_DONE[$phase]:-}" ]; then
    pane="$(_eo_phase_pane_id "$phase")"
    if [ "$pane" = "${_EO_PHASE_DONE_PANE[$phase]:-}" ]; then
      return 0
    fi
    unset '_EO_PHASE_DONE[$phase]' '_EO_PHASE_DONE_PANE[$phase]'
    unset '_EO_PHASE_PIDS[$phase]'
  fi

  if [ -n "${_EO_PHASE_PIDS[$phase]:-}" ]; then
    if kill -0 "${_EO_PHASE_PIDS[$phase]}" 2>/dev/null; then
      return 0
    fi

    # 包在 if 裡取結束碼，不寫成裸的 `wait` 再讀 $?：wait 回傳非 0
    # 時 errexit 會在下一行執行之前就把 main 帶走，那樣就永遠印不出
    # 下面那行診斷、也分不出自願與異常（common.sh 的 eo_herdr 上方對
    # 同一個陷阱有更長的說明）。
    if wait "${_EO_PHASE_PIDS[$phase]}"; then
      rc=0
    else
      rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
      _EO_PHASE_DONE[$phase]=1
      _EO_PHASE_DONE_PANE[$phase]="$(_eo_phase_pane_id "$phase")"
      return 0
    fi

    printf 'event-generator.sh: phase %s 的邊緣迴圈以結束碼 %s 異常結束，本產生器即將結束，請編排端重掛\n' \
      "$phase" "$rc" >&2
    return "$rc"
  fi

  _eo_phase_edge_loop "$phase" &
  _EO_PHASE_PIDS[$phase]=$!
}

# _eo_phase_pane_id <phase>（內部輔助函式）
# 印出這個 phase 目前的 pane 識別碼；讀不到就印空字串。只有
# _eo_phase_watch 的恢復判斷用得到它，刻意只讀這一個欄位：這個判斷
# 要答的問題就是「這個 phase 是不是換了新 pane 復活」，多讀欄位只會
# 讓不相干的欄位變動（例如某個計數加一）誤觸恢復。
_eo_phase_pane_id() {
  local value
  if value="$( ( eo_state_get "$1" pane_id ) 2>/dev/null )"; then
    printf '%s' "$value"
  else
    printf ''
  fi
}

# _eo_forget_phase <phase>（內部輔助函式）
# 收掉一個已經不在狀態檔清單裡的 phase：若還記錄著子行程 pid 就把它
# 連同它的孫行程收掉，並把這個 phase 從全部行程內關聯陣列裡清乾淨。
#
# ---- 為什麼需要這個 ----
# phase 的記錄被 close-phase.sh 呼叫 eo_state_remove_phase 移除之
# 後，若不主動收掉，有兩個後果：(1) 那條邊緣迴圈會繼續跑到它自己下
# 一次 wait 返回為止（最長 EO_WAIT_TIMEOUT_MS，也就是最長兩分鐘），
# 之後才會因為讀不到狀態記錄而結束；(2) pid 陣列從不清除，若之後又
# 有新的 phase 重新使用同一個編號，main 會看到殘留的存活 pid 誤判成
# 「已在監看」而不起新迴圈，那筆重建的記錄就一直只有三個座標欄位。
#
# ---- 為什麼直接 kill 這個子行程不會意外觸發整支產生器的清理 ----
# 已用獨立重現腳本驗證兩件事：一是背景子行程雖然繼承了 main 註冊的
# trap 設定，但 bash 在子殼裡把它們重設回預設處置，收到 TERM 就直接
# 終止、不會執行繼承來的 handler；二是背景子行程正常返回（不論結束
# 碼是 0 或非 0）時也不會執行繼承來的 EXIT trap——重現腳本裡
# "cleanup ran" 只在 main 自己的 pid 下出現過一次。所以這裡對單一子
# 行程送訊號不會連鎖觸發 _eo_cleanup。
# ---- 為什麼這裡不清 _EO_SPIN_SEQ／_EO_SPIN_EPOCH ----
# 那兩個陣列只由低頻掃描子行程寫入，而本函式跑在 main。兩者是不同行
# 程、不同記憶體，在這裡 unset 那兩個 key 恆為無操作——早先版本就是那
# 樣寫的，而測試之所以看起來通過，是因為測試在自己的行程裡先給那兩個
# 陣列賦過值，斷言的是一條生產上不可能發生的路徑。真正的遺忘由擁有它
# 們的那個行程自己做，見 _eo_low_freq_scan_once 尾端。
_eo_forget_phase() {
  local p="$1"
  _eo_kill_own_child "${_EO_PHASE_PIDS[$p]:-}"
  unset '_EO_PHASE_PIDS[$p]' '_EO_PHASE_DONE[$p]' '_EO_PHASE_DONE_PANE[$p]'
}

# main（無參數）
# 常駐主迴圈：起低頻掃描，之後每 EO_PHASE_POLL_SECONDS 秒重讀狀態
# 檔，並且：
#   - 對每個列在狀態檔裡的 phase 呼叫 _eo_phase_watch，把「要不要
#     （重）啟動」的判斷交給它（見該函式與檔頭的存活契約）。它回傳
#     非 0 代表某條邊緣迴圈異常結束，main 跟著結束整支腳本，讓串流
#     結束、由編排端重掛一次。
#   - 讀完這一輪的清單後，把已經不在清單內、但行程內還記錄著的
#     phase 交給 _eo_forget_phase 收掉。
#   - 低頻掃描那條子行程若不在了，一律當異常：它是常駐迴圈，不該有
#     自願結束。同樣結束整支腳本交給編排端，而不是自己重起——早先版
#     本自己重起，結果是 SIGTERM 只殺得掉低頻掃描、main 又把 phase
#     迴圈起回來，變成停不下來的半盲活屍。
main() {
  local phases p low_freq_rc watch_rc

  # 這個集合必須每輪重新歸零，所以宣告刻意留在 while 迴圈外、每輪開
  # 頭用 `=()` 清空：bash 對一個已經存在的關聯陣列再跑一次
  # `declare -A`／`local -A` 不會重置它（已實測：宣告寫在迴圈裡時，
  # 連續三輪的 keys 分別是 `1`、`2 1`、`3 2 1`；宣告在迴圈外、每輪
  # `=()` 清空則是 `1`、`2`、`3`）。舊版把宣告寫在迴圈裡，於是這個
  # 集合累積了每一輪見過的所有 phase，「已經不在清單內」的判斷式永
  # 遠為假，下面那段收尾在生產路徑上是死碼、一次都不會執行——獨立審
  # 查實測：移除一個 phase 之後 14 秒（約三輪）那條邊緣迴圈仍然存
  # 活。不要為了「宣告靠近使用處」把它搬回迴圈內。
  #
  # 宣告刻意不帶 `=()` 初始化：每輪開頭那個 `current_phase_set=()` 已
  # 經負責清空，而宣告時的空陣列初始化在較舊的 bash 上行為如何本機無
  # 法查證，拿掉就少一個查證不了的面，行為完全不變。
  local -A current_phase_set

  _EO_MAIN_PID=$$

  trap '_eo_cleanup' EXIT
  trap '_eo_signal_exit' INT TERM

  _eo_low_freq_scan_loop &
  _EO_LOW_FREQ_PID=$!

  while true; do
    if ! kill -0 "$_EO_LOW_FREQ_PID" 2>/dev/null; then
      # 理由同 _eo_phase_watch 裡那段：包在 if 裡取結束碼，不然
      # errexit 會在印出診斷之前就把 main 帶走。
      if wait "$_EO_LOW_FREQ_PID"; then
        low_freq_rc=0
      else
        low_freq_rc=$?
      fi
      printf 'event-generator.sh: 低頻掃描迴圈以結束碼 %s 結束，本產生器即將結束，請編排端重掛\n' \
        "$low_freq_rc" >&2
      return 1
    fi

    # 狀態檔還不存在（generator 比第一個 start-phase 先起）時
    # eo_state_phases 會以 5 結束；這裡接住，視同「目前沒有任何
    # phase」，不是本迴圈的錯誤。
    if phases="$(eo_state_phases 2>/dev/null)"; then
      :
    else
      phases=""
    fi

    current_phase_set=()
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      current_phase_set[$p]=1

      # ---- 這裡刻意不用 `if _eo_phase_watch "$p"; then`，理由是一個
      #      會傳染給子行程的 bash 語意 ----
      # _eo_phase_watch 內部會 fork 出邊緣迴圈子行程。bash 對「正在被
      # if／while／&&／|| 當條件測試的指令」給的 errexit 豁免，不是
      # errexit 這個選項被關掉，而是另一個內部旗標；那個旗標會隨 fork
      # 繼承進子行程，而且在子行程裡終生有效。把這個呼叫寫成 if 條
      # 件，等於讓每一條邊緣迴圈整個生命期的 errexit 都是關著的——後
      # 果是存活契約的「非 0 代表異常」只剩顯式檢查那一半，凡是原本
      # 靠 errexit 攔下的失敗都不再反映成非 0 結束碼。
      #
      # 關鍵在於：**子行程自己重下 `set -euo pipefail` 修不掉這件事**
      # ——那是選項，蓋不掉上面那個內部旗標。已實測四種組合，只有第
      # 四種真的把 errexit 修回來：
      #   fork 在 if 條件裡 ＋ 子行程不重下      → 失敗被吞，結束碼 0
      #   fork 在 if 條件裡 ＋ 子行程重下 set -e → 失敗仍被吞，結束碼 0
      #   fork 在 set +e 下  ＋ 子行程不重下      → 失敗被吞，結束碼 0
      #   fork 在 set +e 下  ＋ 子行程重下 set -e → 失敗攔下，結束碼 7
      # 所以要兩處一起做：這裡用 set +e／裸呼叫／取結束碼／set -e（讓
      # 子行程繼承的是「選項關著」而不是那個清不掉的豁免旗標），並且
      # 由 _eo_phase_edge_loop 在進入時重下 set -euo pipefail。看到這
      # 段不要「簡化」回 if 條件，也不要以為只留子行程那一行就夠。
      set +e
      _eo_phase_watch "$p"
      watch_rc=$?
      set -e

      if [ "$watch_rc" -ne 0 ]; then
        return "$watch_rc"
      fi
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
# 之後、main 之前，跟其餘七支腳本「先查環境前提、再驗參數」的順序
# 一致。
if [ -z "${EO_GENERATOR_NO_MAIN:-}" ]; then
  eo_require_herdr_env
  if [ "$#" -gt 0 ]; then
    eo_die 2 "event-generator.sh: 不接受任何參數，收到：$*"
  fi
  main
fi
