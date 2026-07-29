# Agent Criteria

本檔是 `agents/`、`.claude/agents/` 目錄下 subagent 定義檔的專屬判準，與 `shared-criteria.md` 一併載入。

## Naming Convention

- 一律使用 **kebab-case**
- 名稱必須以角色名詞結尾，常見後綴如下：
  - `-er`：manager、editor、researcher、poster、thinker、developer、designer、composer
  - `-or`：author、administrator
  - `-ist`：specialist
  - 其他：expert、admin、guide
- 反映「角色」而非「動作」（例：`markdown-editor` 而非 `edit-markdown`；`shell-script-reviewer` 而非 `review-shell-script`）
- 多單字組合時領域詞在前、角色詞在後（例：`docker-expert`、`github-manager`、`obsidian-md-editor`）
- 檔名（去除 `.md` 副檔名）必須與 frontmatter `name` 欄位一致

## Frontmatter Requirements

每份 subagent 定義檔必須在檔案最頂端包含 YAML frontmatter，以下欄位全部必填：

| 欄位 | 說明 |
| --- | --- |
| `name` | 與檔名（去除 `.md` 副檔名）一致 |
| `description` | 觸發描述，使 LLM 能無歧義地判斷何時應呼叫本 agent |
| `tools` | 明確列出本 agent 被授權使用的工具清單 |
| `model` | 使用的模型等級，從 `opus`、`sonnet`、`haiku`、`inherit` 擇一；`inherit` 表示不釘死特定等級，沿用 main session 當下使用的模型 |
| `color` | 視覺識別色，用於 CLI 介面中區分不同 agent |

## Mandatory Sections

每個 subagent 定義檔必須包含以下章節，並**依此順序排列**：

1. **前言段落（不加 heading）**：緊接在 frontmatter 之後，一段話說明本 agent 的角色與核心職責
1. `## In Scope`：條列式列出本 agent 負責處理的工作類型
1. `## Out of Scope`：條列式列出本 agent 明確不負責的工作類型
1. `## Input from Main Agent`：宣告本 agent 需要 main agent 提供哪些輸入，以及缺少必填輸入時的處置
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

## Workflow Authoring Rules

撰寫 Workflow 章節時，內容類型限制對所有 model 等級一律適用，只有執行具體度隨模型能力調整。這兩條軸適用的內容必要性判準，見 `shared-criteria.md` 的 `Wording Criteria` 章節；本節規定其在 Workflow 章節的落實。

**內容類型限制（所有 model 一律適用）**：只允許以下四類，不因模型較小放寬：

- 順序敏感的副作用 checkpoint（例：建立 PR 前必須先完成 push、寫入暫存檔前必須先確認目錄是否存在）
- 此 repo 或此 domain 特有、無法從通用知識推斷的 convention
- 外部工具的已知 quirks
- 與 main agent 的 handoff checkpoint（失敗時回報哪些欄位、何時應暫停並向使用者確認）

以下內容對任何模型都不得寫入 Workflow 章節：

- LLM 能自行推理的常識順序（例：先讀檔再編輯、先搜尋再判斷）
- 標準語法或語言特性教學、通用框架用法
- 透過 help 指令或工具 schema 即可取得的 CLI flag 逐項清單（型錄式窮舉）
- 條件分支的窮舉

**執行具體度（依模型能力調整，僅在上述允許四類內生效）：**

- **model 為 opus 或 sonnet**：以意圖與約束陳述，信任模型自行推導執行細節，不逐步指揮
- **model 為 haiku**：對上述允許四類中的步驟與必要指令，寫得更逐步、更具體、更釘死，以減少小模型的推理誤差。具體化只能發生在已允許的內容範圍內，不得作為跨入禁止內容的理由

關於 CLI canonical 範例的可寫入界線，同樣依 `shared-criteria.md` 的 `Wording Criteria` 章節判斷，本節不重複該判準。

## Out of Scope Authoring Rules

撰寫 `## Out of Scope` 章節時須遵守以下規則：

- 以「問題類型」描述不負責的範圍（例：「不處理 vault body content 的撰寫」）
- 禁止寫成「請改用 xxx agent」或任何指向其他 subagent 的說法
- 需要描述超出範圍後的處置時，統一使用：「向 main agent 回報，由其決定後續處理」

## Input from Main Agent Authoring Rules

撰寫 `## Input from Main Agent` 章節時必須涵蓋以下四項內容：

- **必須提供的輸入**：缺少即無法工作的輸入，例如唯有 main agent 才掌握的目標檔案路徑、資源 ID 等事實
- **選填的輸入**：提供可以提升效果，但缺少也不影響基本執行的輸入
- **不需要提供的輸入**：本 agent 自己查得到的東西，main agent 不必代為提供
- **缺少必填輸入時的行為**：main agent 未提供必填輸入時，本 agent 應如何處置，例如暫停並回報缺少哪一項

此章節存在的理由：審查者看的是靜態定義檔，看不到執行期 main agent 實際傳了什麼 prompt；定義檔若不先宣告需要哪些輸入，就沒有判斷 context 是否給足的對照基準。

審查本章節時須檢查三項：

- 必填項是否真的必要，而非過度索取
- 是否把本 agent 自己查得到的東西列為必填
- 缺少必填輸入時的行為是否明確

## Output to Main Agent Authoring Rules

撰寫 `## Output to Main Agent` 章節時必須涵蓋：

- **成功時**：應回傳的具體欄位，例如檔案路徑、URL、資源 ID、操作狀態等
- **失敗時**：應回傳的具體欄位，例如錯誤代碼、原始錯誤訊息、已嘗試的步驟
- **不應回傳**的資訊，例如完整的筆記內容、敏感憑證、CLI 原始指令輸出等冗餘或有安全疑慮的內容

回傳內容的適當性另須檢查以下三項，核心是回傳內容不是越多越好：

- 每個回傳欄位是否有 main agent 實際會用到的用途；純粹「以防萬一」的欄位應刪除
- 是否回傳了 main agent 自己就能取得的資訊，例如它已經知道的檔案路徑、它可以自己讀取的檔案內容
- 是否回傳了體積大而資訊密度低的內容，例如完整檔案內容、逐字 diff、CLI 原始輸出；此類應改為摘要加上可供 main agent 自行取用的定位資訊
