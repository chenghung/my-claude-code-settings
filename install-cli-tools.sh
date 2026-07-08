#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 腳本用途：在 Manjaro Linux 上安裝 15 個 CLI 工具，並將指定的
#           alias 區塊冪等地寫入 ~/.zshrc。
# 來源優先序（硬性）：官方 repo > AUR > pipx，且版本不可過舊。
# 預期影響：
#   - 透過 pacman 安裝官方 repo 套件：jq、bat、glow、eza、csvlens、
#     openai-codex、abduco、lf、markdownlint-cli、tflint、python-pipx、shellcheck
#   - 透過 yay（AUR helper）安裝 AUR 套件：rtk、claude-code
#   - 透過 pipx 安裝官方 repo 與 AUR 皆無的 python 套件：markitdown[all]
#   - 不再使用 npm 全域安裝任何工具（claude code / codex 已改走 repo 或 AUR）
#   - 於 ~/.zshrc 內以 sentinel 標記包夾的方式維護（重生）alias 區塊
# 冪等與衝突防護（重點）：
#   - 每個工具改以「指令是否已存在」作為冪等判斷，而非僅靠 pacman/yay 的
#     --needed。--needed 只在「同名套件」已安裝時才略過；當該工具是由
#     「不同名的提供者套件」滿足時（例如 codex 由 AUR 的 openai-codex-bin
#     提供，而非官方 repo 的 openai-codex），--needed 不會略過，pacman 仍會
#     嘗試安裝同名官方套件，並因檔案（/usr/bin/<cmd>）衝突而整個 transaction
#     失敗中止。
#   - 因此本腳本對每個工具先檢查對應指令是否已存在：已存在即視為「已有可用
#     版本」，安全略過，絕不強制改裝官方版而造成衝突或把較新版本降版；
#     只有在指令完全不存在時，才依來源優先序安裝指定套件。
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
# 工具安裝守門函式
#   參數：
#     $1 = 對應的可執行指令名稱（用來判斷工具是否已存在）
#     $2 = 要安裝的套件名稱
#     $3.. = 安裝指令（例如 sudo pacman -S --needed --noconfirm）
#   行為：
#     - 若指令 $1 已存在（不論由哪個套件提供），印出既有提供者後略過，
#       不再呼叫套件管理員，藉此避免不同名提供者套件造成的檔案衝突，
#       同時保留使用者既有（可能較新）的版本。
#     - 若指令不存在，才以指定的安裝指令安裝套件 $2。
# ------------------------------------------------------------
ensure_tool() {
  local cmd="$1"
  local pkg="$2"
  shift 2
  if command -v "$cmd" >/dev/null 2>&1; then
    local owner
    owner="$(pacman -Qoq "$(command -v "$cmd")" 2>/dev/null | head -n1 || true)"
    if [ -n "$owner" ]; then
      echo "    [略過] '${cmd}' 已存在，由套件 '${owner}' 提供，不重裝 '${pkg}'。"
    else
      echo "    [略過] '${cmd}' 已存在（非 pacman 套件管理，可能為手動安裝），不重裝 '${pkg}'。"
    fi
    return 0
  fi
  echo "    [安裝] 未偵測到 '${cmd}'，安裝套件 '${pkg}' ..."
  "$@" "$pkg"
}

