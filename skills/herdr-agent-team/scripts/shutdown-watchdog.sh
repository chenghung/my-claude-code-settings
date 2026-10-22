#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/shutdown-watchdog.sh
#
# 用法：shutdown-watchdog.sh
#
# 職責：停掉本 team 的長駐看門狗（watchdog.sh 不帶參數啟動的那一支）。
#   存活：對整個 process group 送 SIGTERM，等存活判讀轉為否後印
#         `watchdog=stopped pid=<PID>`，以 0 結束；10 秒內仍存活以 1
#         結束。
#   未存活：印 `watchdog=not-running`，以 0 結束，不送任何訊號。
# 呼叫時機：team 收工（最後一個 worker 關閉、或人類放棄這個 team）；
# 中斷恢復的第一步（team-init.sh --recover 要求看門狗已停）；改門檻要
# 重啟之前。
#
# ---- 對整個 process group 送訊號，不是只殺主行程 ----
# 看門狗由 setsid 拉起，是 session leader，PGID 等於 PID。只殺主行程
# 時，跑到一半的那一輪會成為孤兒並做完——已實測停止後仍完成一輪，換成
# 正式版就是停止後還送出一次推進。對 `-PID` 送訊號會連同那一輪的子殼、
# 其中的 herdr／jq 呼叫與 sleep 一起收掉。
#
# ---- 先判讀身分才送訊號 ----
# 只對 hat_watchdog_alive_pid 認得的 PID 送訊號（持有鎖檔 fd 且為
# session leader）。watchdog.pid 指向別的行程時一律當成未存活，不送訊
# 號：對一個身分不明的 PID 送 group kill，會連帶殺掉那整個 group。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

if [ "$#" -gt 0 ]; then
  hat_die 2 "shutdown-watchdog.sh: 不接受任何參數"
fi

# 自我續租：位置與理由同 team-status.sh 的同名一節。
hat_renew_orchestrator_name

registry_root="$(hat_registry_root)"

if ! pid="$(hat_watchdog_alive_pid "$registry_root")"; then
  printf 'watchdog=not-running\n'
  exit 0
fi

# 負號 PID 代表整個 process group；行程已自行結束時 kill 會失敗，不算錯。
kill -TERM -- "-$pid" 2>/dev/null || true

for ((i = 0; i < 100; i++)); do
  if ! hat_watchdog_alive_pid "$registry_root" >/dev/null; then
    printf 'watchdog=stopped pid=%s\n' "$pid"
    exit 0
  fi
  sleep 0.1
done

hat_die 1 "shutdown-watchdog.sh: 送出 SIGTERM 後 10 秒內看門狗（pid=$pid）仍存活"
