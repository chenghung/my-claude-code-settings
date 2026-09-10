#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/set-phase-field.sh
#
# 用法：set-phase-field.sh <sub-issue 編號> <欄位名> <值>
#
# ---- 補的是哪個缺口 ----
# 狀態檔 phases.<phase> 底下那九個非座標欄位裡（整筆記錄共十二個欄
# 位：tab_id／pane_id／agent_name 三個座標，加這九個），stage、pr、
# held_by_orchestrator
# 三個只有讀取端（event-generator.sh 的分類與低頻掃描）在讀，從來沒有
# 任何腳本寫。編排端（orchestrator）原本沒有寫入路徑：它不能自己
# jq 改那個 JSON 檔——lib/common.sh 的 eo_state_set 用 flock 把「讀-
# 改-寫」整段序列化，繞過它手改會跟事件產生器的併發寫入互相覆蓋，兩
# 邊都可能蓋掉對方剛寫的內容。這支腳本就是編排端唯一合法的寫入入口。
#
# ---- 這三個欄位為什麼非寫不可 ----
# held_by_orchestrator 實作設計規格第七節那條下行互斥：編排端開始處理
# 某個 phase 就把它標成持有中，事件產生器見到就不自動推一把，處理完
# 才放掉。這條互斥存在的理由是實測顯示兩則下行會被併進同一個回合一起
# 執行——一則「繼續」黏在一則定案後面送達時，phase agent 讀到的是一
# 個混合意圖。沒有寫入路徑，這條互斥形同不存在：event-generator.sh
# 讀得到這個欄位，但它永遠停在初始值 false，等於從來沒鎖過。
# pr 是規格第九節說的 PR 編號權威來源，欄位不可寫就無從權威起。
# stage 與 held_by_orchestrator 也是規格第十四節「中斷恢復時標記序號
# 變小要重設基準」判斷所需的欄位——同樣得靠編排端寫得動狀態檔才成立。
#
# ---- 白名單不是防呆，是設計性質的強制執行 ----
# 編排端與事件產生器寫的欄位集合刻意不重疊：編排端只寫 stage、pr、
# held_by_orchestrator 這三個；last_marker_seq、auto_push_count、
# unknown_rounds，以及 spinning_muted／gone_muted／unclassified_muted
# 三個靜音旗標，一律只由 event-generator.sh 寫。這個不重疊正是「不必
# 為每個欄位單獨加鎖」這個決定的依據——eo_state_set 的 flock 只序列化
# 單次呼叫內「讀-改-寫」那一小段，擋不住「兩個都以為自己是某欄位唯一
# 寫入者的行程，各自覆蓋對方剛寫的另一個欄位」這種邏輯層級的競爭；真
# 正擋住這件事的是雙方各自只碰自己欄位集合這個約定。白名單把這個約定
# 從「大家記得遵守」的慣例，變成「呼叫錯了就直接被結束碼擋下」的程式
# 碼保證。日後如果覺得白名單多餘想放寬，請先確認這個不重疊前提有沒有
# 跟著變——放寬白名單，等於同時放寬了「不必逐欄位加鎖」這個決定，兩
# 者是同一件事的一體兩面，不能只改其中一半。
#
# ---- 值也要驗證：這些欄位之後會被別人讀來做判斷 ----
# stage、pr、held_by_orchestrator 寫進去之後，是 event-generator.sh
# 拿來做分類與互斥判斷的依據，不是純粹紀錄用的欄位。寫入不合法的值不
# 會在寫入當下爆炸（jq 什麼字串都收），只會讓下一個讀到它的人做出錯
# 的判斷，而且那個人不是這支腳本、除錯時對不到源頭。因此三個欄位各自
# 有專屬的合法值檢查，不合格一律以呼叫端用錯（結束碼 2）拒絕：
#   stage                 只接受 running／awaiting-decision／pr-ready／
#                          merged／wrapped-up 五個值。實作計畫「狀態
#                          檔結構」一節列的英文值原本有六個，其中
#                          `pending`（等待啟動）刻意不在這裡收：它描
#                          述的是「還在依賴圖裡、但尚未派工」的
#                          phase，而那個時候狀態檔裡根本還沒有它的記
#                          錄——記錄是啟動腳本在派工那一刻才建立的。
#                          `pending` 不是「這個欄位還沒有人去寫」，而
#                          是「它要描述的狀態下，記錄本身不存在」；
#                          而這支腳本要求記錄必須已經存在才寫入（見
#                          下方「寫入前必須確認該 phase 已經存在」一
#                          節），記錄已存在就代表這個 phase 已經派工
#                          過了，把 `pending` 寫進一筆已存在的記錄在
#                          語意上自相矛盾。這個狀態在這支腳本能碰到
#                          的範圍裡本質上不可達，不是漏寫，之後也不
#                          該為了「湊滿六個值」把它加回來。編排端進
#                          度表那一欄是合併 GitHub 與狀態檔兩邊資料
#                          的衍生視圖，六個值在那裡是對的，但那是另
#                          一個不同的呈現層，不是這個欄位。
#   pr                     只接受純數字（PR 編號）。
#   held_by_orchestrator   只接受 true 或 false 兩個布林字面值。
#
# ---- 寫入一律經共用函式庫的寫入函式，不自行 jq、不自行處理鎖 ----
# 這裡有兩個「第三個參數」，層級不同，分開講：命令列的第三個引數（也
# 就是用法裡的 <值>）是裸值，不要帶引號——呼叫時寫
# `set-phase-field.sh <phase> stage running`，不是
# `set-phase-field.sh <phase> stage '"running"'`；帶著引號的裸值不在
# 下面「值也要驗證」那組合法值清單裡，會被以 2 拒絕，而不是被接受。
# `eo_state_update`（共用函式庫的寫入函式）的第三個參數才是 JSON
# 值：字串要自己帶引號（例如 '"running"'），數字與布林直接寫（pr 寫
# 成 456、held_by_orchestrator 寫成 true／false，不加引號）。本腳本
# 在下面的 case 驗證完命令列收到的裸值之後，自己把它轉成這個 JSON
# 值（stage 用 printf 補上引號成字串；pr／held_by_orchestrator 收到
# 的裸值本來就是合法的 JSON 數字／布林字面值，原樣傳遞），才交給
# `eo_state_update`——這正是命令列引數必須是裸值、不必也不該由呼叫端
# 自己先包一層引號的原因：轉換這一步已經在本腳本裡做過，呼叫端不需
# 要知道下一層的 JSON 引號規則。鎖與原子寫入（暫存檔＋mv）全部在
# `eo_state_update` 內部完成，見 lib/common.sh 的實作與註解，本腳本
# 不重做那一層。
#
# ---- 寫入前必須確認該 phase 已經存在，而且這個確認要跟寫入同一把鎖
#      ----
# 這支腳本不建立記錄，只修改既有記錄；建立記錄是 start-phase.sh 的職
# 責，在啟動 agent 之前把 tab_id／pane_id／agent_name 三個座標欄位一
# 次寫齊。這支腳本的正當用途永遠發生在那之後。因此寫入呼叫的是
# `eo_state_update`，不是會自動起孔的 `eo_state_set`——後者對不存在的
# phase 會用 `.phases[$p] //= {}` 自動建出一筆只有剛寫的那個欄位、沒
# 有任何座標欄位的空白記錄，這筆記錄會出現在 eo_state_phases 的列舉
# 結果裡，讓事件產生器下一輪就開始監看一個從未被啟動過的幻影 phase
# ——跟任務七在 event-generator.sh 那一側耗費多輪才消滅的「只有部分
# 欄位的殘骸記錄」是同一種形狀。`eo_state_set` 本身的自動起孔行為不
# 受影響、原樣保留，因為 event-generator.sh 依賴那個形式在讀取端補齊
# 預設欄位；`eo_state_update` 是共用函式庫另開的一個獨立函式。
#
# 這裡曾經是本腳本自己先呼叫 `eo_state_get "$phase" tab_id` 探測存在
# 性、探測通過才呼叫 `eo_state_set` 寫入的兩段式做法，已由獨立審查以
# 一秒睡眠窗口決定性重現出其中的時間差：探測與寫入是兩次獨立呼叫、各
# 自對鎖檔開關一次，中間有一段完全不持鎖的空窗——一個帶完整座標欄位
# 的 phase 通過探測後進入睡眠，睡眠期間另一個行程呼叫
# `eo_state_remove_phase` 合法地把記錄移除，睡眠結束後寫入照跑，落地
# 的正是這道檢查原本要防的幻影記錄，而整支腳本以結束碼 0 結束、呼叫
# 端拿不到任何失敗訊號。「編排端是單執行緒，這個競態在設計流程裡到不
# 了」不是修這件事的理由：跟白名單一樣，這支腳本擋不住自己被誤用，一
# 道留著未上鎖時間差的檢查是部分保證，比誠實地說沒有保證更糟——讀者
# 會信它，而它在最不巧的時刻失效。因此存在性判斷改搬進
# `eo_state_update` 自己的臨界區，跟寫入共用同一把鎖，兩者之間不會再
# 有其他行程插進來，這條路徑不成立。存在性檢查失敗時同樣以狀態檔缺漏
# 的結束碼（5）拒絕、不寫入，語意跟先前一致，只是判斷的位置換了。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 3 ]; then
  eo_die 2 "set-phase-field.sh: 缺少必填參數 <sub-issue 編號> <欄位名> <值>"
