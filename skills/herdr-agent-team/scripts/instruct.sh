#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/instruct.sh
#
# 用法：
#   instruct.sh --to <worker> (--text <文字> | --text-file <路徑>) \
#     [--reply-to <序號>] [--kind instruct|decision|goal-update|halt]
#
# 職責（規格 §9「怎麼送」、§12）：orchestrator 下行唯一入口，一次只送
# 給一個 worker。
#
# ---- 送之前把收件 worker 標成持有中，送完（不論成功、blocked 或其他
#      拒絕）都要放掉 ----
# 已實測的失敗形狀：兩則下行被併進同一個回合一起執行——一則「繼續」黏
# 在一則 goal 更新後面送達時，worker 讀到的是混合意圖，而兩則訊息都沒
# 有掉、從外面看起來一切正常。持有旗標的語意是「orchestrator 正在跟這
# 個 worker 對話」：看門狗（Task 12）看到它為真就不會自動推進，那個空
# 窗期就不會有第三則訊息插進來。本腳本因此在送出之前把 .held 設成
# true，並在所有離開路徑（成功、blocked、其他 herdr 拒絕、語法錯誤）
# 都放掉，不留任何一條會讓旗標卡在 true 的路徑。
#
# ---- 一律不握手 ----
# 收件的 worker 多半還在做事，對做事中的對象沒有任何短握手可用：已實
# 測帶著等待選項對一個做事中的 agent 送出，會在十秒後逾時、結束碼 1，
# 但訊息其實送到了、該回合結束後就執行了；不帶等待選項則要等完整個回
# 合，實測十二秒，真實情境是幾小時。照握手做的後果是每一則各逾時一
# 次、各誤判成失敗一次、各白派一個調查者。本腳本的投遞呼叫因此絕對不
# 加 --wait／--until／--timeout。
#
# ---- blocked 是待補送，不是失敗；其餘拒絕才是真正的失敗 ----
# herdr 會直接拒絕送給一個卡在核准框的對象（error.code=agent_blocked）。
# 這一則沒有送到，而外部世界沒有任何地方查得到「有一則該送而還沒送到
# 的下行」——它不寫進狀態記錄就等於不存在，後果是靜默的：那個 worker 永
# 遠不知道目標改過，繼續照舊的建東西，一路正常，直到整合時才炸。因此
# agent_blocked 時把這一則加進該 worker 的 pending_resend 清單、放掉持
# 有旗標，以 7 結束（不是失敗，是待補送）。
#
# 其餘拒絕（例如目標名稱根本不存在）不進待補送清單：那個目標可能永遠
# 不會離開拒絕狀態，進了清單只會讓看門狗（Task 12）每一輪都白補投一次
# 注定失敗的對象。因此不透過 hat_herdr——它把 herdr 結束碼 1 一律映射
# 成 6，會把「agent_blocked（待補送）」跟「其他真正的拒絕（同樣是 6，
# 但語意不同）」混成同一碼，本腳本需要在兩者之間分岔；沿用
# launch-worker.sh 對同一類問題的既有手法，自己擷取 stderr 解析
# error.code，不假手 hat_herdr。
#
# ---- .pending_resend 有兩個寫入端，兩者共用 common.sh 的單一加鎖 jq
#      轉換實作 ----
# 這一則加入清單由本腳本做，補投成功後移除那一則由看門狗（Task 12）
# 做，兩者是同一個欄位的兩個獨立寫入端。common.sh「寫入端分邊，欄位集
# 合刻意不重疊」那份分配表原本沒有把 .pending_resend 分配給任何一邊
# （這是計畫的疏漏，已在修正迴圈第一輪的裁決記錄），所以不重疊的約定
# 在它身上不成立，必須換一個保證：對它的每一次變動都表達成「一次
# flock 加鎖區間內完成的單一 jq 轉換」——讀現有內容與算新內容都在同一
# 次 jq 呼叫裡對來源檔案求值，不能先用一次 jq 呼叫把陣列讀出到 shell
# 變數、算完新陣列、再用 hat_json_set 另開一次加鎖呼叫寫回去。後者是兩
# 次獨立的加鎖呼叫，中間那個沒有鎖保護的空窗，剛好就是另一個寫入端
#（看門狗的移除）會插進來的地方；兩個方向的結果都是靜默的資料遺失，正
# 是規格 §13 講的「該送而還沒送到的下行，外部世界沒有任何地方查得到」
# 那件事。Task 12 的前置整理已把這個共用實作（`_hat_pending_resend_
# apply`）與加入／移除兩個入口（`hat_append_pending_resend`／
# `hat_remove_pending_resend`）一併移進 lib/common.sh，本腳本改為直接
# 呼叫共用函式庫的 `hat_append_pending_resend`，不再自己定義。
#
# ---- --reply-to：回覆定案，順手標記已處理 ----
# 上層重啟之後 context 全沒了，它收到過的訊息也一起沒了，所以「哪些上
# 行還沒處理」必須落在磁碟上。設計刻意不要求上層多呼叫一支標記腳
# 本——那是它會忘記做的事，改成讓標記從它本來就會做的動作掉出來：回覆
# 某則定案時順手標掉那一則。
#
# 這一步（寫 replies/<worker>/<seq>.json、標記
# inbox/<seq>-<worker>.json 的 processed_at）是純檔案系統操作，跟後面
# 這一則下行是否送達無關，因此排在投遞之前執行、且不受投遞結果影響：
# 就算後面的投遞被 blocked 甚至被拒絕，這則決議本身已經定案且已經
# durable 落地，report.sh 阻塞中的輪詢（直接檢查檔案是否存在，不經過
# herdr）能立刻讀到，不需要等這次投遞的結果。
#
# replies/ 底下每個檔案只會被本腳本寫入恰好一次（seq 全域唯一且單
# 調），但它有一個 details/ 沒有的性質：worker 端的 report.sh 正在主動
# 輪詢這個檔案是否存在，若這裡用一般的 `>` 直接寫、寫到一半失敗，會被
# 輪詢中的 worker 讀到一個殘缺檔案並當成正常回覆吃下去——比完全沒寫更
# 糟。因此改用 mktemp → jq 產生內容 → mv 置換的三步，跟 hat_json_set／
# hat_allocate_seq 對「有並行讀者」的檔案的既有處理方式一致；details/
# 沒有這個並行讀者，才維持 report.sh 原本較簡單的 cp 寫法，兩者的落
# 差是刻意的，不是遺漏。
#
# ---- 一次只接受一個收件人 ----
# goal 傳播時，每個角色收到的是「這次改動對你這一份的影響」，不是整段
# 變更紀錄；收件端是 worker，它只看得到自己那個角色，判不出哪一段跟自
# 己有關。逐一送，由呼叫端（orchestrator）對每個受影響的角色各呼叫一
# 次，本腳本的 --to 因此只接受單一個名稱。
#
# ---- 入口守衛：hat_assert_workspace 用在既有 target 上 ----
# 本腳本接受呼叫端傳入的既有 target（worker 已註冊的座標），不像
# launch-worker.sh 自己建立新座標；套用方式沿用 skills/epic-
# orchestration/scripts/send-to-phase.sh 對同一類「既有 target」的既有
# 手法：從 registry 讀出這個 worker 的 pane_id，對它斷言屬於本
# workspace，早於任何 herdr 呼叫。三道 workspace 守衛裡唯一擋得住「誤
# 觸別的 team 的 worker」的一道。
#
# ---- --kind 是下行訊息的種類標記，跟 provider 的 agent kind 是完全不
#      同的命名空間 ----
# hat_assert_supported_kind／hat_kind_fidelity 判斷的是 claude／codex／
# agy／opencode 這四種 CLI provider；這裡的 --kind（instruct／
# decision／goal-update／halt）標記的是這一則下行訊息本身的種類，只用
# 於：(a) 進 pending_resend 清單時一併記錄，供 Task 12 的看門狗補投時
# 知道這是哪一種訊息；(b) 白名單外一律拒絕。不影響送出的文字內容本
# 身——文字內容一律是 --text／--text-file 給的原文，本腳本不替四種
# kind 分別組不同格式的訊息（規格與可觸及的任務簡報都沒有規定 worker
# 端要怎麼從純文字辨識 kind，只有 pending_resend 這個內部記錄需要它；
# 這是本次實作的判斷，回報見任務報告）。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／set-goal.sh／launch-worker.sh 的同名局部函式：各腳本各自
# 獨立定義，不共用（理由見 set-goal.sh 檔頭）。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

