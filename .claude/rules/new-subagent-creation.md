當需要新增或修改 `agents/` 目錄下的 subagent 定義檔時，main agent 必須觸發 `subagent-architect` skill 取得最新格式規格與命名規範，依其指引產出符合規範的內容；不得自行記憶或猜測格式細節。

## When to Trigger

- 新建 `agents/` 下的 subagent 定義檔
- 修改既有 subagent 的章節結構（新增、刪除、重命名章節）
- 修改既有 subagent 的 frontmatter 欄位
- 重新命名 subagent

## Relation to Other Rules

- 修改 `agents/` 目錄下的檔案時，git commit scope 為 `agent`（參見 `git-commit-style.md`）
- `prompt-quality-checks.md` 的合規檢查階段會直接 reference `subagent-architect` skill，本 rule 不重複格式判準
