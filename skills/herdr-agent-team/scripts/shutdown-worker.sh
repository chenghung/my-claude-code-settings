#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/shutdown-worker.sh
#
# 用法：
#   shutdown-worker.sh --to <worker> --reason <done|abandon|superseded> \
#     [--evidence <外部可查證的事實>] [--handoff-file <路徑>]
#
# 職責（規格 §11、§12 的 `shutdown` 動作）：關閉一個 worker——不可逆，
# 不支援 resume。
#
# ---- 為什麼證據是必填的，不是選填的品質建議 ----
# 這個設計刻意放棄 resume：關掉一個 worker 就是丟掉它整個 session，回
# 不去。全部重量因此壓在關閉前這一次確認上，而上層看不到 worker 實際
# 做了什麼，「完成」不能靠自我宣告，證據必須是外部查得到的事實
# （`--reason done` 帶 `--evidence`）。放棄或被取代的情形則反過來：交
# 接檔（`--handoff-file`）往往比完成證明更有價值——工作隔離區裡已經做
# 好的部分，接手的人拿得到，那些東西本來會隨 session 一起消失。兩者都
# 缺席以 2 結束（呼叫端用錯，不是守衛不通過），因為這是純粹的參數完整
# 性問題，不需要碰 registry 就能判斷。
#
# ---- 交付點不等於終點：`delivered` 關卡不得走本腳本 ----
# 產物可以給人用了，不代表不會再有工作——review 回來要改就回到執行
# 中。生命週期是 `running → delivered →（可回到 running）→ closing →
# closed`，本腳本只負責最後一段（closing → closed），`delivered` 這個
# 中繼站必須先被別的動作（不在本任務範圍）撥回 `running` 才能走到這
# 裡。以 4 結束（守衛不通過），不是 2：呼叫端沒有用錯任何參數，是這個
# worker 現在的狀態不允許關閉。
#
# ---- 「有人正在等它就拒絕」：兩個條件都要是查得到的形式 ----
# 兩個條件都只看磁碟上已經有的紀錄，不用問任何人：
#   一、它自己有未回覆的 need-you——inbox/ 裡屬於它、token 是
#      need-you、且 processed_at 仍是 JSON null 的紀錄。掃過去比對
#      `.worker` 欄位，不解析檔名裡的 worker 名稱：worker 名稱本身可能
#      含連字號，從檔名 `<seq>-<worker>.json` 反推容易切錯。
#   二、別的 worker 的 `.grants` 清單還指向它。**`.grants` 欄位不存在
#      一律視為空陣列（`// []`），不得因缺欄位而失敗**——registry 是逐
#      步長出來的，這支腳本（Task 10）會在 grant 功能（Task 11）存在
#      之前就先完成，Task 11 之前建立的每一個 worker 記錄都沒有這個欄
#      位，若因此判定失敗，等於這支腳本在自己的功能上線前完全無法使
#      用。兩者任一成立以 4 結束。
#
# ---- 參與檔案鎖協定：整段關閉序列全程持有該 worker 記錄的檔案鎖
#      （修正迴圈第一輪裁決）----
# `watchdog.sh`（後續任務）會透過 `hat_json_set` 對同一個 `workers/
# <name>.json` 做讀-改-寫，而 `hat_json_set` 走的是「每個檔案一把鎖」
# 的序列化模型（鎖檔路徑 `<file>.lock`，見 common.sh 該函式檔頭）。本
# 腳本若不參與同一個協定，會出現這個具體的競態：`watchdog.sh` 已經讀出
# 舊內容、正要把新內容置換回去的空檔裡，若本腳本這段關閉序列（讀取記
# 錄、`tab close`、歸檔、移除記錄）整段插進來完成，`watchdog.sh` 隨後
# 那次遲到的置換會把一筆已經永久關閉的記錄原地復活——一個 session 已
# 經被丟掉的 worker 又出現在清單上，且看起來是正常在途的。這與本腳本
# 「不可逆、不支援 resume」的核心前提直接牴觸：一個能被復活的「不可
# 逆」動作等於沒有不可逆。
#
# 修法是從讀取記錄開始，一路持有 `${worker_file}.lock` 這把鎖到最後移
# 除記錄為止，寫法沿用 `hat_json_set` 自己的既有慣用手法（`exec
# {fd}>"$lock_file"; flock -x "$fd"`）、鎖檔路徑也用同一條，這樣兩邊搶
# 的才是同一把鎖，不是各自序列化、彼此不排隊（那等於沒鎖，跟
# `instruct.sh` 檔頭「`.pending_resend` 有兩個寫入端」一節點出的教訓同
# 一個成因）。移除記錄時（見下方成功路徑）連同它的鎖檔一併移除，不留
# 下指不到任何現存記錄的孤兒鎖檔。
#
# 這只解決「讀出舊內容之後才被插入」這一半；另一半（鎖內置換前重查目
# 標檔是否還存在，不存在就大聲失敗而不是照樣置換）由 `watchdog.sh` 那
# 個任務在 `hat_json_set` 自己那一側補上，兩道一起擋住同一個競態的兩
# 端，不在本腳本的職責範圍內。
#
# ---- 三道守衛全過才 `tab close`；close 失敗要留著記錄 ----
# 三道守衛依序是：入口的 workspace 邊界（見下方「入口守衛」一節）、
# 「有人正在等它」（上一節）、`delivered` 關卡（上上節）。全部通過之後
# 才呼叫 `herdr tab close`，而且這個呼叫刻意用裸陳述句（不接指令替
# 換）：`hat_herdr` 對失敗的映射（herdr 拒絕→6，語法錯誤→2 原樣保留）
# 會透過本檔開頭 `set -euo pipefail` 的 errexit 直接終止整支腳本，此時
# 一行 registry 寫入都還沒發生——`workers/<name>.json` 完全沒被動到，
# 下一次呼叫還找得到同一個 tab_id。這不是巧合，是刻意的順序：所有會改
# 變 registry 的動作（歸檔）都排在 `tab close` 之後，讓「關閉失敗」與
# 「記錄消失」在結構上不可能同時發生，不需要額外的復原程式碼。這段期
# 間鎖全程持有著，`errexit` 觸發的行程結束會自動關閉鎖用的檔案描述
# 符、釋放鎖，不需要額外的 trap 或明確的解鎖呼叫。
#
# `tab close` 成功之後，把 `workers/<name>.json` 的內容外加
# `reason`／`evidence`／`handoff_file`／`closed_at` 四個欄位一起寫進
# `handoff/<name>.json` 歸檔（這四個欄位是本次實作的判斷：`--evidence`
# 存在的唯一理由是留下可查證的關閉依據，若歸檔時把它丟掉，這個必填欄
# 位就只在呼叫的當下有意義、事後審查者手上什麼都拿不到，判斷與理由見
# 任務報告），再移除 `workers/<name>.json` 本體。這兩步之間有一個未涵
# 蓋的窗口（annotate 後的內容已經寫進 handoff/、但原始 workers/ 檔案還
# 沒刪除，若腳本這時被中止會同時存在兩份），窗口很窄且後果是重複而非
# 遺失，此腳本重跑一次會在 `tab close` 這一步被 herdr 拒絕（tab 已經
# 關過）而以 6 結束、不會再往下動任何檔案；記錄見任務報告。
#
# 若 `--handoff-file` 有給，同一時間把它的內容複製進
# `handoff/<name>.md`（`--reason abandon`／`superseded` 必填，`done`
# 選填但若給了照樣複製，不特別限制）——跟 `report.sh` 複製
# `--detail-file` 進 `details/` 是同一個理由：呼叫端給的路徑可能是暫存
# 檔，也可能事後被改掉或刪掉，registry 只留副本才能保證事後還查得到。
#
# ---- 入口守衛：名稱格式驗證早於組路徑，workspace 邊界早於任何 herdr
#      呼叫 ----
# `--to` 會被直接用來組 `workers/<--to>.json` 這條 registry 路徑；含斜
# 線或上層目錄記號的值可以組出跳脫 registry 根目錄的路徑，因此先過
# `hat_assert_agent_name`（不合格式以 2 結束），再讀出這個 worker 的
# `pane_id` 對它斷言屬於本 workspace（不屬於以 4 結束）——跟
# `press-approval.sh`／`instruct.sh` 對「既有 target」的既有手法一致，
# 且早於本腳本會呼叫的任何 herdr 子指令（`tab close`）。
#
# ---- 不加 --dry-run ----
# 本腳本執行的是整個 skill 裡最不可逆的動作，理當是最需要 dry-run 的
# 候選；但沒有加，理由跟 `press-approval.sh` 拒絕加 dry-run 是同一個：
# 三道守衛（必填證據／交接檔、有人在等就拒絕、delivered 關卡）已經是
# 比通用 dry-run 更貼題的安全機制——它們強迫呼叫端在呼叫當下就把「憑什
# 麼現在關」講清楚並通過查證，而不是先乾跑一次看看會不會被擋、再决定
# 要不要真的關。介面簽章也是任務簡報逐字給定的固定形式
#（`--to`／`--reason`／`--evidence`／`--handoff-file` 四項），不添加簡
# 報沒有要求的選項。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／instruct.sh／set-goal.sh／launch-worker.sh 的同名局部函
# 式：各腳本各自獨立定義，不共用。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

