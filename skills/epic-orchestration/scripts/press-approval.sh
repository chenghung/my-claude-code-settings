#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/press-approval.sh
#
# 用法：press-approval.sh <sub-issue 編號> <按鍵> --allows <這次放行的具體動作> [--startup]
#
# ---- 這支腳本獨立成支的唯一理由 ----
# `herdr agent send-keys` 沒有 `agent_blocked` 這類檢查，這條路徑沒有
# 任何內建保護：herdr 不會替呼叫端判斷「現在畫面上是不是真的有一個核
# 准框」，也不會判斷「按下去放行的是不是呼叫端以為的那個動作」。放行
# 什麼完全由畫面上那個框決定，herdr 只負責忠實地把按鍵送過去。這正是
# `--allows` 被設計成必填參數（不是選項、不能有預設值、不能從別處推
# 導）的原因：把「按之前要指得出放行什麼」從一句只能靠人自律遵守的散
# 文約束，變成缺了就連呼叫都跑不動的參數檢查。
#
# ---- 正常運行中幾乎不會被呼叫，但一次做錯的代價與發生率不成比例 ----
# 已實測：`--permission-mode auto` 之下，執行中途的核准框不會為「寫工
# 作目錄外的檔案」這一類跳出來；而 cwd 指向已被信任的主倉庫之後，啟動
# 階段的工作區信任對話框也幾乎不會出現。這支腳本在正常運行中幾乎用不
# 到。它之所以仍要求這麼嚴格（`--allows` 必填、執行前重查狀態），不是
# 因為這件事常發生，而是因為它一旦真的被呼叫又做錯了，代價是打斷某個
# 正在跑的真實 agent，而且錯誤不會反映在任何結束碼上——herdr 不會因
# 為「按錯了框」而回報失敗。
#
# ---- 動作順序：重查 blocked → send-keys → 依情境取憑據 ----
#   1. `herdr agent get <target>` 重新查一次 agent_status，必須仍是
#      `blocked` 才繼續。理由：呼叫端決定要按這顆按鍵，跟這支腳本真的
#      執行按鍵之間有時間差，畫面在這段時間內可能已經換掉（例如對方
#      自己先跳出了那個框、或已經被別的動作處理掉）。按在一張已經換
#      掉的畫面上不會讓 herdr 報錯，但按下去的是別的東西，所以狀態已
#      不是 blocked 時一律以 6 結束、不代按。
#   2. `herdr agent send-keys <target> <按鍵>`。
#   3. 依 `--startup` 決定要等待哪一種憑據（見下一段）。
#
# ---- 兩種取憑據的方式不能共用同一套等待邏輯 ----
# 一般的核准框代按成功後，對方會進入 `working`（開始做被放行的那件
# 事），因此等 `--until working`。但 `--startup`（啟動階段的工作區信
# 任對話框）代按成功後，對方進入的是「啟動就緒」而不是 `working`——
# 它回到的是 `idle`，因為信任對話框本身不是一個任務，通過它只是讓
# agent 可以開始接受輸入。因此 `--startup` 改為等 `--until idle`。兩者
# 都是各自獨立的一次 `herdr agent wait <TARGET> --until <STATUS>
# --timeout <MS>` 呼叫，不能像 send-to-phase.sh 對 `agent prompt` 那樣
# 把等待併進送出那一次呼叫——已對真實 herdr 0.8.2 執行 `--help` 查證：
# `agent send-keys` 的介面是 `<TARGET> <KEY>...`，全部是位置引數，完全
# 沒有任何選項，沒有 `--wait`／`--until`／`--timeout` 可用，等待只能是
# 額外一次獨立呼叫。
#
# ---- 憑據等待的成功／失敗判斷不讀回應內文，只看結束碼與 error.code ----
# `herdr agent wait` 成功時的回應要不要轉發完全不重要：已對真實 herdr
# 唯讀查證，它跟 `agent get` 一樣把 agent 物件包在 `result` 底下的
# `agent` 底下，但本腳本從不解析這個成功回應——herdr 只在真的觀測到
# 目標狀態已符合 `--until` 條件時才回傳成功，結束碼本身就是憑據，不必
# 再多讀一次欄位（跟 send-to-phase.sh 對 `agent prompt --wait` 成功分
# 支的處理方式一致）。失敗分支才需要讀 `error.code`：已對真實 herdr
# 唯讀查證，逾時的錯誤碼是 `timeout`，視為「未取得憑據」，以 7 結束並
# 印 `handshake=none`，交由呼叫端判斷要不要派調查者；其餘錯誤碼（例如
# 目標在等待期間消失的 `agent_not_found`）視為 herdr 拒絕，以 6 結束。
#
# ---- 開發期查證發現的落差：任務簡報原始測試樁把 agent get 寫成扁平
#      結構，與已查證事實衝突 ----
# 任務簡報 Step 1 給的測試樁原文把 `agent get` 的回應寫成
# `{"result":{"agent_status":"blocked"}}`（扁平）。但已對真實 herdr
# 0.8.2 執行 `herdr agent get <target>` 唯讀查證：回應是巢狀的，欄位在
# `result` 底下的 `agent` 底下（`.result.agent.agent_status`），直接取
# `.result.agent_status` 得到的是 `null`。這正是全域約束檔點名過的同一
# 類假設（start-phase.sh 也記錄過一次：先前計畫把「啟動三項」查詢寫成
# 扁平結構，被查證推翻）。本腳本按巢狀結構解析，測試檔對應的樁也已改
# 為巢狀結構，避免「樁與實作共享同一個錯誤假設、綠燈掩蓋真實環境失
# 效」的覆轍。若直接照抄簡報原文的扁平樁，本腳本會對每一次真正成功的
# 重查都誤判成「狀態已不是 blocked」而拒絕代按。
#
# ---- 不加 --dry-run ----
# 一般對破壞性操作的預設要求是提供 --dry-run。這支腳本不加：`--allows`
# 已經是這支腳本專屬、比通用 dry-run 更貼題的安全機制——它強迫呼叫端
# 在呼叫當下就講清楚放行的是什麼，而不是先乾跑一次再決定要不要真的
# 按；介面簽章也是任務簡報逐字給定的固定形式，不添加簡報沒要求的選
# 項。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 2 ]; then
  eo_die 2 "press-approval.sh: 缺少必填參數 <sub-issue 編號> <按鍵>"
