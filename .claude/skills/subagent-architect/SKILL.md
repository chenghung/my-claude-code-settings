---
name: subagent-architect
description: "Subagent 定義檔結構與命名規範知識庫。當使用者要求新建 subagent 定義檔，或修改既有 subagent 的章節結構（新增、刪除、重命名章節），或對 subagent 的 frontmatter / sections / 命名進行合規檢查時觸發。不應觸發：只是修改 subagent 既有章節內文（不改結構）、編輯 skills/ 或 rules/ 目錄下的檔案。觸發關鍵字：subagent、agent 定義、agent 規格、frontmatter、in scope、out of scope、boundary and failure behavior、output to main agent"
---

本 skill 統一 `agents/` 目錄下所有 subagent 定義檔的結構與命名，使 main agent 能以一致方式解析各 subagent 的職責與行為。本 skill 與 `prompt-quality-checks` rule 互補：後者規定設計原則與品質檢查，本 skill 規定具體格式落實。

## Applicability

- 適用對象：`agents/` 目錄下的所有 subagent 定義檔
- 不適用：`skills/` 與 `rules/` 目錄（可參考本 skill 的結構，但不強制相同）
- 觸發時機：新增 subagent 或修改既有 subagent 的章節結構（新增、刪除、重命名章節）時，必須遵循本 skill

## Naming Convention

- 一律使用 **kebab-case**
- 名稱必須以角色名詞結尾，常見後綴如下：
  - `-er`：manager、editor、researcher、poster、thinker、developer、designer、composer
  - `-or`：author、administrator
  - `-ist`：specialist
  - 其他：expert、admin、guide
- 反映「角色」而非「動作」（例：`markdown-editor` 而非 `edit-markdown`；`subagent-architect` 而非 `subagent-authoring`）
- 多單字組合時領域詞在前、角色詞在後（例：`docker-expert`、`github-manager`、`obsidian-md-editor`）
- 檔名（去除 `.md` 副檔名）必須與 frontmatter `name` 欄位一致

## Frontmatter Requirements

每份 subagent 定義檔必須在檔案最頂端包含 YAML frontmatter，以下欄位全部必填：

| 欄位 | 說明 |
| --- | --- |
| `name` | 與檔名（去除 `.md` 副檔名）一致 |
| `description` | 觸發描述，使 LLM 能無歧義地判斷何時應呼叫本 agent |
| `tools` | 明確列出本 agent 被授權使用的工具清單 |
| `model` | 使用的模型等級，從 `opus`、`sonnet`、`haiku` 擇一 |
| `color` | 視覺識別色，用於 CLI 介面中區分不同 agent |

## Mandatory Sections

每個 subagent 定義檔必須包含以下章節，並**依此順序排列**：

1. **前言段落（不加 heading）**：緊接在 frontmatter 之後，一段話說明本 agent 的角色與核心職責
1. `## In Scope`：條列式列出本 agent 負責處理的工作類型
1. `## Out of Scope`：條列式列出本 agent 明確不負責的工作類型
1. `## Boundary and Failure Behavior`：描述工具呼叫失敗、資料缺失、認證失敗等邊界情境下的處置方式
1. `## Output to Main Agent`：定義成功與失敗時應回傳給 main agent 的格式與欄位

## Optional Sections

以下章節依 agent 型態選用，位置排在所有 Mandatory Sections 之後，章節之間的相對順序由作者依語意決定：

- `## Primary Tooling`：包裹 CLI 或外部工具的 agent 適用，描述工具呼叫規則與注意事項
- `## Workflow`：有固定操作流程的 agent 適用，逐步說明執行順序
- `## Standards and Principles`：code-writing 類 agent 適用，描述程式碼風格與設計準則
- `## Known Issues`：包裹外部工具且有已知 bug 的 agent 適用
- `## Communication Style`：對輸出風格有特殊要求的 agent 適用
- `## Language`：需要限定回應語言的 agent 適用

## Section Naming and Hierarchy

- 章節標題一律使用**英文**，即使內文是繁體中文（例：標題寫 `## In Scope`，條列內容可以是中文）
- 主章節使用 `##`（H2），子章節使用 `###`（H3），不再往下深入
- **禁止**使用編號式標題（如 `## 1. Tooling`、`## 2. Workflow`）——編號在新增或移除章節時會連動引發重新編號，增加維護成本
- 子章節命名必須自我說明，不得依賴上下文才能理解其含義

## Forbidden Patterns

以下行為一律禁止，發現後必須立即修正：

- **Table of Contents**：不得在 subagent 定義檔頂端放置 ToC。Subagent 定義檔是 prompt，會整份載入 LLM context；ToC 對 LLM 沒有導航價值，純屬 token 浪費，且在章節重命名時會增加同步維護成本
- **Cross-agent references**：不得在內文中提及其他 subagent 的名稱。職責邊界以「不處理什麼問題類型」描述；遇到超出範圍的需求，應向 main agent 回報，由 main agent 決定後續路由
- **Hardcoded credentials**：不得寫入 API 金鑰、access token、含 token 的 webhook URL 或任何敏感資訊；一律改用環境變數
- **Numbered section headings**：不得使用 `## 1. xxx`、`## 2. xxx` 等編號形式的章節標題

## Out of Scope Authoring Rules

撰寫 `## Out of Scope` 章節時須遵守以下規則：

- 以「問題類型」描述不負責的範圍（例：「不處理 vault body content 的撰寫」）
- 禁止寫成「請改用 xxx agent」或任何指向其他 subagent 的說法
- 需要描述超出範圍後的處置時，統一使用：「向 main agent 回報，由其決定後續處理」

## Output to Main Agent Authoring Rules

撰寫 `## Output to Main Agent` 章節時必須涵蓋：

- **成功時**：應回傳的具體欄位，例如檔案路徑、URL、資源 ID、操作狀態等
- **失敗時**：應回傳的具體欄位，例如錯誤代碼、原始錯誤訊息、已嘗試的步驟
- **不應回傳**的資訊，例如完整的筆記內容、敏感憑證、CLI 原始指令輸出等冗餘或有安全疑慮的內容

## Compliance Check Triggers

以下情況發生時，必須對該 subagent 檔案執行本 skill 的合規檢查：

- 新建 subagent 定義檔
- 修改既有 subagent 的章節結構（新增、刪除、重命名章節）
- `prompt-quality-checks` rule 觸發品質檢查時，本 skill 同步執行
