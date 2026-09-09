#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/press-approval.sh
#
# 用法：press-approval.sh <sub-issue 編號> <按鍵> --allows <這次放行的具體動作> [--startup]
#
# ---- 這支腳本獨立成支的唯一理由 ----
# `herdr agent send-keys` 這條路徑沒有任何內建保護：herdr 不會替呼叫端
# 判斷「現在畫面上是不是真的有一個核准框」，也不會判斷「按下去放行的
# 是不是呼叫端以為的那個動作」。放行什麼完全由畫面上那個框決定，herdr
# 只負責忠實地把按鍵送過去。
#
# 這一段有一個未實測的成分要標明（references/rationale.md 那一側標的
# 就是未實測，本檔先前寫成事實陳述，是兩邊不一致）：`send-keys` 到底
# 有沒有像 `agent prompt` 那樣的 `agent_blocked` 檢查，本輪沒有量測，
# 因為要看到它只能真的對一個 blocked 的目標送一次按鍵，那是有副作用
# 的動作。
#
# 它若其實有那道檢查，垮掉的是流程本身，不是這一段的措辭——這一點要
# 寫死，因為相反的說法曾經寫在這裡：`agent prompt` 那道檢查的行為是
# 拒絕執行並回錯誤，而 lib/common.sh 的 eo_herdr 把 herdr 的結束碼 1
# 一律映成 eo_die 6。本腳本只在重查狀態仍為 blocked 時才代按，所以那
# 個假設一旦成立，每一次代按都會以 6 結束、一顆鍵也按不下去；而 6 的
# 既有退路是改用 send-to-phase.sh 送文字，那一條對 blocked 的對象同樣
# 被 agent_blocked 拒絕成 6（已實測，見 rationale.md「下行對 blocked
# 的對象會被明確拒絕」），於是卡在 blocked 的 phase 完全沒有出路。真
# 的落在這一種，要換的是送鍵的手段，不是改這裡的字。
#
# 不受這個假設影響的，是那兩道狀態守衛「各自為什麼要存在」這件事：
# 代按前重查仍為 blocked、代按後只確認狀態已離開 blocked，兩者各自的
# 設計理由與 send-keys 攔不攔都無關。這一句只能讀到這裡，不要讀成
# 「那個假設成立時這兩道仍然發揮作用」——那是假的：第一道正是把假設
# 變成必死的那一步（重查仍為 blocked 才代按，於是每次都送進那個會被
# 拒絕的呼叫），而第二道永遠到不了，因為送鍵那一行就已經 eo_die 6。這正是
# `--allows` 被設計成必填參數（不是選項、不能有預設值、不能從別處推
# 導）的原因：把「按之前要指得出放行什麼」從一句只能靠人自律遵守的散
# 文約束，變成缺了就連呼叫都跑不動的參數檢查。
#
# ---- 正常運行中幾乎不會被呼叫，但一次做錯的代價與發生率不成比例 ----
# 已實測的射程只到一類操作：`--permission-mode auto` 之下，執行中途的
# 核准框不會為「以 Bash 工具對工作目錄以外的路徑建立檔案」這一類跳出
# 來。其餘類型未實測，不要把它讀成「不會為任何越界寫入跳出來」——用
# Edit 或 Write 改寫既有檔案是另一條路徑（專案層還掛著一個 matcher 為
# Edit|Write 的 PreToolUse hook），其中若有會跳框的，那一種會讓該
# phase 停在 blocked，而這支腳本正是為那一種留的。另外，cwd 指向已被
# 信任的主倉庫之後，啟動階段的工作區信任對話框也幾乎不會出現。這支腳本在正常運行中幾乎用不
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
#   3. 等待「狀態已離開 blocked」這個憑據；`--startup` 只決定接受哪些
#      落點（見下一段）。
#
# ---- 兩種模式等的都是「狀態已離開 blocked」，差別只在落點有哪些 ----
# 這次等待要確認的事只有一件：這次代按真的生效了、畫面上那個框已經不
# 在。也就是「狀態已離開 `blocked`」，不是「被放行的那件事已經開始
# 做」。`working` 只是其中一種落點，不是這次等待在檢查的性質。
#
# 非啟動階段等的是 `--until idle --until done --until working`，三個
# 都收。只等 `working` 會有一整類代按永遠等不到：拒絕鍵（`esc`、否、
# 取消這一類）依定義不放行任何動作，被否決的 agent 進入什麼狀態取決於
# 它收到否決後是繼續處理還是就此停下；只要它落回停下態，這條路徑就每
# 次都在逾時後拿到 7，而 7 的處置是「按鍵已送出、不得重按、派調查
# 者」——等於每一次拒絕代按都固定燒掉一次調查。放行鍵也不保險：被放
# 行的動作若在 herdr 兩次觀測之間就跑完，`working` 是個瞬間態，一樣可
# 能整段錯過，失敗形狀完全相同。
#
# 放寬的只有「接受哪些落點」，這次等待原本要守的東西沒有變：代按若根
# 本沒生效，對方仍然停在 `blocked`，三個值一個都不會出現，照樣逾時、
# 照樣以 7 結束。換掉的是「分辨對方現在是在做事還是停著」這個能力，而
# 本腳本從來不用它——成功分支只印 `handshake=ok`、不解析回應內文（見
# 下方「憑據等待的成功／失敗判斷不讀回應內文」）；真要知道當下狀態，
# 該查的是 `phase-status.sh`。
#
# 不做成「只有拒絕鍵才放寬」：這支腳本分辨不出手上那顆鍵是放行還是拒
# 絕。`<按鍵>` 是原樣轉送給 `herdr agent send-keys` 的不透明字串，腳本
# 從不讀畫面，同一顆 `2` 在不同的框上可能是「是，而且以後不要再問」，
# 也可能是「否，並告訴它該怎麼改」。硬寫一份拒絕鍵名單等於猜那個框長
# 什麼樣，而猜錯時的失敗形狀正是這裡要修掉的那一種：一次拒絕被當成放
# 行、等一個不會來的 `working`、逾時、白派一次調查。用一份會猜錯的分
# 類去修一個由錯誤分類造成的缺陷，不是修法。
#
# `--startup`（啟動階段的工作區信任對話框）維持 `--until idle --until
# done`，不加 `working`：那個時點沒有任何 prompt 排著等做——
# start-phase.sh 只負責把 agent 起起來，開場指令是稍後才由
# send-to-phase.sh 送的——通過信任對話框只是讓 agent 可以開始接受輸
# 入，落點就是停下態。而「已離開 `blocked`」在這條路徑上有 `idle` 與
# `done` 兩個值、兩個都要接受：依這個系統已知的行為，一個沒有被使用者
# 在 herdr 介面裡點進去看過的 tab，停下時回報的是 `done` 而不是
# `idle`；這條路徑的情境正是使用者只在對話裡回答「信任」、由編排端代
# 按，未必點進過那個 tab。只等 `idle` 的話，每一次啟動階段代按都會等
# 到逾時、拿到 7——不是偶發，是這條路徑的常態。
#
# `--until` 可以重複給值這件事已對真實 herdr 0.8.2 查證：`herdr agent
# wait --help` 寫的是「State to match; repeat for more than one state」
# （可用值 idle／working／blocked／done／unknown），而且不只讀說明——
# 對一個不存在的 agent 實際下過 `herdr agent wait <不存在的名稱>
# --until idle --until done --timeout 1000`（唯讀、無副作用），回應是
# `{"error":{"code":"agent_not_found",...}}`、結束碼 1，也就是重複的
# `--until` 已經通過引數解析、真的送到伺服器端了，不是被當成語法錯誤
# 擋在解析階段（那會是結束碼 2）。
#
# 兩者都是各自獨立的一次 `herdr agent wait <TARGET> --until <STATUS>
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
# 目標在等待期間消失的 `agent_not_found`）視為 herdr 拒絕，以 6 結
# 束，訊息只含 error.code 與 error.message 兩個純字串欄位，不轉發回
# 應原文（理由見下方對應程式碼旁的註解）。
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

