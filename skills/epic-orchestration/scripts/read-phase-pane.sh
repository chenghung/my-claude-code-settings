#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/read-phase-pane.sh
#
# 用法：read-phase-pane.sh <sub-issue 編號> [--marker-only]
#
# 讀一個 phase 的終端畫面。預設輸出畫面文字；--marker-only 只輸出畫
# 面上最後一個狀態標記行，格式固定是：
#   [PHASE <編號>] seq=<N> state=<狀態>
# 抓不到標記行時輸出 `marker=none`，交由呼叫端決定要不要因此派調查
# 者，不是這支腳本自己判斷。
#
# ---- 誰能用哪一種模式 ----
# investigator 讀畫面全文（預設模式），用來理解對方卡在哪裡；
# event-generator.sh 的邊緣觸發只抓標記行（--marker-only），拿新的
# seq 判斷有沒有進展；orchestrator 兩種模式都不呼叫本腳本——它只透
# 過 phase-status.sh 看 herdr 自己的狀態分類，不需要、也不應該自己
# 解讀畫面文字。
#
# ---- 讀取行數上限 200，腳本內定，呼叫端不得覆寫 ----
# 這是權限半徑的一部分，不是效能考量：本腳本的介面完全沒有讓呼叫端
# 指定行數的選項。
#
# ---- 不分級讀取：這是一道不存在的階梯 ----
# 已對真實 herdr 0.8.2、對一個活著的 Claude Code agent pane 實測：不
# 論 --lines 給多少、不論 --source 選 visible／recent／
# recent-unwrapped／detection 哪一個，回傳內容都只有終端當下一屏
# （實測 viewport_rows 42 行）。下面把 --lines 定成 200，不是為了拿
# 到比 42 行更多的內容——拿不到，而且升級之後（例如先讀一次抓不到標
# 記行、再加大 --lines 或換 --source 重讀）不會有任何錯誤訊息或欄位
# 告訴你沒拿到更多，只會安靜地拿回同一份內容。取 200 而非目前實測到
# 的 42，理由是 42 是終端「當下」的高度，不是協定保證的上限；終端變
# 高時真正存在的內容可能超過 42 行，寫死 42 會截掉那些內容。200 給
# 足餘裕，但實際回傳量仍完全由 herdr 自己的一屏限制決定，不受這個數
# 字影響。後續維護者若想靠加大這個數字換取更多內容，不會成功——這正
# 是特地寫這段註解的理由。

set -euo pipefail
IFS=$'\n\t'

# 見上方「不分級讀取」說明：這個數字給足餘裕，但拿不到比一屏更多的
# 內容，不要因為某次讀不到想要的東西就加大它。
readonly EO_PANE_READ_LINES=200

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 1 ]; then
  eo_die 2 "read-phase-pane.sh: 缺少必填參數 <sub-issue 編號>"
fi
phase="$1"
shift

marker_only=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --marker-only)
      marker_only=1
      shift
      ;;
    *)
      eo_die 2 "read-phase-pane.sh: 未知選項 $1"
      ;;
  esac
done

# --marker-only 會把 phase 原樣接進下面 grep 的 basic regular
# expression 樣式（`^\[PHASE ${phase}\] seq=`）。若 phase 帶有正規表
# 示式特殊字元（例如未跳脫的中括號），grep 會把它解讀成字元類別、吃
# 掉後面的字元，結果是靜默回報 `marker=none`——這個結果跟「畫面上真
# 的沒有標記行」完全無法區分，不會有任何錯誤訊息（獨立審查以自建樁
# 重現過）。因此在組出 grep 樣式之前，先驗證 phase 是純數字（本專案
# 命名慣例裡 sub-issue 編號恆為數字），不符就以呼叫端用錯的 2 明確拒
# 絕，不留給 grep 去靜默吞掉。這項驗證只在 --marker-only 需要用到
# grep 時才做：預設模式不把 phase 接進任何正規表示式，不受這個問題
# 影響，不必連帶收緊介面。
if [ "$marker_only" -eq 1 ]; then
  case "$phase" in
    ''|*[!0-9]*)
      eo_die 2 "read-phase-pane.sh: --marker-only 要求 <sub-issue 編號> 是純數字（會被接進 grep 的比對樣式），收到：$phase"
      ;;
  esac
fi

pane_id="$(eo_state_get "$phase" pane_id)"
tab_id="$(eo_state_get "$phase" tab_id)"

# 「本 workspace 為何」的判定集中在 eo_assert_workspace（來源是
# HERDR_WORKSPACE_ID，見 common.sh），本腳本不自行重新推導。狀態檔
# 裡的 tab_id 不通過這一關就視為記錄過期，以 4 結束。
eo_assert_workspace "$tab_id"

# 透過 eo_herdr 呼叫：herdr pane read 的輸出是純文字（不是 JSON），
# 成功時原樣轉發給呼叫端即可；失敗時（agent_blocked、
# agent_not_found、pane_not_found、tab_not_found 等，錯誤 JSON 印在
# stderr、herdr 結束碼 1）eo_herdr 一律映射成本專案的 6，不需要、也
# 不應該在這裡自己再解析錯誤 JSON 的 error.code 另外分岔——pane read
# 這條路徑沒有 send-to-phase.sh／press-approval.sh 那種「逾時（7）跟
# 其他拒絕（6）要分開」的情況，所有 herdr 拒絕在這支腳本裡都歸同一種
# 結果，跟 close-phase.sh 的 `eo_herdr tab close` 是同一種簡單用法。
screen="$(eo_herdr pane read "$pane_id" --lines "$EO_PANE_READ_LINES")"

if [ "$marker_only" -eq 0 ]; then
  printf '%s\n' "$screen"
  exit 0
fi

# --marker-only：抓畫面上最後一個標記行，不是第一個，也不能用出現
# 次數判斷——一屏內可能同時存在好幾個回合的標記（實測看過
# seq=1,1,2,2,3,4,4 這樣的序列，是終端捲動疊代留下的殘影，不代表真
# 的發生了這麼多次事件），因此用 grep 取出全部命中、tail -n 1 拿最
# 後一行。
#
# 用 grep 而非 rg 是刻意的：這支檔案會在別人的機器上執行，grep 是
# POSIX 保證存在而 rg 不是——這跟「自己在終端下指令一律用 rg」是兩件
# 不同的事，前者是產出物本身的可攜性，後者是互動當下的工具選擇。
#
# `|| true`：grep 在完全沒有命中時以結束碼 1 收場，本腳本開了
# pipefail，命中零筆是「沒有標記行」這個正常、預期得到的結果，不是
# 腳本的錯誤，因此吞掉這個結束碼，改以 matches 是否為空字串來判斷。
matches="$(printf '%s\n' "$screen" | grep "^\[PHASE ${phase}\] seq=" || true)"
if [ -z "$matches" ]; then
  printf 'marker=none\n'
  exit 0
fi
printf '%s\n' "$matches" | tail -n 1
