#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/phase-status.sh
#
# 用法：phase-status.sh [<sub-issue 編號>] [--explain]
#
# 省略 <sub-issue 編號> 時查狀態檔內全部 phase；指定時只查那一個。
# 每個 phase 印一行：
#   phase=<編號> status=<agent_status> seq=<state_change_seq>
# 帶 --explain 時，每個 phase 的狀態行後面再多印一行：
#   rule=<規則名>
# 這是 herdr 對該 pane 的分類判定用的規則 id，供呼叫端判斷 UNCLASSIFIED
# 的成因（不是模型自己說了什麼，是 herdr 偵測引擎自己的規則名稱）。
#
# 省略編號的「查全部」模式：某個 phase 查不到就在它那一行印
# `phase=<編號> status=ERROR seq=- rc=<結束碼>`，繼續處理下一個 phase，
# 全部處理完後只要有任何一個失敗就以 1 結束（1 不在下面的結束碼對照
# 表裡，是本腳本自己的擴充：對照表其餘各碼都對應「單一失敗、整支腳本
# 立刻結束」，但查全部模式允許部分成功、部分失敗，需要一個跟那些單一
# 失敗碼不同、專門代表「至少一個 phase 失敗」的聚合碼）。這麼做是因為
# 呼叫端之一是事件產生器的低頻掃描：一個記錄過期的 phase 若讓整支腳本
# 立刻中止，其餘還在跑的 phase 會整批從那一輪掃描的輸出裡消失，等於把
# 這個專案本來要修的「監控視野漏判」複製一份到查詢層。查單一 phase（有
# 給編號）不受此影響，維持原本的失敗即以該次失敗的結束碼結束——單一
# phase 沒有「其他 phase 還要繼續看」這回事。
#
# ---- 安全：絕不轉發 herdr 的原始回應 ----
# 本腳本的存在理由是把 herdr 回應「消毒」過再交給呼叫端（呼叫端是會把
# stdout 整段讀進 context 的模型）。因此輸出只能是自己用 jq 逐欄位組
# 出來的白名單結果，不能是「herdr 原始回應剝掉幾個具名欄位」——那種做
# 法只要漏列一個欄位就會外洩，而承載模型／使用者產出文字的出口不只一
# 處，用排除法列舉才不會漏：
#   1. `api snapshot` 每個 agent 條目的 terminal_title：原始視窗標題，
#      內容通常是使用者或模型自己下的（例：任務描述、issue 標題）。已對
#      真實 herdr 0.8.2 查證：一個 agent 條目實際共有 15 個欄位，
#      terminal_title 與下面第 2 項的 terminal_title_stripped 就是其中
#      兩個模型文字載體（另外 13 個是 agent、agent_session、
#      agent_status、cwd、focused、foreground_cwd、pane_id、revision、
#      state_change_seq、tab_id、terminal_id、tokens、workspace_id，
#      都不帶模型產出文字）。
#   2. 同一條目的 terminal_title_stripped：同一份文字，只是去掉前綴符
#      號，一樣是使用者／模型產出，不是本腳本能安全轉發的欄位。
#   3. `herdr agent explain` 回應中 evaluated_rules[].evidence 底下的
#      region_preview／contains 等欄位：畫面片段，內容就是螢幕上顯示
#      的文字，同樣可能是模型輸出。
#   4. `herdr agent wait` 與 `herdr agent prompt` 的回應也整包帶著同一個
#      agent 物件（因此也帶著 terminal_title／terminal_title_stripped）
#      ——本腳本雖然不呼叫這兩個子指令，但列在這裡是提醒之後任何人都
#      不能想當然爾地說「這個 herdr 子指令的回應看起來只是狀態，應該
#      能直接轉發」：目前已知會整包帶著模型文字的出口不只一種形狀。
# 因此本腳本只讀取 agent_status、state_change_seq、matched_rule.id 三
# 個白名單欄位；就算 herdr 未來在回應裡新增欄位，也不會被意外印出，因
# 為輸出本來就是白名單組出來的，不是原始回應扣掉黑名單。
#
# ---- 回應形狀：api snapshot 與 agent list 不一樣，別搞混 ----
# 已對真實 herdr 0.8.2 分別查證：`api snapshot` 的 agent 清單在
# `.result.snapshot.agents`，中間多一層 `snapshot`；`agent list` 的 agent
# 清單則是直接在 `.result.agents`，沒有那一層。兩者都用 `agents` 這個鍵
# 名，很容易誤用另一個指令的形狀去解析，取錯層一律安靜地得到 null 而不
# 是報錯。本腳本只用到 `api snapshot`，jq 路徑一律走
# `.result.snapshot.agents[]`。另外，agent 條目裡沒有任何欄位裝著
# phase 被指派的 agent 名稱：叫做 `agent` 的欄位裝的是種類（實測值為
# `claude`），不是名稱，所以只能靠狀態檔記的 pane_id 把一列對回某個
# phase（見下面的 process_phase）。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

explain=0
phase=""
for arg in "$@"; do
  case "$arg" in
    --explain)
      explain=1
      ;;
    -*)
      eo_die 2 "phase-status.sh: 未知選項：$arg"
      ;;
    *)
      if [ -n "$phase" ]; then
        eo_die 2 "phase-status.sh: 只能指定一個 sub-issue 編號"
      fi
      phase="$arg"
      ;;
  esac
done

