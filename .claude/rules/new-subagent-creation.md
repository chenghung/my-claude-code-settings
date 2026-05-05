當需要新增或修改既有 subagent 的 prompt 時，main agent 必須透過 `subagent-architect` skill 取得最新的格式規格與命名規範，依其指引產出符合規範的 subagent 定義檔。main agent 不得自行記憶或猜測格式細節。

## When to Trigger

以下任一情況發生時，必須觸發 `subagent-architect` skill：

- 新建 `agents/` 目錄下的 subagent 定義檔
- 修改既有 subagent 的章節結構（新增、刪除、重命名章節）
- 修改既有 subagent 的 frontmatter 欄位
- 重新命名 subagent

## Relation to Other Rules

- `git-commit-style.md`：修改 `agents/` 目錄下的 subagent 定義檔時，commit message 的 scope 使用 `agent`
- `prompt-quality-checks.md`：合規檢查階段會直接 reference `subagent-architect` skill
