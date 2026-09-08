#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/send-to-phase.sh
#
# 用法：send-to-phase.sh <sub-issue 編號> <文字> [--handshake-timeout <毫秒>] [--no-handshake]
#
# 對停下中的 phase 送出下行文字並嘗試取得「對方已接手」的憑據；對做事
# 中的 phase 廣播時改用 --no-handshake，不嘗試握手。
#
# ---- 呼叫形式：握手與送出併成同一次呼叫 ----
# 一律呼叫 `herdr agent prompt <TARGET> <TEXT> --wait --until working
# --timeout <毫秒>`，不是送完文字再補一次 herdr agent wait。TARGET 取
# 自狀態檔的 agent_name（由 start-phase.sh 寫入），TEXT 以雙引號包成
# 單一位置引數傳給 herdr——不包起來 shell 會在第一個空白處切開，可能
# 整條失敗，也可能只送出第一段而握手照樣回報成功，是無聲的錯誤。
#
# ---- 握手逾時預設 10000 毫秒，且不隨 phase 工作長度調整 ----
# 它等的是「對方接手了這則訊息」（herdr 觀測到狀態轉成 working），不是
# 「工作做完」，因此不論 phase 底下的工作要跑多久，這個逾時值都不變。
# event-generator.sh 低頻掃描用的 120000 毫秒是完全不同的另一個量
# （那個量的是「目標消失多久被發現」，跟「多快接手」無關），兩者不要
# 一起調。
#
# ---- --no-handshake：對做事中的對象沒有任何短握手可用 ----
# 已對真實 herdr 0.8.2 實測：對一個處於 working 的 agent 帶
# `--wait --until working --timeout 10000` 送出，10024 毫秒逾時、結束
# 碼 1，但訊息其實送到了，該回合結束後兩則指令都執行了；改成不帶
# --until（預設等 settled）則回傳成功，代價是等完整個回合（實測
# 12327 毫秒，真實情境是幾小時）。所以對做事中的對象沒有任何短握手可
# 用，只能送出即算。合併後廣播「main 動了」走這條，收件的每個 phase
# 都還在 working；照握手做，一次廣播給四個 phase 就是四次逾時、四次
# 誤判成握手失敗、四次白派調查者，外加四十秒阻塞。因此 --no-handshake
# 模式完全不帶 --wait／--until／--timeout，送出即回報，不等待任何狀態。
#
# ---- 結束碼與輸出 ----
#   取得憑據（herdr 成功回報，狀態已轉成 working）：印 `handshake=ok`，
#     以 0 結束。
#   herdr 拒絕（agent_blocked、agent_not_found 等非逾時類錯誤）：以 6
#     結束，不印 handshake= 行。
#   握手逾時或 agent_prompt_stalled：不當成失敗，印 `handshake=none`，
#     以 7 結束，交由呼叫端決定要不要派調查者判定對方是已接手在做事
#     還是卡住了。
#   --no-handshake：印 `handshake=skipped`，以 0 結束；herdr 若在送出
#     當下就拒絕（例如 agent_blocked），一樣以 6 結束——不因為選了
#     --no-handshake 就連送出本身失敗也吞掉。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

eo_require_herdr_env

if [ "$#" -lt 2 ]; then
  eo_die 2 "send-to-phase.sh: 缺少必填參數 <sub-issue 編號> <文字>"
fi
phase="$1"
text="$2"
shift 2

# 握手逾時預設 10000 毫秒（見上方註解），可用 --handshake-timeout 覆寫。
handshake_timeout_ms=10000
no_handshake=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --handshake-timeout)
      if [ "$#" -lt 2 ]; then
        eo_die 2 "send-to-phase.sh: --handshake-timeout 缺少值"
      fi
      handshake_timeout_ms="$2"
      shift 2
      ;;
    --no-handshake)
      no_handshake=1
      shift
      ;;
    *)
      eo_die 2 "send-to-phase.sh: 未知選項 $1"
      ;;
  esac
done

target="$(eo_state_get "$phase" agent_name)"

if [ "$no_handshake" -eq 1 ]; then
  # 不帶 --wait／--until／--timeout：對做事中的對象沒有短握手可用，
  # 送出即算。herdr 若在送出當下就拒絕（例如 agent_blocked），仍透過
  # eo_herdr 映射成 6，不因為選了 --no-handshake 就連這個也吞掉。
  eo_herdr agent prompt "$target" "$text" >/dev/null
  printf 'handshake=skipped\n'
  exit 0
fi

# 握手模式：不能用 eo_herdr——它把 herdr 結束碼 1 一律映射成 6，會把
# 「逾時／agent_prompt_stalled（未取得憑據，7）」跟「agent_blocked 等
# 真正的拒絕（6）」混成同一碼。這裡自己呼叫 herdr，並沿用 common.sh
# 的 eo_herdr 同一套手法：把呼叫包在 if 的條件裡、在 else 分支緊接著
# 取 $?，理由完全相同——本腳本已 set -e，若寫成裸陳述句再讀 $?，
# errexit 會在讀到 $? 之前就先終止整個腳本，走不到下面的碼判斷。
# `2>&1 >/dev/null`：先把 fd2 導向目前的 fd1（也就是被命令替換擷取的
# 管線），再把 fd1 導向 /dev/null，結果只有 stderr（herdr 的錯誤 JSON
# 印在這裡）被擷取進 err_output，stdout 直接丟棄。
rc=0
if err_output="$(herdr agent prompt "$target" "$text" \
    --wait --until working --timeout "$handshake_timeout_ms" \
    2>&1 >/dev/null)"; then
  printf 'handshake=ok\n'
  exit 0
else
  rc=$?
fi

if [ "$rc" -eq 2 ]; then
  eo_die 2 "send-to-phase.sh: herdr 以結束碼 2 拒絕 agent prompt，疑似腳本呼叫語法錯誤（target=$target）"
fi
if [ "$rc" -ne 1 ]; then
  exit "$rc"
fi

error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
case "$error_code" in
  timeout | agent_prompt_stalled)
    printf 'handshake=none\n'
    exit 7
    ;;
  *)
    eo_die 6 "send-to-phase.sh: herdr 以結束碼 1 拒絕 agent prompt（target=$target），錯誤碼非逾時類：$err_output"
    ;;
esac