fi
phase="$1"
key="$2"
shift 2

allows=""
startup=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allows)
      if [ "$#" -lt 2 ]; then
        eo_die 2 "press-approval.sh: --allows 缺少值"
      fi
      allows="$2"
      shift 2
      ;;
    --startup)
      startup=1
      shift
      ;;
    *)
      eo_die 2 "press-approval.sh: 未知選項 $1"
      ;;
  esac
done

# --allows 必填：不得有預設值、不得從別處推導、不得因為呼叫端沒給就
# 自己編一個。這是整支腳本存在的理由，見檔頭說明。
if [ -z "$allows" ]; then
  eo_die 2 "press-approval.sh: 缺少必填參數 --allows：必須指出這次代按放行的是哪一個具體動作，不得省略"
fi

# 憑據等待逾時，單位毫秒。跟 send-to-phase.sh 的握手逾時同一類——確
# 認「這次代按已經生效」，不是確認「被放行的那件事做完了」，因此沿用
# 同一個 10000ms。
readonly EO_PRESS_APPROVAL_TIMEOUT_MS=10000

target="$(eo_state_get "$phase" agent_name)"

# 執行前重查狀態仍為 blocked：畫面可能已經換掉，見檔頭「動作順序」說明。
get_json="$(eo_herdr agent get "$target")"
current_status="$(printf '%s' "$get_json" | jq -r '.result.agent.agent_status')"
if [ "$current_status" != "blocked" ]; then
  eo_die 6 "press-approval.sh: 目標 $target 的狀態已不是 blocked（目前是 $current_status），畫面可能已換掉，拒絕代按這次放行的動作：$allows"
fi

# herdr agent send-keys 沒有 agent_blocked 這種內建保護，見檔頭說明。
eo_herdr agent send-keys "$target" "$key" >/dev/null

# 依 --startup 決定要等待哪一種憑據，見檔頭「兩種取憑據的方式」說明。
if [ "$startup" -eq 1 ]; then
  wait_until=idle
else
  wait_until=working
fi

# 不透過 eo_herdr：eo_herdr 會把 herdr 結束碼 1 一律映射成 6，但這裡
# 要分辨「逾時（7，未取得憑據）」跟「其他拒絕（6）」，做法與
# send-to-phase.sh 對 agent prompt --wait 完全一致，包括把呼叫包在 if
# 條件裡的理由：本腳本已 set -e，裸陳述句一旦失敗會在讀到 $? 之前就
# 先終止整個腳本，走不到下面的碼判斷。`2>&1 >/dev/null`：先把 fd2 導
# 向目前的 fd1（也就是被命令替換擷取的管線），再把 fd1 導向
# /dev/null，結果只有 stderr（herdr 的錯誤 JSON 印在這裡）被擷取進
# err_output，stdout（成功時的 agent 物件，本腳本不需要）直接丟棄。
rc=0
if err_output="$(herdr agent wait "$target" --until "$wait_until" \
    --timeout "$EO_PRESS_APPROVAL_TIMEOUT_MS" 2>&1 >/dev/null)"; then
  printf 'handshake=ok\n'
  exit 0
else
  rc=$?
fi

if [ "$rc" -eq 2 ]; then
  eo_die 2 "press-approval.sh: herdr 以結束碼 2 拒絕 agent wait，疑似腳本呼叫語法錯誤（target=$target）"
fi
if [ "$rc" -ne 1 ]; then
  exit "$rc"
fi

error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
case "$error_code" in
  timeout)
    printf 'handshake=none\n'
    exit 7
    ;;
  *)
    eo_die 6 "press-approval.sh: herdr 以結束碼 1 拒絕 agent wait（target=$target），錯誤碼非逾時類：$err_output"
    ;;
esac
