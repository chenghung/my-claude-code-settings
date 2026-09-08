#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/set-phase-field.sh
#
# 用法：set-phase-field.sh <sub-issue 編號> <欄位名> <值>
#
# ---- 補的是哪個缺口 ----
# 狀態檔 phases.<phase> 底下九個欄位裡，stage、pr、held_by_orchestrator
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
#   stage                 只接受 pending／running／awaiting-decision／
#                          pr-ready／merged／wrapped-up 六個值，逐字取
#                          自全域約束檔「狀態檔結構」一節列的英文值。
#   pr                     只接受純數字（PR 編號）。
#   held_by_orchestrator   只接受 true 或 false 兩個布林字面值。
#
# ---- 寫入一律經 eo_state_set，不自行 jq、不自行處理鎖 ----
# eo_state_set 的第三個參數是 JSON 值而非字串：字串要自己帶引號（例如
# stage 寫成 '"running"'），數字與布林直接寫（pr 寫成 456、
# held_by_orchestrator 寫成 true／false，不加引號）。鎖與原子寫入（暫
# 存檔＋mv）全部在 eo_state_set 內部完成，見 lib/common.sh 的實作與
# 註解，本腳本不重做那一層。

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
      pending|running|awaiting-decision|pr-ready|merged|wrapped-up)
        json_value="$(printf '"%s"' "$value")"
        ;;
      *)
        eo_die 2 "set-phase-field.sh: stage 的值 '$value' 不合法，只允許 pending、running、awaiting-decision、pr-ready、merged、wrapped-up"
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

eo_state_set "$phase" "$field" "$json_value"