# hat_need_you_pending <registry_root> <to>
# <to> 在 inbox/ 裡有沒有屬於自己、token 是 need-you、且 processed_at
# 仍是 JSON null 的紀錄（見檔頭「有人正在等它就拒絕」一節條件一）。找
# 到就印 "1"，否則印 "0"；印出值而非結束碼，因為呼叫端只需要一個布林
# 判斷，不需要額外的失敗語意。
hat_need_you_pending() {
  local registry_root="$1" to="$2" f token who processed

  while IFS= read -r -d '' f; do
    token="$(jq -r '.token // empty' "$f")"
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "need-you" ] && [ "$who" = "$to" ] && [ "$processed" = "null" ]; then
      printf '1\n'
      return 0
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '0\n'
}

# hat_grant_points_to <registry_root> <to>
# 掃過 workers/ 底下每一筆記錄的 .grants 清單，是否有任何一筆指向
# <to>（見檔頭「有人正在等它就拒絕」一節條件二）。欄位不存在一律視為
# 空陣列（`// []`），不得因缺欄位而失敗。找到就印 "1"，否則印 "0"。
hat_grant_points_to() {
  local registry_root="$1" to="$2" f hit

  while IFS= read -r -d '' f; do
    hit="$(jq -r --arg t "$to" '(.grants // []) | any(. == $t)' "$f")"
    if [ "$hit" = "true" ]; then
      printf '1\n'
      return 0
    fi
  done < <(find "$registry_root/workers" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '0\n'
}

to="" reason="" evidence="" handoff_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "shutdown-worker.sh: --to 缺值"
      to="$2"; shift 2 ;;
    --reason)
      [ "$#" -ge 2 ] || hat_die 2 "shutdown-worker.sh: --reason 缺值"
      reason="$2"; shift 2 ;;
    --evidence)
      [ "$#" -ge 2 ] || hat_die 2 "shutdown-worker.sh: --evidence 缺值"
      evidence="$2"; shift 2 ;;
    --handoff-file)
      [ "$#" -ge 2 ] || hat_die 2 "shutdown-worker.sh: --handoff-file 缺值"
      handoff_file="$2"; shift 2 ;;
    *)
      hat_die 2 "shutdown-worker.sh: 未知參數 '$1'" ;;
  esac
