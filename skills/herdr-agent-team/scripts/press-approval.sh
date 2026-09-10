#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/press-approval.sh
#
# 用法：
#   press-approval.sh --to <worker> --key <按鍵> --allows <這次放行什麼> \
#     [--rule <herdr 規則名>] [--startup]
#
# 職責（規格 §11）：整個 skill 裡唯一「放行什麼不由呼叫端決定、呼叫端
# 只負責按下去」的動作——`herdr agent send-keys` 這條路徑沒有任何內建
# 保護，herdr 不會替呼叫端判斷畫面上是不是真的有一個核准框，也不會判斷
# 按下去放行的是不是呼叫端以為的那個動作，放行什麼完全由畫面上那個框決
# 定。它的守衛因此比別處嚴，而且射程必須是封閉的（見下方「四類框」）。
#
# ---- 四類框，逐條處置 ----
#   1. CLI 啟動框、規則名在 Task 5 的 hat_approval_allowlist 允許清單
#      上：自決代按，但**呼叫端給的 --key 必須與清單載明的按鍵一致**
#      （見下方「允許清單命中時，--key 與清單不一致就拒絕，不做靜默覆
#      蓋」）。目前只有 startup_update → 2（Skip）。
#   2. 啟動階段的框、不在允許清單上：升級給人，不代按。涵蓋三種情形
#      （規則名不在清單上、herdr 落在 unknown 分不出來、規則名對得上但
#      清單沒載明按哪一顆），三者的共同點是「無法確定」——
#      hat_approval_allowlist 的介面本身就是為了把這三種收斂成同一個判
#      斷：只要它沒有回傳 0 並印出一個非空字串，就是無法確定，一律以 4
#      結束，不需要在本腳本裡逐一分辨是三種裡的哪一種。
#   3. 工作區信任框：升級給人。它問的是使用者信不信任這個目錄，只有使
#      用者答得了——本腳本從不讀畫面，分辨不出眼前這個 blocked 狀態究
#      竟是不是一個工作區信任框，這件事完全是呼叫端（讀過畫面的調查
#      者）的責任：遇到這一類框時，呼叫端根本不應該呼叫本腳本，直接把
#      決定權交給人類。本腳本沒有、也不需要任何程式碼路徑對應這一類。
#   4. 執行中途的核准框：按鍵值一律取自調查者的指名，也就是不帶
#      --startup 時的預設路徑——本腳本原樣使用呼叫端給的 --key，不查允
#      許清單（清單只收錄啟動框的規則名）。放行範圍大於這一次那個具體
#      動作（「總是允許」這一類）一律升級、不代按；拒絕鍵走獨立處置，
#      --allows 填保留值「不放行任何動作，僅解除阻塞」。這兩點都是呼叫
#      端（讀過畫面、判斷這顆鍵是放行還是拒絕、放行範圍多大的調查者）
#      要遵守的協定：本腳本分辨不出手上這顆鍵放行的是什麼、範圍多大
#      （同一顆鍵在不同的框上可能是「是，而且以後不要再問」，也可能是
#      「否，並告訴它該怎麼改」），硬寫一份規則去猜測等於猜那個框長什
#      麼樣，猜錯的後果比不猜更糟——這與 skills/epic-orchestration/
#      scripts/press-approval.sh 檔頭「不做成『只有拒絕鍵才放寬』」一節
#      是同一個理由。呼叫端若判斷放行範圍過大，就不應該呼叫本腳本。
#
# ---- 允許清單命中時，--key 與清單不一致就拒絕，不做靜默覆蓋 ----
# 修正迴圈第一輪裁決：命中允許清單時，若呼叫端的 --key 與清單載明的按
# 鍵不一致，以 2 結束，訊息同時點出兩個值；不是本次實作最初採用的「用
# 清單值靜默覆蓋 --key」。
#
# 理由：這支腳本是整個 skill 裡唯一「放行什麼不由呼叫端決定、呼叫端只
# 負責按下去」的動作，正因為如此，呼叫端與清單之間的分歧本身就是訊
# 號——呼叫端以為它在按 A，實際會按下 B，這兩者不一致代表有一方的認知
# 是錯的（可能是呼叫端打錯 --key，也可能是清單本身需要更新）。靜默覆
# 蓋雖然按對了鍵，卻把那個錯誤認知留在原地，下一次它可能出現在一個沒
# 有清單保護的地方（例如第四類「執行中途的核准框」，那裡沒有清單可以
# 接住錯誤的 --key）。以 2 結束會逼那一方回去對齊，而不是靠這支腳本悄
# 悄把錯誤蓋過去。
#
# ---- 共同守衛（沿用 epic-orchestration 已驗過的形狀）----
#   1. --allows 必填。空字串或缺席以 2 結束——這是整支腳本存在的理由：
#      逼呼叫端在按下去之前就把「這一次到底放行了什麼」講清楚，不得有
#      預設值、不得從別處推導。
#   2. 代按之前重查一次 agent get，狀態必須仍是 blocked；不是就以 4 結
#      束，訊息說明畫面已經變了、按下去的會是別的東西。呼叫端決定要按
#      這顆鍵，跟本腳本真的執行按鍵之間有時間差，畫面在這段時間內可能
#      已經換掉（例如對方自己先跳出了那個框、或已經被別的動作處理
#      掉）；按在一張已經換掉的畫面上不會讓 herdr 報錯，錯誤不會反映在
#      任何結束碼上——herdr 只負責忠實地把按鍵送過去。
#   3. <按鍵> 原樣轉送給 herdr agent send-keys，腳本不解讀。
#   4. 代按之後重查一次狀態並印出來；仍然是 blocked 就以 7 結束，說明
#      那個框還在（見下方「代按後重查狀態」一節）。
#
# ---- 入口守衛：hat_assert_workspace 用在既有 target 上 ----
# 本腳本接受呼叫端傳入的既有 target（worker 已註冊的座標），跟
# instruct.sh 是同一類：從 registry 讀出這個 worker 的 pane_id，對它斷
# 言屬於本 workspace，早於任何 herdr 呼叫（含代按前的重查）。
#
# ---- --to 的名稱格式驗證（全域約束）----
# --to 會被直接用來組 `workers/<--to>.json` 這條 registry 路徑；含斜線
# 或上層目錄記號的值可以組出跳脫 registry 根目錄的路徑，因此必須先驗過
# herdr agent 名稱正規表示式（`^[a-z][a-z0-9_-]{0,31}$`）才能使用，不合
# 格式的以 2 結束（呼叫端用錯，不是守衛不通過）。驗證函式
# hat_assert_agent_name 定義在 lib/common.sh，後續任務會沿用同一個函式
# 驗證各自從參數或環境變數讀來的名稱。
#
# ---- 不加 --dry-run ----
# --allows 已經是這支腳本專屬、比通用 dry-run 更貼題的安全機制：它強迫
# 呼叫端在呼叫當下就講清楚放行的是什麼，而不是先乾跑一次再決定要不要真
# 的按。介面簽章也是任務簡報逐字給定的固定形式，不添加簡報沒要求的選
# 項（沿用 epic-orchestration/scripts/press-approval.sh 同一節的既有理
# 由）。
#
# ---- 代按後重查狀態 ----
# 修正迴圈第一輪補上的一步（原計畫遺漏，非本次實作疏漏）：herdr 只負責
# 把按鍵送到，它不會、也無法驗證那個按鍵在當下畫面上是不是呼叫端以為的
# 那個動作。少了這一步，「代按成功」與「按了但框還在」在呼叫端看起來完
# 全一樣，而後者代表按錯了鍵——那正是這支腳本最該讓人知道的事。
#
# 做法：`herdr agent send-keys` 一送出，立刻再查一次 `agent get`，把查
# 到的狀態印在 stdout；若仍然是 blocked，以 7 結束並在訊息裡明講「那個
# 框還在」。7 在這個專案裡的語意是「不算失敗，由呼叫端決定下一步」，正
# 合適——這不是「按鍵沒送出去」（那是 herdr 拒絕，映射成 6），也不是
# 「畫面已經換掉、按下去的是別的東西」（那是代按前重查失敗，映射成
# 4），而是「按鍵確實送到了，但看起來沒有起作用」，呼叫端需要自己決定
# 要不要重新讀畫面、要不要換一顆鍵再試一次。
#
# 這一步跟 skills/epic-orchestration/scripts/press-approval.sh 送出按鍵
# 後 `herdr agent wait` 的憑據等待是同一個目的（確認代按真的生效），但
# 手法不同：那支腳本用 `agent wait` 阻塞等到狀態離開 blocked 或逾時，
# 這裡改用「查一次、立刻判斷」——因為這支腳本沒有排定任何逾時參數，且
# `blocked` 本身沒有自然消失的機制（不像 idle/working 那樣會隨對方動作
# 改變），阻塞等待在這裡沒有一個明確該等多久的依據；查一次已經足夠回
# 答「按下去之後，框還在不在」這個問題。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