to="" text="" text_file="" reply_to="" kind="instruct"
have_to=0 have_text=0 have_text_file=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --to 缺值"
      to="$2"; have_to=1; shift 2 ;;
    --text)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --text 缺值"
      text="$2"; have_text=1; shift 2 ;;
    --text-file)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --text-file 缺值"
      text_file="$2"; have_text_file=1; shift 2 ;;
    --reply-to)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --reply-to 缺值"
      reply_to="$2"; shift 2 ;;
    --kind)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --kind 缺值"
      kind="$2"; shift 2 ;;
    *)
      hat_die 2 "instruct.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_to" -ne 1 ]; then
  hat_die 2 "instruct.sh: --to 為必填"
fi

if [ "$have_text" -eq 1 ] && [ "$have_text_file" -eq 1 ]; then
  hat_die 2 "instruct.sh: --text／--text-file 只能擇一"
fi
if [ "$have_text" -ne 1 ] && [ "$have_text_file" -ne 1 ]; then
  hat_die 2 "instruct.sh: --text／--text-file 必須擇一"
fi

if [ -n "$reply_to" ]; then
  case "$reply_to" in
    '' | *[!0-9]*)
      hat_die 2 "instruct.sh: --reply-to 必須是純數字序號，收到：$reply_to" ;;
  esac