# ------------------------------------------------------------
# 1) 官方 repo 套件（pacman）：
#    jq bat glow eza csvlens openai-codex abduco lf markdownlint-cli
#    tflint python-pipx shellcheck
#    來源依據：以上皆有官方 repo 版本，且版本不過舊（優先序第 1 級）。
#      - openai-codex 即 OpenAI Codex CLI 官方套件
#        （github.com/openai/codex，提供 /usr/bin/codex）。
#      - markdownlint-cli 提供 /usr/bin/markdownlint；務必是這個套件，
#        不要誤裝官方 repo 裡另一個同樣叫 markdownlint 的套件——那是
#        Ruby 寫的 mdl，是完全不同的工具。
#      - python-pipx 僅作為下方 pipx 安裝層（markitdown）的前置依賴，
#        本身不提供終端使用者指令。
#    衝突防護：codex 可能已由 AUR 的 openai-codex-bin 等不同名套件提供；
#      此時 /usr/bin/codex 已被佔用，直接 pacman -S openai-codex 會檔案衝突。
#      故改用 ensure_tool 以「codex 指令是否存在」為準，已存在即略過。
#    對應：套件名 -> 指令名
#      jq->jq  bat->bat  glow->glow  eza->eza  csvlens->csvlens
#      openai-codex->codex  abduco->abduco  lf->lf
#      markdownlint-cli->markdownlint  tflint->tflint
#      python-pipx->pipx  shellcheck->shellcheck
# ------------------------------------------------------------
echo "==> [1/3] 透過 pacman 安裝官方 repo 套件（已存在的工具會自動略過）"
PACMAN_INSTALL=(sudo pacman -S --needed --noconfirm)
ensure_tool jq           jq               "${PACMAN_INSTALL[@]}"
ensure_tool bat          bat              "${PACMAN_INSTALL[@]}"
ensure_tool glow         glow             "${PACMAN_INSTALL[@]}"
ensure_tool eza          eza              "${PACMAN_INSTALL[@]}"
ensure_tool csvlens      csvlens          "${PACMAN_INSTALL[@]}"
ensure_tool codex        openai-codex     "${PACMAN_INSTALL[@]}"
ensure_tool abduco       abduco           "${PACMAN_INSTALL[@]}"
ensure_tool lf           lf               "${PACMAN_INSTALL[@]}"
ensure_tool markdownlint markdownlint-cli "${PACMAN_INSTALL[@]}"
ensure_tool tflint       tflint           "${PACMAN_INSTALL[@]}"
ensure_tool pipx         python-pipx      "${PACMAN_INSTALL[@]}"
ensure_tool shellcheck   shellcheck       "${PACMAN_INSTALL[@]}"

# ------------------------------------------------------------
# 2) AUR 套件（yay）：rtk claude-code
#    來源依據：兩者官方 repo 皆無，但 AUR 有且版本不過舊（優先序第 2 級）。
#      - rtk：官方安裝管道為 Homebrew / install.sh / cargo / 預建二進位，
#        官方 repo 無；AUR 套件與 pacman 整合、可追蹤、易更新移除，最穩定。
#      - claude-code：官方 repo 無；AUR 套件版本與 npm 官方上游一致且近期更新。
#    衝突防護：同上，claude-code 可能由 claude-code-bin 等不同名套件提供，
#      rtk 亦可能由其他變體提供；故同樣以「指令是否存在」為準。
#    對應：套件名 -> 指令名
#      rtk->rtk  claude-code->claude
# ------------------------------------------------------------
echo "==> [2/3] 透過 yay 安裝 AUR 套件（已存在的工具會自動略過）"
if ! command -v yay >/dev/null 2>&1; then
  echo "    [錯誤] 找不到 yay，請先安裝 AUR helper 後再執行此腳本。" >&2
  exit 1
fi
YAY_INSTALL=(yay -S --needed --noconfirm)
ensure_tool rtk    rtk         "${YAY_INSTALL[@]}"
ensure_tool claude claude-code "${YAY_INSTALL[@]}"

# ------------------------------------------------------------
# 3) pipx 套件：markitdown（帶 all extras，取得完整格式支援）
#    來源依據：官方 repo 與 AUR 皆無 markitdown，改走 pipx（優先序第 3 級，
#      低於官方 repo 與 AUR）。
#    前置依賴：python-pipx（已於上方 pacman 區塊安裝，提供 pipx 指令）。
#    對應：套件名 -> 指令名
#      markitdown[all]->markitdown
#    注意：pipx 安裝的執行檔位於 ~/.local/bin，該路徑需已加入 PATH，
#      command -v 才偵測得到，ensure_tool 的冪等判斷才會生效。
#    防呆：若 python-pipx 剛安裝、當前 shell 尚未重新載入 PATH 導致
#      偵測不到 pipx，比照上方「找不到 yay」的風格警告後略過，
#      不中止整支腳本（與 yay 那層不同：yay 是硬性前提，pipx 只影響
#      這一個工具，故此處選擇 warn-and-skip 而非 exit）。
# ------------------------------------------------------------
echo "==> [3/3] 透過 pipx 安裝 python 套件（已存在的工具會自動略過）"
if ! command -v pipx >/dev/null 2>&1; then
  echo "    [警告] 找不到 pipx，略過 markitdown 安裝。若剛安裝 python-pipx，" >&2
  echo "           請重新開啟終端機或 source ~/.zshrc 後再重跑此腳本。" >&2
