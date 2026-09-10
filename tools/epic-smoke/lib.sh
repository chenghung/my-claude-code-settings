#!/usr/bin/env bash
# tools/epic-smoke/lib.sh - Shared logging layer for epic-smoke
#
# 界線：log_msg 僅用於人類可讀的診斷與進度訊息，後續 phase 若要產出可被程式解析的結果一律直接走標準輸出，不透過 log_msg。

log_msg() {
  echo "$*" >&2
}