fi

# ---- --kind 白名單：見檔頭「--kind 是下行訊息的種類標記」一節 ----
case "$kind" in
  instruct | decision | goal-update | halt) : ;;
  *) hat_die 2 "instruct.sh: 不支援的 --kind '$kind'：只接受 instruct、decision、goal-update、halt 四個" ;;
esac

if [ "$have_text_file" -eq 1 ]; then
  [ -f "$text_file" ] || hat_die 2 "instruct.sh: --text-file 指向的檔案不存在：$text_file"
  text="$(cat "$text_file")"
fi

registry_root="$(hat_registry_root)"
worker_file="$registry_root/workers/$to.json"

# ---- 入口守衛：對這個既有 target 的座標斷言屬於本 workspace，早於任
#      何 herdr 呼叫（見檔頭「入口守衛」一節）----
pane_id="$(hat_json_get "$worker_file" '.pane_id')"
hat_assert_workspace "$pane_id"

# ---- --reply-to：回覆定案並順手標記已處理，早於投遞、不受投遞結果影
#      響（見檔頭「--reply-to」一節）----
if [ -n "$reply_to" ]; then
  inbox_file="$registry_root/inbox/${reply_to}-${to}.json"
  if [ ! -f "$inbox_file" ]; then
    hat_die 5 "instruct.sh: --reply-to 指名的 inbox 記錄不存在：$inbox_file"
  fi

  reply_dir="$registry_root/replies/$to"
  mkdir -p "$reply_dir"
  reply_file="$reply_dir/$reply_to.json"
  tmp_reply="$(mktemp "${reply_file}.XXXXXX")" || hat_die 5 "instruct.sh: 無法建立暫存檔，回覆未寫入：$reply_file"
  if ! { jq -n --arg d "$text" '{decision: $d}' > "$tmp_reply" && mv "$tmp_reply" "$reply_file"; }; then
    rm -f "$tmp_reply"
    hat_die 5 "instruct.sh: 回覆檔寫入失敗：$reply_file"
  fi

  processed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hat_json_set "$inbox_file" '.processed_at' "$(hat_json_string "$processed_at")"
fi

# ---- 送之前設持有旗標（見檔頭同名一節）----
hat_json_set "$worker_file" '.held' 'true'

# ---- 投遞：不透過 hat_herdr，理由見檔頭「blocked 是待補送」一節 ----
rc=0
if err_output="$(herdr agent prompt "$to" "$text" 2>&1 >/dev/null)"; then
  :
else
  rc=$?
fi

if [ "$rc" -eq 0 ]; then
  hat_json_set "$worker_file" '.held' 'false'
  exit 0
fi

error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
error_message="$(printf '%s' "$err_output" | jq -r '.error.message // empty' 2>/dev/null || true)"
[ -n "$error_code" ] || error_code="unknown_error"
[ -n "$error_message" ] || error_message="(herdr 未提供可解析的錯誤訊息)"

if [ "$rc" -eq 2 ]; then
  hat_json_set "$worker_file" '.held' 'false'
  hat_die 2 "instruct.sh: herdr 以結束碼 2 拒絕 agent prompt，疑似腳本呼叫語法錯誤（worker=$to）：code=$error_code message=$error_message"
fi

if [ "$error_code" = "agent_blocked" ]; then
  # ---- agent_blocked：進待補送清單，不是失敗（見檔頭「blocked 是待補
  #      送」與「.pending_resend 有兩個寫入端」兩節）----
  hat_append_pending_resend "$worker_file" "$text" "$kind"
  hat_json_set "$worker_file" '.held' 'false'
  printf '已記錄、待補送：worker %s 目前卡在核准框，看門狗會在解除後補投\n' "$to"
  exit 7
fi

# ---- agent_blocked 以外的拒絕：真正的失敗，不進待補送清單（見檔頭
#      「blocked 是待補送」一節）----
hat_json_set "$worker_file" '.held' 'false'
hat_die 6 "instruct.sh: herdr 拒絕 agent prompt（worker=$to）：code=$error_code message=$error_message"