# `api snapshot` 沒有伺服器端的 workspace 過濾參數（已對真實二進位查
# 證：`herdr api snapshot --help` 不接受任何選項），只能整包拿回來，
# 對全部要查的 phase 只呼叫這一次，下面逐 phase 用狀態檔記的 pane_id
# 從裡面挑出屬於自己的那一列。
snapshot="$(eo_herdr api snapshot)"

# process_phase <phase>
# 印出單一 phase 的狀態行（與 --explain 時的規則行）。內部任何一步失
# 敗都是直接呼叫 eo_die／exit，不回傳錯誤碼給呼叫端判斷——這是
# common.sh 全部函式一貫的設計，呼叫端要嘛讓它終止整個行程（單一
# phase 模式），要嘛把整次呼叫包進一支獨立子殼再看子殼的結束碼（查全
# 部模式，見下面的主流程），不能在同一個行程裡用 if 包這個函式再指望
# 攔到失敗——那樣會撞進 bash 的一個特性：一個函式呼叫只要是 if／
# while／&&／|| 的被測條件，errexit 在它整個執行期間（包含它內部再呼
# 叫的巢狀指令替換）都會被暫停，不是只暫停在最外層那一次判斷，已用獨
# 立探測腳本重現過：若直接 `if process_phase "$p"; then …`，內部某一
# 步的 eo_die 會被吃掉，函式會一路執行到最後一行印出錯的資料，而不是
# 提早中止。
process_phase() {
  local p="$1" pane_id tab_id row status seq explain_json rule

  pane_id="$(eo_state_get "$p" pane_id)"
  tab_id="$(eo_state_get "$p" tab_id)"

  # workspace 過濾：「本 workspace 為何」的判定集中在
  # eo_assert_workspace（來源是 HERDR_WORKSPACE_ID，見 common.sh），本
  # 腳本不對 snapshot 的 workspace_id 欄位另外做字串比對、不自己重新
  # 判定一次——那樣會有兩套各自獨立的『本 workspace』結論，一旦兩者
  # 來源不一致就會產生假陰性或假陽性。狀態檔裡的 tab_id 不通過這一關
  # 就視為記錄過期，以 4 結束。
  eo_assert_workspace "$tab_id"

  row="$(printf '%s' "$snapshot" | jq -c --arg pane "$pane_id" \
    '.result.snapshot.agents[]? | select(.pane_id == $pane)')"
  if [ -z "$row" ]; then
    eo_die 5 "phase-status.sh: pane $pane_id（phase $p）不在目前的 snapshot 裡"
  fi

  status="$(printf '%s' "$row" | jq -r '.agent_status')"
  seq="$(printf '%s' "$row" | jq -r '.state_change_seq')"
  printf 'phase=%s status=%s seq=%s\n' "$p" "$status" "$seq"

  if [ "$explain" -eq 1 ]; then
    explain_json="$(eo_herdr agent explain --format json "$pane_id")"
    # matched_rule 在偵測引擎判不出狀態（fallback）時可能是 null；
    # 用固定的哨兵字串「none」呈現，不是留白也不是印整個 fallback 物件。
    rule="$(printf '%s' "$explain_json" | jq -r '.matched_rule.id // "none"')"
    printf 'rule=%s\n' "$rule"
  fi
}

if [ -n "$phase" ]; then
  # 查單一 phase：失敗即結束，直接呼叫，讓 process_phase 內部的
  # eo_die／exit 原樣終止本腳本，結束碼就是那次失敗對應的碼。
  process_phase "$phase"
else
  # 查全部：對每個 phase 各自隔離失敗，不讓一個過期的記錄讓其餘還在
  # 跑的 phase 從輸出裡消失。
  #
  # 隔離手法：先 `set +e` 讓「這個子殼失敗」這件事本身不會觸發本腳本
  # 的 errexit（因為現在 -e 已經是關的，不需要靠 if／&&／|| 這種會連
  # 帶關掉子殼內部 errexit 的結構去測它），子殼一啟動立刻自己重新
  # `set -euo pipefail`，讓子殼內部（也就是 process_phase 真正執行的
  # 地方）的 errexit 是貨真價實開著的，第一個失敗的指令就會讓子殼提早
  # 結束、不會繼續往下印出錯的資料。子殼結束後立刻 `rc=$?`（這一步不
  # 是被測條件，單純讀值，不受上面提到的暫停規則影響），再把外層的
  # `set -e` 復原，供迴圈下一輪與迴圈結束後的程式碼使用。
  #
  # 列舉 phase 清單本身（`eo_state_phases`）刻意先用一般的指令替換賦
  # 值、餵進 here-string，不是製程替換（`< <(...)`）：製程替換的失敗
  # 不受 errexit 約束，狀態檔整個不存在時 `eo_state_phases` 會在裡面
  # 死掉，但迴圈只會安靜地讀到空輸入、印零行、以 0 結束，把「狀態檔缺
  # 漏」誤報成「目前沒有任何 phase」。一般賦值已在前面驗證過會正確傳
  # 播失敗結束碼。
  phases="$(eo_state_phases)"
  any_failed=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    set +e
    ( set -euo pipefail; process_phase "$p" )
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      any_failed=1
      printf 'phase=%s status=ERROR seq=- rc=%s\n' "$p" "$rc"
    fi
  done <<<"$phases"
  if [ "$any_failed" -ne 0 ]; then
    exit 1
  fi
fi
