# Git Commit Message 風格規範

- [格式](#格式)
- [Type](#type)
- [Scope](#scope)
- [範例](#範例)

此規則定義本倉庫的 git commit message 格式，以倉庫目錄結構作為分類依據，確保提交記錄清晰易讀。

## 格式

```text
type(scope): [name] description
```

每個欄位的說明如下：

- **type** — 變更的性質，使用 Conventional Commits 標準類型
- **scope** — 對應倉庫主要目錄，使用**單數形式**
- **name** — 以方括號包住，代表具體修改的項目名稱
- **description** — 英文撰寫，簡潔描述變更目的

## Type

| Type | 說明 |
| --- | --- |
| `feat` | 新增功能或項目 |
| `fix` | 修正錯誤或問題 |
| `refactor` | 重構，不影響功能 |
| `docs` | 文件更新 |
| `chore` | 雜項維護，如依賴更新、格式調整 |

## Scope

Scope 對應倉庫中的主要目錄，一律使用**單數形式**：

| Scope | 對應目錄 |
| --- | --- |
| `skill` | `skills/` |
| `agent` | `agents/` |
| `rule` | `rules/` |
| `hook` | `hooks/`（未來使用） |
| `config` | 全域設定檔（如 `CLAUDE.md`、`settings.json`） |
| `global` | 不屬於特定目錄的跨範疇變更 |

若修改涉及多個 scope，以**主要變更**的 scope 為準。

## 範例

```text
feat(skill): [my-skill] add initial implementation
feat(agent): [doc-researcher] support multi-source lookup
fix(rule): [markdown-editing] correct subagent delegation flow
refactor(agent): [github-manager] simplify PR creation logic
docs(config): [CLAUDE.md] update role description
chore(global): clean up unused files
```