fi
phase="$1"
field="$2"
value="$3"

# 白名單與值驗證合併在同一個 case：欄位不在編排端可寫的三個之內，一
# 律落到最後的 *) 分支被拒絕；欄位合法時才進一步驗證對應的值。這個
# case 本身就是檔頭「白名單不是防呆」一節所說的、把約定變成程式碼保
# 證的那個機制。
case "$field" in
  stage)
    case "$value" in
      running|awaiting-decision|pr-ready|merged|wrapped-up)
        json_value="$(printf '"%s"' "$value")"
        ;;
      *)
        eo_die 2 "set-phase-field.sh: stage 的值 '$value' 不合法，只允許 running、awaiting-decision、pr-ready、merged、wrapped-up（pending 不在其列，理由見檔頭「值也要驗證」一節）"
        ;;
    esac
    ;;
  pr)
    case "$value" in
      ''|*[!0-9]*)
        eo_die 2 "set-phase-field.sh: pr 的值 '$value' 不是純數字"
        ;;
      *)
        json_value="$value"
        ;;
    esac
    ;;
  held_by_orchestrator)
    case "$value" in
      true|false)
        json_value="$value"
        ;;
      *)
        eo_die 2 "set-phase-field.sh: held_by_orchestrator 的值 '$value' 不合法，只允許 true 或 false"
        ;;
    esac
    ;;
  *)
    eo_die 2 "set-phase-field.sh: 欄位 $field 不在編排端可寫的白名單內（只允許 stage、pr、held_by_orchestrator），拒絕寫入"
    ;;
esac

# eo_state_update 在同一把鎖內完成存在性判斷與寫入，見檔頭「寫入前必
# 須確認該 phase 已經存在」一節。呼叫排在欄位與值驗證之後——呼叫端傳
# 錯欄位或值本身就是純粹的參數錯誤（結束碼 2），跟這個 phase 在狀態
# 檔裡存不存在無關，不該因為多走一次狀態檔而被結束碼 5 蓋過去。
eo_state_update "$phase" "$field" "$json_value"
