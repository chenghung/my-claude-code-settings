#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/grant-peer.sh
#
# 用法：
#   grant-peer.sh --from <worker> --to <worker> [--revoke]
#
# 職責（規格 §10、§12）：orchestrator 端唯一的授權入口。
#
# ---- 授權就是揭露位址，不是另開一個開關 ----
# 寫在契約裡的「你只能找 B」是文字，模型不遵守也沒有錯誤訊息；不知道對
# 方叫什麼，就算想繞過腳本直接呼叫 herdr 也叫不到人。本腳本因此做兩件
# 事：一、把 --to 寫進 --from 的 `.grants` 清單（send-peer.sh 靠這個清
# 單放行，見該腳本檔頭）；二、下行告訴 --from 對方叫什麼名字、負責什
# 麼——**這段下行文字本身就是授權**，不是可有可無的禮貌通知。--revoke
# 只做前者：撤銷時沒有新位址要揭露，不需要再送一則通知。
#
# ---- 下行通知是 best-effort，不是本腳本成敗的判準 ----
# 真正生效、擋得住 send-peer.sh 的是 `.grants` 清單這個結構性事實；下行
# 通知只是讓 --from 這個 agent 知道有這個位址可用。若 --from 當下卡在
# 核准框或做事中拒絕文字輸入，清單已經真的寫入、`send-peer.sh` 已經放
# 行，通知送不到只印一句提示，不讓整支腳本以非 0 結束——不像
# `instruct.sh` 那樣把 `agent_blocked` 記進 `.pending_resend` 排隊重
# 試：那一份待補送清單是 orchestrator 下行指令專用的重試基礎設施，這裡
# 只是一則資訊性通知，多開一個重試路徑是簡報沒有要求的複雜度。
#
# ---- --from／--to 都要過 workspace 邊界守衛 ----
# 兩者都是「既有 target」：分別讀出各自的 pane_id 斷言屬於本
# workspace，早於任何 herdr 呼叫，也早於 `.grants` 的寫入。只驗其中一
# 邊會留下漏洞——例如可以把別的 team 的 worker 位址揭露給本 team 的
# worker。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_grant_add <file> <name>
# 在 <file>.lock 的鎖保護下，把 <name> 加進 <file> 的 `.grants` 陣列，
# 全程只用一次 jq 呼叫對來源檔案求值（讀現有內容與算新內容是同一次求
# 值），手法沿用 instruct.sh 的 hat_append_pending_resend。先移除既有的
# 同名項目再補回一個，確保重複 grant 同一個對象不會產生重複項目，也不
# 會因為 jq 的 `unique` 把整個陣列排序、打亂其他項目原有的順序。
hat_grant_add() {
  local file="$1" name="$2"
  local lock_fd tmp

  lock_fd=""
  exec {lock_fd}>"${file}.lock"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")" || hat_die 5 "grant-peer.sh: 無法建立暫存檔，grants 未寫入：$file"
  if ! { jq --arg n "$name" \
      '.grants = ((.grants // []) - [$n] + [$n])' \
      "$file" > "$tmp" && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    hat_die 5 "grant-peer.sh: 寫入失敗（jq 解析或置換未成功），grants 未寫入：$file"
  fi

  exec {lock_fd}>&-
  return 0
}

# hat_grant_remove <file> <name>
# 同上鎖與原子轉換手法，把 <name> 從 <file> 的 `.grants` 陣列移除。<name>
# 原本就不在清單裡是安全的無動作，不視為錯誤。
hat_grant_remove() {
  local file="$1" name="$2"
  local lock_fd tmp

  lock_fd=""
  exec {lock_fd}>"${file}.lock"
  flock -x "$lock_fd"

  tmp="$(mktemp "${file}.XXXXXX")" || hat_die 5 "grant-peer.sh: 無法建立暫存檔，grants 未撤銷：$file"
  if ! { jq --arg n "$name" \
      '.grants = ((.grants // []) - [$n])' \
      "$file" > "$tmp" && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    hat_die 5 "grant-peer.sh: 寫入失敗（jq 解析或置換未成功），grants 未撤銷：$file"
  fi

  exec {lock_fd}>&-
  return 0
}

from="" to="" revoke=0
have_from=0 have_to=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      [ "$#" -ge 2 ] || hat_die 2 "grant-peer.sh: --from 缺值"
      from="$2"; have_from=1; shift 2 ;;
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "grant-peer.sh: --to 缺值"
      to="$2"; have_to=1; shift 2 ;;
    --revoke)
      revoke=1; shift ;;
    *)
      hat_die 2 "grant-peer.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_from" -ne 1 ] || [ "$have_to" -ne 1 ]; then
  hat_die 2 "grant-peer.sh: --from／--to 兩項全部必填"
fi

# ---- 名稱格式驗證早於組 registry 路徑（全域約束，見 common.sh
#      hat_assert_agent_name 檔頭）----
hat_assert_agent_name "$from"
hat_assert_agent_name "$to"

registry_root="$(hat_registry_root)"
from_file="$registry_root/workers/$from.json"
to_file="$registry_root/workers/$to.json"

# ---- 入口守衛：--from／--to 都是既有 target，各自斷言屬於本
#      workspace，早於任何 herdr 呼叫、也早於 grants 的寫入（見檔頭
#      「--from／--to 都要過 workspace 邊界守衛」一節）----
from_pane_id="$(hat_json_get "$from_file" '.pane_id')"
hat_assert_workspace "$from_pane_id"

to_pane_id="$(hat_json_get "$to_file" '.pane_id')"
hat_assert_workspace "$to_pane_id"

if [ "$revoke" -eq 1 ]; then
  hat_grant_remove "$from_file" "$to"
  printf 'from=%s to=%s revoked\n' "$from" "$to"
  exit 0
fi

hat_grant_add "$from_file" "$to"

# ---- 下行通知：揭露 --to 的名字與職責，見檔頭「授權就是揭露位址」一
#      節。職責取自 registry 已知的 .role；缺席時只揭露名字，不阻塞整
#      個授權動作 ----
to_role="$(jq -r '.role // empty' "$to_file")"
if [ -n "$to_role" ]; then
  grant_message="你可以聯繫 $to（角色：$to_role）。凡是他答得出來、而 orchestrator 答不出來的問題，直接問他，不要繞道；但你們談定的東西若改變了雙方之間的介面，仍然要回報 orchestrator。"
else
  grant_message="你可以聯繫 $to。凡是他答得出來、而 orchestrator 答不出來的問題，直接問他，不要繞道；但你們談定的東西若改變了雙方之間的介面，仍然要回報 orchestrator。"
fi

# ---- 通知是 best-effort，見檔頭同名一節：grants 清單已經生效，通知送
#      不到不讓本腳本以非 0 結束 ----
rc=0
hat_herdr agent prompt "$from" "$grant_message" >/dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  printf '已授權：grants 清單已更新，但下行通知目前送不到 %s（可能忙碌中）。授權已生效，不影響 send-peer.sh 放行\n' "$from"
fi

printf 'from=%s to=%s granted\n' "$from" "$to"
exit 0