else
  PIPX_INSTALL=(pipx install)
  ensure_tool markitdown "markitdown[all]" "${PIPX_INSTALL[@]}"
fi

# ------------------------------------------------------------
# 4) 同步 alias 到 ~/.zshrc（重生整個託管區塊）
#    防重複與同步機制：以 BEGIN/END sentinel 標記包夾整段 alias，視為
#    「託管區塊」。每次執行都用腳本當下定義的內容「重生」此區塊：
#      - 完整區塊（BEGIN 與 END 皆在）：以 awk 只替換 BEGIN 與 END
#        sentinel 之間（含兩行 sentinel）的範圍，sentinel 以外的內容
#        一律原封不動。如此新增／修改／刪除腳本內的 alias，重跑後都會
#        完整反映到託管區塊；alias 內容沒變時則產生與前次相同的結果，
#        維持冪等、不重複附加。
#      - 無區塊（首次執行，BEGIN 與 END 皆不在）：在檔案結尾以一行空行
#        為分隔，新增整個區塊。
#      - 殘缺狀態（只有 BEGIN 沒有 END，或只有 END 沒有 BEGIN）：無法
#        安全判定託管範圍——若貿然附加新區塊，下次重跑時 awk 會把孤兒
#        sentinel 與新區塊之間的使用者內容一併吞掉而造成資料遺失。故
#        此處「停止並回報」，請使用者先手動修正成對 sentinel 後再執行，
#        本腳本絕不自動改動既有殘缺標記。
#    冪等關鍵：託管區塊本身（NEW_BLOCK）只含 BEGIN..END，不含前置空行；
#      前置空行只屬於「附加」路徑、且永遠落在區塊之外。重生路徑替換的
#      範圍恰為 BEGIN..END，因此區塊外既有的分隔空行不會被動到，也不會
#      每次重跑就多長一行。
#    literal 保留：_cc_prune_dead_sockets / _cc_launch / clw / clre 等含
#      $() 的函式與行，皆以 quoted heredoc 產生，寫入後字面與來源完全
#      一致，寫入時不會被本腳本的 shell 展開，留待 ~/.zshrc 載入時
#      才由 zsh 於執行期展開。
# ------------------------------------------------------------
echo "==> 同步 alias 至 ${ZSHRC}"
touch "$ZSHRC"

# 產生託管區塊內容（僅 BEGIN..END，不含前置空行）到暫存檔。
# 區塊主體以 quoted heredoc（<<'EOF'）輸出：$()、引號皆原樣保留，
# 不需逐字 escape，也不會被 shell 展開。
NEW_BLOCK="$(mktemp)"
MERGED=""
trap 'rm -f "$NEW_BLOCK" "$MERGED"' EXIT
{
  echo "$BEGIN_MARK"
  cat <<'EOF'
# Aliases
alias cat="bat"
alias ls="eza"
alias ll="eza -l --total-size --git"
alias tree="eza --long --tree"
alias md="glow -lt"
#alias glow="glow -lt"
alias csv="csvlens --color-columns --ignore-case --wrap words"
## aliases for claude code (launched inside abduco for detachable/persistent sessions)
# 逾期（14 天以上）死 socket 清理：只清 ~/.abduco 下、socket 型別、mtime 超過
# 14 天、且 session 名稱不在 `abduco -l` 存活清單中的檔案；任何失敗都不得
# 阻擋後續 claude 啟動，故各步驟以 2>/dev/null 或條件判斷吞掉錯誤。
_cc_prune_dead_sockets() {
  local dir="$HOME/.abduco" days=14
  local candidates
  candidates="$(find "$dir" -maxdepth 1 -type s -mtime +$days 2>/dev/null)"
  [ -z "$candidates" ] && return 0
  local live
  live="$(abduco -l 2>/dev/null | awk 'NR>1{print $NF}')"
  local f name
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name="$(basename "$f")"; name="${name%@*}"
    grep -qxF -- "$name" <<< "$live" && continue
    rm -f -- "$f"
  done <<< "$candidates"
}
# 統一啟動器：先清理逾期死 socket，再以「repo 名稱-時間戳」為 session 名稱
# 透過 abduco 啟動 claude，session 可隨時 detach / 用 cll 或 abduco -a 重連。
_cc_launch() {
  _cc_prune_dead_sockets
  local base
  base="$(git rev-parse --show-toplevel 2>/dev/null)"
  base="$(basename "${base:-$PWD}")"
  abduco -c "${base// /-}-$(date +%Y%m%d-%H%M%S)" claude "$@"
}
alias cl='_cc_launch'
alias cla='_cc_launch --permission-mode auto'
alias clc='_cc_launch --permission-mode auto --continue'
alias clr='_cc_launch --permission-mode auto --resume'
alias clw='_cc_launch --permission-mode auto --worktree "$(basename $(git rev-parse --show-toplevel))/wt/$(date +%Y%m%d-%H%M%S)"'
alias clre='_cc_launch --permission-mode auto --remote-control --name remote-control-onr-notebook-$(date +%Y%m%d-%H%M%S)'
alias cll='abduco -l'
## aliases for lf (terminal file manager)
# lfcd：離開 lf 時 cd 到瀏覽時所在目錄，透過 -last-dir-path 寫出的暫存檔傳遞。
lfcd() {
  local tmp dir
  tmp="$(mktemp)"
  command lf -last-dir-path="$tmp" "$@"
  dir="$(cat "$tmp" 2>/dev/null)"
  rm -f "$tmp"
  [ -d "$dir" ] && [ "$dir" != "$PWD" ] && cd "$dir"
}
alias f='lfcd'
## aliases for npx skills
alias skills="npx skills@latest"
alias sk="npx skills@latest"
EOF
  echo "$END_MARK"
} >"$NEW_BLOCK"

