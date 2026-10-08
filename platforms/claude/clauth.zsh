# clauth.zsh — clauth 啟動 claude 的函式與 alias（zsh 專用，由 ~/.zshrc 的
# 託管區塊以絕對路徑 source；見 install-cli-tools.sh 第 6 節）。
# 直接編輯此檔，新開的 shell 即生效，不需重跑 install-cli-tools.sh。
#
# _CLAUTH_SETTINGS_FILE：repo 內 platforms/claude/settings.json 的絕對路徑，
# 於 source 當下由本檔自身位置推得（zsh 的 %x 為正在被 source 的檔案路徑，
# :A 轉絕對路徑並解析 symlink、:h 取目錄），repo 無論 clone 到哪台機器的哪
# 個位置都成立，不寫死任何家目錄。
#
# 為何不再把 ~/.claude/settings.json 做成 symlink、改用 --settings：
#   [推論] clauth 啟動時似乎會把 settings.json 複製進 runtime 目錄、結束後
#   同步回 ~/.claude/settings.json，把 symlink 換成實體檔，造成 repo 與本機
#   內容漂移。此點未直接重現，依據是間接證據：clauth 二進位內的字串
#   "settings.json sync"／"final settings.json sync"、2026-09-30 首次執行
#   clauth 後 2 分鐘起出現的 8 份 *.pre-symlink.bak 備份，以及 env {} 指紋。
#   因此 ~/.claude/settings.json 改由 clauth 擁有，repo 的設定由下面每個啟動
#   入口於 `--` 之後加上 `--settings "$_CLAUTH_SETTINGS_FILE"` 載入。
# 已實測（2026-10-08，/usr/bin/claude -p，暫存專案）：
#   - --settings 檔會覆蓋 project 層設定（model 由 sonnet 變 haiku）；
#   - 同一個 hook 指令同時定義在 project 層與 --settings 檔時只觸發一次。
# [推論] --settings 也高於 user 層：依 Claude Code 文件的優先序（CLI 參數 >
#   local > project > user）推得，未對 user 層另行實測。
# 本檔不主張任何關於 permissions 陣列如何合併的行為。
# 變數於 alias／函式執行時才展開並加雙引號，路徑含空白也不會被拆開。
_CLAUTH_SETTINGS_FILE="${${(%):-%x}:A:h}/settings.json"
## clauth 智慧選 profile（claude 啟動前自動判斷要用哪個 profile）
# 完整規則說明與調整指南見同目錄 clauth-profile-picker.md；修改規則時須同步更新。
# _clauth_smart_pick 依 `clauth status --json` 中每個 auth_status=="ok" profile
# 的 7d／5h 用量視窗計算分數 S，挑最適合現在使用的 profile；claude 改呼叫
# clauto，不再固定寫死 onramplab 或 personal。
#   w  = 100 - 7d 視窗 utilization_pct（缺 7d 視窗視為已用滿，w=0）
#   T  = 距 7d resets_at 的小時數，下限鎖 0.25 小時
#   r5 = 100 - 5h 視窗 utilization_pct（缺 5h 視窗視為尚未使用，r5=100）
#   t5 = 距 5h resets_at 的小時數（缺視窗或已過期記為 0）
#   c(t) = 台北時間週一至週五 09:00–19:00（不含 19:00）每小時耗用 40%，其餘 25%
#   E  = now 到 5h 重置這段時間，逐 15 分鐘 slot 累加 c(slot 起點)，最後不足
#        15 分鐘的 slot 依剩餘比例加權（t5=0 時 E=0）
#   F  = E=0 時為 1，否則 min(1, r5/E)；U = max(w-2, 0)/T；S = U * F
# 篩選：先剔除 r5<=2 或 w<=2 者；剩餘中若有 2<w<=5 且 F>=0.5（即將用完 7d 配額、
# 但 5h 還撐得住）者，取其中 S 最高者；否則取剩餘中 S 最高者；全數被剔除時
# 回退 .active_profile。CLAUTH_PICK_NOW（epoch 秒）可覆寫「現在時間」，供測試
# 用固定時間注入，未設定時才用系統當下時間。
_clauth_smart_pick() {
  local now target
  now="${CLAUTH_PICK_NOW:-$(date +%s)}"
  target=$(clauth status --json 2>/dev/null | jq -r --argjson now "$now" '
    def parse_epoch:
      sub("(\\.[0-9]+)?(Z|\\+00:00)$"; "Z") | fromdateiso8601;
    def rate($t):
      ($t + 8*3600 | gmtime) as $tp
      | ($tp[6]) as $wday
      | ($tp[3]*3600 + $tp[4]*60 + $tp[5]) as $secofday
      | if ($wday >= 1 and $wday <= 5 and $secofday >= 9*3600 and $secofday < 19*3600)
        then 40 else 25 end;
    def win($p; $label):
      ($p.windows // []) | map(select(.label == $label)) | first;
    def expected_consumption($now; $reset_epoch):
      if $reset_epoch == null then 0
      else ([0, ($reset_epoch - $now)] | max) as $total
        | ($total / 900 | floor) as $nfull
        | ($total - $nfull*900) as $rem
        | (if $rem > 0 then $nfull + 1 else $nfull end) as $nslots
        | reduce range(0; $nslots) as $i
            (0; . + (rate($now + $i*900) * 0.25 * (if $i < $nfull then 1 else ($rem/900) end)))
      end;
    def score($p):
      win($p; "7d") as $w7
      | win($p; "5h") as $w5
      | (if $w7 == null then 100 else $w7.utilization_pct end) as $u7
      | (100 - $u7) as $w
      | (if $w7.resets_at == null then null else ($w7.resets_at | parse_epoch) end) as $r7e
      | (if $r7e == null then 0.25 else ([0.25, (($r7e - $now) / 3600)] | max) end) as $T
      | (if $w5 == null then 0 else $w5.utilization_pct end) as $u5
      | (100 - $u5) as $r5
      | (if $w5.resets_at == null then null else ($w5.resets_at | parse_epoch) end) as $r5e
      | expected_consumption($now; $r5e) as $e
      | (if $e == 0 then 1 else ([1, ($r5 / $e)] | min) end) as $f
      | (([$w - 2, 0] | max) / $T) as $u
      | { name: $p.name, w: $w, r5: $r5, f: $f, s: ($u * $f) };
    . as $root
    | ($root.profiles // [])
    | map(select(.auth_status == "ok"))
    | map(score(.))
    | map(select(.r5 > 2 and .w > 2)) as $remain
    | ($remain | map(select(.w > 2 and .w <= 5 and .f >= 0.5))) as $finish
    | (if ($finish | length) > 0 then $finish else $remain end) as $pool
    | if ($pool | length) > 0 then ($pool | max_by(.s) | .name)
      else ($root.active_profile // empty)
      end
  ')
  echo "${target:-onramplab}"
}
clauto() { local profile; profile=$(_clauth_smart_pick); echo "==> [clauth] 選定 profile: $profile" >&2; clauth start "$profile" -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto "$@"; }
alias claude='clauto'
## aliases for claude code
# 統一透過 clauth 的 profile 啟動 claude，不再直接呼叫 claude、也不再走
# 自製的 _ccp_launch config-dir 切換函式（已移除）。clauth start 執行期間
# 對 CLAUDE_CONFIG_DIR=~/.clauth/profiles/<profile>/runtime-<pid>-0
# （數字隨每次執行改變）做完整列舉，已實測驗證這不是複製、而是「幾乎全部
# symlink、僅兩個實體檔」的混合結構：47 個 symlink、剛好 2 個實體檔、0 個
# 實體目錄。
#   - symlink 回 /home/eddie/.claude/<同名>：agents、rules、hooks、
#     skills、commands、CLAUDE.md、projects、session-env、file-history、
#     tasks、settings.local.json、remote-settings.json。
#   - 唯二的實體檔：.claude.json（119k，user-scope MCP 設定如 codegraph
#     所在處；本體是與 ~/.claude 同層的手足檔案 $HOME/.claude.json，不在
#     ~/.claude 目錄內——已確認 ~/.claude/.claude.json 並不存在）與
#     settings.json（7.0k，clauth 應是為了注入自己的欄位才複製而非直接
#     symlink）。
# 已實測驗證 clauth 把 .claude.json 這份手足檔案的內容也帶進了 runtime
# 目錄：`clauth start personal -- mcp list` 的輸出與全域 `claude mcp list`
# 完全一致，包含 `codegraph: codegraph serve --mcp - ✔ Connected`。
# 更重要的是：projects、session-env、file-history、tasks 這四個 session
# 資料目錄全部是 symlink 回 ~/.claude 本體，根本不住在會隨 session 結束
# 而消失的暫時目錄裡——「移除 --claude-personal 後 session 仍然共享」這
# 件事因此有了直接證據，不再只是推論；這正是 --claude-personal 機制原本
# 存在的兩個目的（第二組憑證隔離、跨訂閱共享 session）裡，第二個目的能
# 被 clauth 直接承接的依據。
# clauth 的 usage 建議把它自己的旗標放在 profile 名之前，但那只是建議的
# 擺放位置，不等於解析器的實際攔截範圍——兩者不可混為一談。已逐一實測：
# `clauth start <profile> --help`（不加 `--`）會印出 clauth 自己的 start
# 說明、claude 根本沒被執行；`--theme` 給無效值會噴 clauth 自己的
# "invalid value ... for '--theme <TIER>'"，代表它同樣在 profile 名之後
# 仍被 clauth 解析；但 `--version` 不會被攔截，照樣轉交 claude（印出
# claude 的版本而非 clauth 的）。因此攔截範圍實測為 `--help`／`-h`／
# `--theme`，不含 `--version`。
# 每個 alias 一律以 `--` 分隔 clauth 與 claude 的引數，即使該 alias 目前
# 沒有任何與 clauth 同名的旗標——理由是使用者在 alias 後面自行追加的引數
# （例如 `cla --model opus`）也會落在 `--` 之後；一旦追加到上述會被攔截
# 的旗標，不加 `--` 就會被 clauth 吃掉，而非原樣轉交給 claude。
# 已實測確認 `clauth start <profile> --` 這種尾端
# 只有 `--`、後面沒有任何引數的形式不會被拒絕：clap 會把它解析為空的
# CLAUDE_ARGS，仍正常轉交 claude 執行（exit code 0）。
# cl* 對應 onramplab profile（Team 方案），clp* 對應 personal profile
# （Max 方案）——兩個 profile 名稱皆取自 `clauth list` 的實際輸出，非
# 隨意命名。
alias cl='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE"'
alias cla='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto'
alias clc='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --continue'
alias clr='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --resume'
alias clw='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --worktree "$(basename $(git rev-parse --show-toplevel))/wt/$(date +%Y%m%d-%H%M%S)"'
alias clre='clauth start onramplab -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --remote-control --name remote-control-onr-notebook-$(date +%Y%m%d-%H%M%S)'
alias clp='clauth start personal -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto'
alias clpc='clauth start personal -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --continue'
alias clpr='clauth start personal -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --resume'
alias clpw='clauth start personal -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --worktree "$(basename $(git rev-parse --show-toplevel))/wt/$(date +%Y%m%d-%H%M%S)"'
alias clpre='clauth start personal -- --settings "$_CLAUTH_SETTINGS_FILE" --permission-mode auto --remote-control --name remote-control-personal-notebook-$(date +%Y%m%d-%H%M%S)'