done

if [ -z "$to" ]; then
  hat_die 2 "shutdown-worker.sh: --to 為必填"
fi
if [ -z "$reason" ]; then
  hat_die 2 "shutdown-worker.sh: --reason 為必填"
fi

# ---- --reason 白名單 ----
case "$reason" in
  done | abandon | superseded) : ;;
  *)
    hat_die 2 "shutdown-worker.sh: 不支援的 --reason '$reason'：只接受 done、abandon、superseded 三個" ;;
esac

# ---- 必填證據／交接檔：純參數完整性檢查，不需要碰 registry（見檔頭
#      「為什麼證據是必填的」一節）----
if [ "$reason" = "done" ] && [ -z "$evidence" ]; then
  hat_die 2 "shutdown-worker.sh: --reason done 必須帶 --evidence（外部可查證的事實），缺席拒絕：關閉前的這一次確認是唯一的把關點"
fi

if { [ "$reason" = "abandon" ] || [ "$reason" = "superseded" ]; } && [ -z "$handoff_file" ]; then
  hat_die 2 "shutdown-worker.sh: --reason $reason 必須帶 --handoff-file（含殘留隔離區的處置），缺席拒絕：交接檔的價值往往比完成證明更高，讓接手的人拿得到已經做過的部分"
fi

if [ -n "$handoff_file" ] && [ ! -f "$handoff_file" ]; then
  hat_die 2 "shutdown-worker.sh: --handoff-file 指向的檔案不存在：$handoff_file"
fi

# ---- 名稱格式驗證早於組 registry 路徑（見檔頭「入口守衛」一節）----
hat_assert_agent_name "$to"

registry_root="$(hat_registry_root)"
worker_file="$registry_root/workers/$to.json"
lock_file="${worker_file}.lock"