has_begin=0
has_end=0
grep -qF "$BEGIN_MARK" "$ZSHRC" && has_begin=1
grep -qF "$END_MARK"   "$ZSHRC" && has_end=1

if [ "$has_begin" -eq 1 ] && [ "$has_end" -eq 1 ]; then
  echo "    偵測到既有託管區塊，重生 sentinel 之間的內容（其餘原封不動）..."
  MERGED="$(mktemp)"
  # awk 流程：逐行讀 ~/.zshrc。
  #   - 未進入區塊前：原樣輸出每一行。
  #   - 遇到第一個 BEGIN sentinel：原地插入整份新區塊（NEW_BLOCK 已含
  #     BEGIN/END 兩行），並進入 skip 狀態，丟棄舊區塊內所有行直到 END。
  #   - 遇到 END sentinel：結束 skip，且該行本身一併丟棄（新區塊已含 END）。
  #   以 -v 傳入 sentinel 字串並用 index() 做字面比對，避免 regex 轉義問題。
  #   done 旗標確保只處理第一個託管區塊；其後重複出現的 sentinel 視為
  #   一般內容原樣保留，不再觸發替換。
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v nb="$NEW_BLOCK" '
    !done && !inblk && index($0, b) {
      while ((getline line < nb) > 0) print line
      close(nb)
      inblk = 1
      next
    }
    inblk && index($0, e) { inblk = 0; done = 1; next }
    inblk { next }
    { print }
  ' "$ZSHRC" >"$MERGED"
  cat "$MERGED" >"$ZSHRC"
  echo "    託管區塊已重生完成。"
elif [ "$has_begin" -eq 1 ] || [ "$has_end" -eq 1 ]; then
  echo "    [錯誤] ${ZSHRC} 內偵測到殘缺的託管 sentinel（BEGIN/END 不成對）。" >&2
  echo "           為避免重跑時誤刪 sentinel 之間的使用者內容，腳本停止，不做任何寫入。" >&2
  echo "           請手動修正成對的 sentinel 標記後再重新執行：" >&2
  echo "             BEGIN: ${BEGIN_MARK}" >&2
  echo "             END:   ${END_MARK}" >&2
  exit 1
else
  echo "    未偵測到託管區塊，於檔尾新增 ..."
  # 附加路徑：先輸出一行空行作為與既有內容的分隔，再接整個區塊。
  { echo ""; cat "$NEW_BLOCK"; } >>"$ZSHRC"
  echo "    alias 區塊已寫入完成。"
fi

echo
echo "==> 全部完成。請重新開啟終端機或執行：source ${ZSHRC} 以套用 alias。"