# phase 一律驗成純數字，與消費端契約對齊；完整理由見 start-phase.sh
# 同一道檢查上方的說明，不在這裡重複。
case "$phase" in
  ''|*[!0-9]*)
    eo_die 2 "press-approval.sh: <sub-issue 編號> 必須是純數字，收到：$phase"
    ;;
esac

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

# workspace 守衛：本腳本與 send-to-phase.sh 是唯二會對一個活著的
# agent 送出輸入（下行文字／按鍵）的腳本，射程比其餘唯讀或只動狀態檔
# 的腳本都大。狀態檔的 tab_id 與這裡的 target（agent_name）只綁主倉
# 庫路徑（agent_name 是 phase 編號加主倉庫路徑的雜湊，見 common.sh 的
# eo_agent_name），同一個主倉庫在兩個不同 workspace 各跑一次 epic
# 時，兩邊的狀態檔與 agent 名稱會重合，跨 workspace 誤按在這裡不是理
# 論可能。「本 workspace 為何」的判定集中在 eo_assert_workspace（來
# 源是 HERDR_WORKSPACE_ID，見 common.sh），本腳本不自行重新推導。狀
# 態檔裡的 tab_id 不通過這一關就視為記錄過期，以 4 結束，且發生在下
# 面任何一支 herdr 呼叫（含重查狀態、代按）之前。
tab_id="$(eo_state_get "$phase" tab_id)"
eo_assert_workspace "$tab_id"

