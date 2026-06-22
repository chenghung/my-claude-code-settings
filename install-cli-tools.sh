#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 腳本用途：在 Manjaro Linux 上安裝 8 個 CLI 工具，並將指定的
#           alias 區塊冪等地寫入 ~/.zshrc。
# 來源優先序（硬性）：官方 repo > AUR > npm/curl/cargo，且版本不可過舊。
# 預期影響：
#   - 透過 pacman 安裝官方 repo 套件：jq、bat、glow、eza、csvlens、openai-codex
#   - 透過 yay（AUR helper）安裝 AUR 套件：rtk、claude-code
#   - 不再使用 npm 全域安裝任何工具（claude code / codex 已改走 repo 或 AUR）
#   - 於 ~/.zshrc 內以 sentinel 標記包夾的方式新增 alias 區塊
# 執行前提：
#   - 系統已安裝 yay（AUR helper）
#   - pacman 與 yay 步驟會在執行期間透過 sudo 互動式輸入密碼
# 錯誤復原：
#   - 套件可用對應的 pacman -Rns / yay -Rns 移除
#   - ~/.zshrc 的 alias 區塊以 BEGIN/END sentinel 標記包夾，可手動刪除整段還原
# 所需權限：pacman 與 yay 安裝步驟需要 sudo（執行期間互動輸入）；
#           ~/.zshrc 寫入為使用者層級，不需 sudo。
# ============================================================

ZSHRC="${HOME}/.zshrc"
BEGIN_MARK="# >>> cli-tools aliases (managed) >>>"
END_MARK="# <<< cli-tools aliases (managed) <<<"

echo "==> 開始安裝 CLI 工具（此腳本可安全重複執行）"

# ------------------------------------------------------------
# 1) 官方 repo 套件（pacman）：jq bat glow eza csvlens openai-codex
#    來源依據：以上六者官方 repo 皆有，且版本不過舊（優先序第 1 級）。
#      - openai-codex 即 OpenAI Codex CLI 官方套件
#        （github.com/openai/codex，提供 /usr/bin/codex），
#        repo 版本與 npm 上游屬同一 0.x versioning，差距小、不過舊，
#        故由官方 repo 安裝，取代原本的 npm 全域安裝。
#    冪等機制：pacman --needed 會自動略過已安裝且為最新版的套件。
# ------------------------------------------------------------
PACMAN_PKGS=(jq bat glow eza csvlens openai-codex)
echo "==> [1/2] 透過 pacman 安裝官方 repo 套件：${PACMAN_PKGS[*]}"
echo "    （--needed 會自動略過已安裝的套件，因此重複執行不會出錯）"
sudo pacman -S --needed --noconfirm "${PACMAN_PKGS[@]}"

# ------------------------------------------------------------
# 2) AUR 套件（yay）：rtk claude-code
#    來源依據：兩者官方 repo 皆無，但 AUR 有且版本不過舊（優先序第 2 級）。
#      - rtk：官方安裝管道為 Homebrew / install.sh / cargo / 預建二進位，
#        官方 repo 無；AUR 套件與 pacman 整合、可追蹤、易更新移除，最穩定。
#      - claude-code：官方 repo 無；AUR 套件版本與 npm 官方上游一致且近期更新，
#        故改由 AUR 安裝，取代原本的 npm 全域安裝。
#    冪等機制：yay --needed 會略過已安裝且為最新版的套件。
# ------------------------------------------------------------
AUR_PKGS=(rtk claude-code)
echo "==> [2/2] 透過 yay 安裝 AUR 套件：${AUR_PKGS[*]}"
if ! command -v yay >/dev/null 2>&1; then
  echo "    [錯誤] 找不到 yay，請先安裝 AUR helper 後再執行此腳本。" >&2
  exit 1
fi
yay -S --needed --noconfirm "${AUR_PKGS[@]}"

# ------------------------------------------------------------
# 3) 寫入 alias 到 ~/.zshrc
#    防重複機制：以 BEGIN/END sentinel 標記包夾整段 alias。
#    若 ~/.zshrc 內已存在 BEGIN sentinel，代表已寫入過，直接略過，
#    確保重複執行不會把 alias 區塊重覆附加到檔案。
# ------------------------------------------------------------
echo "==> 設定 alias 至 ${ZSHRC}"
touch "$ZSHRC"
if grep -qF "$BEGIN_MARK" "$ZSHRC"; then
  echo "    偵測到既有的 alias 區塊（sentinel 已存在），略過寫入。"
else
  echo "    寫入 alias 區塊 ..."
  cat >> "$ZSHRC" <<EOF

${BEGIN_MARK}
# Aliases
alias cat="bat"
alias ls="eza"
alias ll="eza -l --total-size --git"
alias tree="eza --long --tree"
alias md="glow -lt"
#alias glow="glow -lt"
alias csv="csvlens --color-columns --ignore-case --wrap words"
## aliases for claude code
alias cl="claude"
alias cla='claude --permission-mode auto'
alias clc="claude --permission-mode auto --continue"
alias clr="claude --permission-mode auto --resume"
alias clw='claude --permission-mode auto --worktree "\$(basename \$(git rev-parse --show-toplevel))/wt/\$(date +%Y%m%d-%H%M%S)"'
alias clre="claude --permission-mode auto --remote-control --name remote-control-onr-notebook-\$(date +%Y%m%d-%H%M%S)"
${END_MARK}
EOF
  echo "    alias 區塊已寫入完成。"
fi

echo
echo "==> 全部完成。請重新開啟終端機或執行：source ${ZSHRC} 以套用 alias。"