to="" key="" allows="" rule=""
startup=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "press-approval.sh: --to 缺值"
      to="$2"; shift 2 ;;
    --key)
      [ "$#" -ge 2 ] || hat_die 2 "press-approval.sh: --key 缺值"
      key="$2"; shift 2 ;;
    --allows)
      [ "$#" -ge 2 ] || hat_die 2 "press-approval.sh: --allows 缺值"
      allows="$2"; shift 2 ;;
    --rule)
      [ "$#" -ge 2 ] || hat_die 2 "press-approval.sh: --rule 缺值"
      rule="$2"; shift 2 ;;
    --startup)
      startup=1; shift ;;
    *)
      hat_die 2 "press-approval.sh: 未知參數 '$1'" ;;
  esac
done

if [ -z "$to" ]; then
  hat_die 2 "press-approval.sh: --to 為必填"
fi
if [ -z "$key" ]; then
  hat_die 2 "press-approval.sh: --key 為必填"
fi
# --allows 必填：不得有預設值、不得從別處推導，見檔頭「共同守衛」第 1
# 項。空字串或缺席在這裡是同一個判斷（-z 兩者都成立）。
if [ -z "$allows" ]; then
  hat_die 2 "press-approval.sh: 缺少必填參數 --allows：必須指出這次代按放行的是哪一個具體動作，不得省略"
