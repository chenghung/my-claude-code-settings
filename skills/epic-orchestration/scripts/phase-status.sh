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
# ---- 安全：絕不轉發 herdr 的原始回應 ----
# 本腳本的存在理由是把 herdr 回應「消毒」過再交給呼叫端（呼叫端是會把
# stdout 整段讀進 context 的模型）。因此輸出只能是自己用 jq 逐欄位組
# 出來的白名單結果，不能是「herdr 原始回應剝掉幾個具名欄位」——那種做
# 法只要漏列一個欄位就會外洩，而承載模型／使用者產出文字的出口不只一
# 處，用排除法列舉才不會漏：
#   1. `api snapshot` 每個 agent 條目的 terminal_title：原始視窗標題，
#      內容通常是使用者或模型自己下的（例：任務描述、issue 標題）。
#   2. 同一條目的 terminal_title_stripped：同一份文字，只是去掉前綴符
#      號，一樣是使用者／模型產出，不是本腳本能安全轉發的欄位。
#   3. `herdr agent explain` 回應中 evaluated_rules[].evidence 底下的
#      region_preview／contains 等欄位：畫面片段，內容就是螢幕上顯示
#      的文字，同樣可能是模型輸出。
# 因此本腳本只讀取 agent_status、state_change_seq、matched_rule.id 三
# 個白名單欄位；就算 herdr 未來在回應裡新增欄位，也不會被意外印出，因
# 為輸出本來就是白名單組出來的，不是原始回應扣掉黑名單。

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

# 決定要查的 phase 清單：指定編號就只查那一個，否則查狀態檔內全部。
if [ -n "$phase" ]; then
  phases="$phase"
else
  phases="$(eo_state_phases)"
fi

# `api snapshot` 沒有伺服器端的 workspace 過濾參數（已對真實二進位查
# 證：`herdr api snapshot --help` 不接受任何選項），只能整包拿回來，
# 對全部要查的 phase 只呼叫這一次，下面逐 phase 用狀態檔記的 pane_id
# 從裡面挑出屬於自己的那一列。
snapshot="$(eo_herdr api snapshot)"

while IFS= read -r p; do
  [ -n "$p" ] || continue

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
    '.result.agents[]? | select(.pane_id == $pane)')"
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
done <<<"$phases"