# 執行前重查狀態仍為 blocked：畫面可能已經換掉，見檔頭「動作順序」說明。
get_json="$(eo_herdr agent get "$target")"
current_status="$(printf '%s' "$get_json" | jq -r '.result.agent.agent_status')"
if [ "$current_status" != "blocked" ]; then
  eo_die 6 "press-approval.sh: 目標 $target 的狀態已不是 blocked（目前是 $current_status），畫面可能已換掉，拒絕代按這次放行的動作：$allows"
fi

# send-keys 有沒有 agent_blocked 這種內建保護未實測，見檔頭說明；這一
# 行的設計不依賴它有或沒有。
eo_herdr agent send-keys "$target" "$key" >/dev/null

# 依 --startup 決定接受哪些落點，見檔頭「兩種模式等的都是『狀態已離開
# blocked』」說明。兩條分支等的性質相同（已離開 blocked），差別只在非
# 啟動階段多收一個 working。"done" 這個字面值必須加引號：不加的話
# 靜態檢查的解析器會把它誤判成 do/done 迴圈語法的收尾字（SC1010），
# 跟這裡單純是 --until 的一個字面值參數無關。這段註解也刻意不讓任何
# 一行以「# 加上工具名」開頭：那個形式會被當成 disable 指示詞解析，
# 本身就報 SC1072／SC1073。
if [ "$startup" -eq 1 ]; then
  wait_until_args=(--until idle --until "done")
else
  wait_until_args=(--until idle --until "done" --until working)
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
if err_output="$(herdr agent wait "$target" "${wait_until_args[@]}" \
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
    # 只轉發 error.code 與 error.message 兩個純字串欄位，不轉發
    # err_output 整包：herdr 的回應可能整包帶著 terminal_title 這類模
    # 型產出文字的載體，一旦轉發到這裡，就會直接進入呼叫端（編排端）
    # 的 context，而編排端的 context 純度正是這裡要保護的東西。已對真
    # 實 herdr 0.8.2 唯讀查證：`agent get` 對不存在目標的錯誤酬載是扁
    # 平的，只有 error.code／error.message／id 三個欄位，不帶 agent 物
    # 件；`agent wait` 的正常回應則整包帶著 agent 物件（因此也帶著
    # terminal_title／terminal_title_stripped，見上方檔頭）。但
    # `agent_blocked` 這一類錯誤酬載會不會也帶 agent 物件未查證——要
    # 製造一個 blocked 的 agent 本身就是副作用，沒有無副作用的探測手
    # 段可用。因此不逐一查證每種錯誤碼的酬載形狀，改採結構性做法：只
    # 白名單擷取 code 與 message，其餘欄位一律不觸碰。兩個欄位任一取
    # 不到都給明確的替代字串，不靜默留空、也不因此退回轉發原文——退
    # 回原文等於這裡的收斂沒有意義。
    error_message="$(printf '%s' "$err_output" | jq -r '.error.message // empty' 2>/dev/null || true)"
    [ -n "$error_code" ] || error_code="(無法取得 error.code)"
    [ -n "$error_message" ] || error_message="(無法取得 error.message)"
    eo_die 6 "press-approval.sh: herdr 以結束碼 1 拒絕 agent wait（target=$target），錯誤碼非逾時類：code=$error_code message=$error_message"
    ;;
esac