fi

# --to 的名稱格式驗證，見檔頭「--to 的名稱格式驗證」一節。早於任何
# registry 路徑組裝。
hat_assert_agent_name "$to"

registry_root="$(hat_registry_root)"
worker_file="$registry_root/workers/$to.json"

# ---- 入口守衛：對這個既有 target 的座標斷言屬於本 workspace，早於任
#      何 herdr 呼叫（見檔頭「入口守衛」一節）----
pane_id="$(hat_json_get "$worker_file" '.pane_id')"
hat_assert_workspace "$pane_id"

# ---- 第一類／第二類框：--startup 時查允許清單，決定能不能自決代按
#      （見檔頭「四類框」與「允許清單命中時，--key 與清單不一致就拒
#      絕」兩節）。不帶 --startup 時完全不查清單，直接沿用呼叫端給的
#      --key（第四類：執行中途的核准框，按鍵值一律取自調查者的指名）
#      ----
if [ "$startup" -eq 1 ]; then
  allow_key=""
  if allow_key="$(hat_approval_allowlist "$rule")"; then
    if [ "$key" != "$allow_key" ]; then
      hat_die 2 "press-approval.sh: --key '$key' 與允許清單對規則 '$rule' 載明的按鍵 '$allow_key' 不一致，拒絕代按。呼叫端與清單的認知必須先對齊：可能是 --key 打錯，也可能是允許清單本身需要更新"
    fi
  else
    hat_die 4 "press-approval.sh: 啟動框規則 '$rule' 不在允許清單上（或缺席、無法判斷是哪一條規則），升級給人確認，不代按。呼叫端原本想放行的動作：$allows"
  fi
fi

# ---- 共同守衛第 2 項：代按之前重查一次狀態，必須仍是 blocked ----
# 裸賦值（不接 `|| rc=$?`）讓 hat_herdr 對這通呼叫本身的失敗（herdr 拒
# 絕、語法錯誤）直接透過 errexit 帶著它自己已經映射好的結束碼（6 或 2）
# 終止整支腳本；查到的狀態是不是 blocked 則是業務層判斷，用顯式 if 處
# 理，跟 launch-worker.sh 第 5 步（確認不在 blocked）同一個手法。
agent_get_json="$(hat_herdr agent get "$to")"
current_status="$(printf '%s' "$agent_get_json" | jq -r '.result.agent.agent_status // empty')"
if [ "$current_status" != "blocked" ]; then
  hat_die 4 "press-approval.sh: 目標 $to 的狀態已不是 blocked（目前是 '$current_status'），畫面可能已經換掉，按下去的會是別的東西，拒絕代按這次放行的動作：$allows"
fi

# ---- 共同守衛第 3 項：<按鍵> 原樣轉送，腳本不解讀 ----
hat_herdr agent send-keys "$to" "$key" >/dev/null

# ---- 共同守衛第 4 項：代按之後重查一次狀態，見檔頭「代按後重查狀
#      態」一節 ----
after_get_json="$(hat_herdr agent get "$to")"
after_status="$(printf '%s' "$after_get_json" | jq -r '.result.agent.agent_status // empty')"
printf 'to=%s key=%s post_press_status=%s\n' "$to" "$key" "$after_status"

if [ "$after_status" = "blocked" ]; then
  hat_die 7 "press-approval.sh: 按鍵已送出，但目標 $to 的狀態仍是 blocked——那個框還在，這次代按可能按錯了鍵，也可能有另一個框疊在上面。呼叫端需要重新讀畫面決定下一步，不得直接視為代按成功"
fi

exit 0
