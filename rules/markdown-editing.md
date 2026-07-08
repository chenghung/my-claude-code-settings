---
globs: "**/*.md"
---

# Markdown 編輯規則

建立或修改任何 markdown 檔案時，main agent 必須從下列兩個 subagent 擇一執行實際的編輯工作，禁止 main agent 自行編輯 markdown 檔案：

- `markdown-editor`：處理一般 markdown 檔案（software project README、docs、非 Obsidian 環境下的筆記等）
- `obsidian-md-editor`：處理 Obsidian vault 內的筆記，需套用 Obsidian 專屬語法（wiki-link、embed、block reference、Obsidian callout、typed property 等）

## Subagent 選擇

判定為 Obsidian vault 筆記的訊號，任一成立即應使用 `obsidian-md-editor`：

- 使用者明確提到 Obsidian、vault、wiki-link、callout、嵌入筆記、block reference 等 Obsidian 相關詞彙
- 目標檔案路徑位於已知的 Obsidian vault 目錄下
- 使用者明確要求產出含 Obsidian 專屬語法的筆記
- 既有目標檔案已包含 Obsidian 專屬語法（`[[...]]`、`![[...]]`、`==...==`、`%%...%%`、`> [!note]` 小寫 callout、typed frontmatter 等）
- Main agent 先前已為同一 vault 呼叫過 `obsidian-manager`，延續同一脈絡

上述任一訊號都不成立時，預設使用 `markdown-editor`。當訊號模糊或互相矛盾時，向使用者確認而非擅自判斷。

## Main Agent 的責任

Main agent 傳給 subagent 的 prompt 必須是純文字，不得夾帶任何 markdown 格式語法；所有實際的格式決策由 subagent 自行判斷處理。此要求對兩個 subagent 皆適用。

Main agent 只負責提供以下資訊給 subagent：

- **目標檔案路徑**：要建立或修改的檔案絕對路徑
- **修改意圖**：說明要新增、更新或刪除哪些部分
- **內容重點摘要**：要傳達的資訊

## 互斥原則

單一編輯任務只應委派給其中一個 subagent，不得在同一次任務中交叉呼叫兩者。若任務跨越 Obsidian vault 與一般檔案（例如需要從一般 markdown 複製內容到 vault 筆記），應拆分為兩個獨立任務分別委派。

**例外：在 Obsidian vault 中建立需要初始內容的新筆記。** 此場景屬於互斥原則的例外，完整協作流程由 `obsidian-notes` skill 定義，main agent 觸發該 skill 後依其指引處理，本 rule 不重複描述細節。

## 範圍排除

GitHub issue 與 PR 的標題及內文雖然以 markdown 格式撰寫，但不屬於本 rule 所規範的 markdown 檔案範圍，不應觸發 `markdown-editor` 或 `obsidian-md-editor`。此類內容的撰寫由 `github-issue-pr-authoring` skill 統籌處理。

領域驅動設計（DDD）建模流程產出的戰略與戰術模型檔，由該流程中負責建模的 subagent 於任務執行時直接寫入，屬領域專家的結構化產出，同樣排除於本 rule 所規範的 markdown 檔案範圍之外，不應改由 `markdown-editor` 或 `obsidian-md-editor` 代寫。此類產物的撰寫由 `ddd-modeling` skill 統籌處理。

`agents/`、`skills/`、`rules/`、`.claude/rules/` 目錄下的定義檔，以及各層的 `CLAUDE.md`，屬於受 `subagent-architect`、`new-subagent-creation` 與 `prompt-quality-checks` 治理的 prompt 定義檔，由該治理管線於撰寫時直接產出並接受獨立合規審查，不屬於本 rule 所規範的一般 markdown 檔案範圍，不經 `markdown-editor` 或 `obsidian-md-editor` 路由。