# ---- 整段關閉序列參與 hat_json_set 既有的「每個檔案一把鎖」協定（見
#      檔頭「參與檔案鎖協定」一節）：從這裡讀取記錄開始，一路持有到最
#      後關閉 tab、歸檔、移除記錄為止，鎖檔路徑跟 hat_json_set 用的同
#      一條（`<file>.lock`），寫法也沿用同一個慣用手法（`exec
#      {fd}>"$lock_file"; flock -x "$fd"`），才會跟 watchdog.sh 未來對
#      同一個檔案的 hat_json_set 呼叫排隊，不是各自序列化、彼此不排隊
#      （那等於沒鎖）----
lock_fd=""
exec {lock_fd}>"$lock_file"
flock -x "$lock_fd"

# ---- 入口守衛：workspace 邊界，早於任何 herdr 呼叫 ----
pane_id="$(hat_json_get "$worker_file" '.pane_id')"
hat_assert_workspace "$pane_id"

# ---- 守衛一：有人正在等它就拒絕（兩個條件，見檔頭同名一節）----
if [ "$(hat_need_you_pending "$registry_root" "$to")" = "1" ]; then
  hat_die 4 "shutdown-worker.sh: worker '$to' 自己還有未回覆的 need-you，有人正在等它決議，拒絕關閉"
fi

if [ "$(hat_grant_points_to "$registry_root" "$to")" = "1" ]; then
  hat_die 4 "shutdown-worker.sh: 還有其他 worker 的 .grants 清單指向 '$to'，有人正在等它，拒絕關閉"
fi

# ---- 守衛二：delivered 關卡不得走本腳本（見檔頭同名一節）----
stage="$(jq -r '.stage // empty' "$worker_file")"
if [ "$stage" = "delivered" ]; then
  hat_die 4 "shutdown-worker.sh: worker '$to' 目前處於 delivered 關卡——交付點不等於終點，review 回來要改就回到執行中，拒絕在這裡關閉"
fi

# ---- 三道守衛全過，關閉 tab；失敗直接透過 errexit 終止，此時
#      workers/$to.json 完全沒被動到（見檔頭「三道守衛全過才 tab
#      close」一節）----
tab_id="$(hat_json_get "$worker_file" '.tab_id')"
hat_herdr tab close "$tab_id" >/dev/null

# ---- close 成功後才做的兩件事：交接檔複製、記錄歸檔（見檔頭同名一
#      節）----
if [ -n "$handoff_file" ]; then
  if ! cp "$handoff_file" "$registry_root/handoff/$to.md"; then
    hat_die 5 "shutdown-worker.sh: tab 已關閉，但交接檔複製失敗：$handoff_file -> $registry_root/handoff/$to.md"
  fi
fi

closed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
evidence_json='null'
if [ -n "$evidence" ]; then
  evidence_json="$(hat_json_string "$evidence")"
fi
handoff_file_json='null'
if [ -n "$handoff_file" ]; then
  handoff_file_json="$(hat_json_string "$handoff_file")"
fi

tmp_handoff="$(mktemp "$registry_root/handoff/$to.json.XXXXXX")" || hat_die 5 "shutdown-worker.sh: tab 已關閉，但無法建立暫存檔，記錄未歸檔：$worker_file"
if ! jq --arg reason "$reason" --argjson evidence "$evidence_json" \
    --argjson handoff_file "$handoff_file_json" --arg closed_at "$closed_at" \
    '. + {reason: $reason, evidence: $evidence, handoff_file: $handoff_file, closed_at: $closed_at}' \
    "$worker_file" > "$tmp_handoff"; then
  rm -f "$tmp_handoff"
  hat_die 5 "shutdown-worker.sh: tab 已關閉，但記錄歸檔失敗（jq 轉換），workers/$to.json 保留原地：$worker_file"
fi
if ! mv "$tmp_handoff" "$registry_root/handoff/$to.json"; then
  rm -f "$tmp_handoff"
  hat_die 5 "shutdown-worker.sh: tab 已關閉，但記錄歸檔失敗（置換），workers/$to.json 保留原地：$worker_file"
fi

# ---- 移除記錄時連同它的鎖檔一併移除（見檔頭「參與檔案鎖協定」一
#      節）：這個 fd 已經持有的 flock 只綁在這個開啟的檔案描述上，跟檔
#      名本身脫鉤，unlink 掉 lock_file 不會讓目前這個行程失去它，也不
#      影響下面即將發生的行程結束——真正釋放要等到 fd 關閉或行程結
#      束；但 workers/ 目錄不會留下一個指不到任何現存記錄的孤兒鎖檔----
rm -f "$worker_file" "$lock_file"

printf 'to=%s reason=%s tab=%s closed\n' "$to" "$reason" "$tab_id"
exit 0
