#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/fetch-detail.sh
#
# 用法：fetch-detail.sh --seq <序號>
#
# 職責（規格 §8、Task 12）：印出 details/ 底下 <序號> 那則回報的檔案
# 路徑，絕不印內容。
#
# ---- 只印路徑，不印內容 ----
# details/<seq>-<worker>.txt 裡的內容是 worker 的自由文字，量體無上限
# （report.sh 檔頭「這支腳本在整個設計裡的位置」一節：細節本來就是為
# 了不佔用 orchestrator 的 context 才落到磁碟上）。若本腳本把內容印出
# 來，等於讓那個本來要被隔開的量體直接灌回呼叫端（orchestrator）的
# context，跟本來要解決的問題一樣——因此本腳本只回傳一個檔案路徑，內
# 容由調查者（讀取類 subagent）另外去讀。
#
# ---- <序號> 不需要名稱格式驗證，也不需要 workspace 邊界守衛 ----
# 本腳本唯一的輸入是純數字序號，不接受任何會被拿去組 registry 路徑的
# 名稱（不像 instruct.sh／press-approval.sh 等腳本的 --to），因此不適
# 用 hat_assert_agent_name；序號本身先驗證只含數字，已經足以防止路徑
# 跳脫（`/`、`..` 都不是數字字元）。也沒有「既有 target」的座標可以拿
# 去斷言屬於本 workspace——details/ 底下的檔案都落在 hat_registry_root
# 算出的本 workspace 專屬路徑之下，找不到、找到都只在這個範圍內，沒有
# 誤觸別的 team 的風險。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

seq="" have_seq=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --seq)
      [ "$#" -ge 2 ] || hat_die 2 "fetch-detail.sh: --seq 缺值"
      seq="$2"; have_seq=1; shift 2 ;;
    *)
      hat_die 2 "fetch-detail.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_seq" -ne 1 ]; then
  hat_die 2 "fetch-detail.sh: --seq 為必填"
fi

case "$seq" in
  '' | *[!0-9]*)
    hat_die 2 "fetch-detail.sh: --seq 必須是純數字序號，收到：$seq" ;;
esac

registry_root="$(hat_registry_root)"

detail_file=""
while IFS= read -r -d '' f; do
  detail_file="$f"
  break
done < <(find "$registry_root/details" -maxdepth 1 -type f -name "${seq}-*.txt" -print0 2>/dev/null)

if [ -z "$detail_file" ]; then
  hat_die 5 "fetch-detail.sh: 序號 $seq 底下沒有細節檔（可能這則回報沒有帶 --detail-file，或序號不存在）：$registry_root/details/${seq}-*.txt"
fi

printf '%s\n' "$detail_file"
exit 0
