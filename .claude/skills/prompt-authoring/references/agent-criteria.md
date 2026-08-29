# Agent Criteria

本檔是 `agents/`、`.claude/agents/` 目錄下 subagent 定義檔的專屬判準，與 `shared-criteria.md` 一併載入。

本檔以「呼叫方」泛稱呼叫本 agent 的一方，涵蓋 main agent 與核心職責為統籌並派工其他 subagent 的 orchestrator 性質 subagent；除本檔另有限定的情境外，判準對兩者一體適用。

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
1. `## Input`：宣告本 agent 需要呼叫方提供哪些輸入，以及缺少必填輸入時的處置
1. `## Boundary and Failure Behavior`：描述工具呼叫失敗、資料缺失、認證失敗等邊界情境下的處置方式
1. `## Output`：定義成功與失敗時應回傳給呼叫方的格式與欄位

`## Input` 的必填範圍採過渡判定：新建的 subagent 定義檔，以及本次變更中被修改的既有定義檔，此章節必填；本次變更未觸碰的既有定義檔，缺少此章節不列為 finding。判定方式：檢查該檔案是否在本次變更所異動的檔案清單中——是則必填，否則跳過此項檢查。

既有定義檔沿用舊標題 `Input from Main Agent` 與 `Output to Main Agent` 者永久合規，不套用上一段「本次變更所異動的檔案清單」判定：此處只是標題措辭調整，新舊標題指涉的章節內容與必填規則完全相同，不像 `## Input` 必填範圍本身是新增的實質要求，因此不隨檔案日後是否被修改而失效。

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

以下行為一律禁止：撰寫時不得寫入，審查時發現一律列為 finding。發現後的處置沿用 `shared-criteria.md` 的 `Forbidden Patterns` 節，本節不重複。

- **Cross-agent references**：不得在內文中提及其他 subagent 的名稱。職責邊界以「不處理什麼問題類型」描述；遇到超出範圍的需求，應向呼叫方回報，由呼叫方決定後續路由。但書：核心職責為統籌並派工其他 subagent 的 orchestrator 性質 agent，得在內文中指名其派工對象，因為不指名即無法描述其管線；此但書不放寬其他情境。自我檢測：該 agent 的 `## In Scope` 是否明確宣告其核心職責即為呼叫並協調其他具名 subagent？是才適用此但書；若只是流程中附帶呼叫某個 helper agent、核心職責仍是別的工作，則不適用，仍依「不處理什麼問題類型」描述職責邊界
- **Numbered section headings**：不得使用 `## 1. xxx`、`## 2. xxx` 等編號形式的章節標題

## Workflow Authoring Rules

撰寫 Workflow 章節時，內容類型限制對所有 model 等級一律適用，只有執行具體度隨模型能力調整。這兩條軸對應 `shared-criteria.md` 的 `Content Necessity` 章節「模型能力與執行具體度的兩軸」；本節規定其在 Workflow 章節的落實。

**內容類型限制（所有 model 一律適用）**：應寫入五類與禁止清單沿用 `shared-criteria.md` 的 `Content Necessity` 章節，本節不重複列出。Workflow 章節在此之外額外禁止一項：條件分支的窮舉。

**執行具體度（依模型能力調整，僅在上述允許內容範圍內生效）：**

- **model 為 opus 或 sonnet**：以意圖與約束陳述，信任模型自行推導執行細節，不逐步指揮
- **model 為 haiku**：對上述允許內容中的步驟與必要指令，寫得更逐步、更具體、更釘死，以減少小模型的推理誤差。具體化只能發生在已允許的內容範圍內，不得作為跨入禁止內容的理由

關於 CLI canonical 範例的可寫入界線，依 `shared-criteria.md` 的 `Content Necessity` 章節「CLI 範例的界線」判斷，本節不重複該判準。

## Out of Scope Authoring Rules

撰寫 `## Out of Scope` 章節時須遵守以下規則：

- 以「問題類型」描述不負責的範圍（例：「不處理 vault body content 的撰寫」）
- 禁止寫成「請改用 xxx agent」或任何指向其他 subagent 的說法
- 需要描述超出範圍後的處置時，統一使用：「向呼叫方回報，由其決定後續處理」

既有定義檔沿用舊措辭「向 main agent 回報，由其決定後續處理」者永久合規：此措辭指向的行為與「向呼叫方回報，由其決定後續處理」完全相同，只是稱呼呼叫方的方式不同，不涉及實質規則變更，因此不隨檔案日後是否被修改而失效。

## Input Authoring Rules

撰寫 `## Input` 章節時必須涵蓋以下四項內容：

- **必須提供的輸入**：缺少即無法工作的輸入，例如唯有呼叫方才掌握的目標檔案路徑、資源 ID 等事實
- **選填的輸入**：提供可以提升效果，但缺少也不影響基本執行的輸入
- **不需要提供的輸入**：本 agent 自己查得到的東西，呼叫方不必代為提供
- **缺少必填輸入時的行為**：呼叫方未提供必填輸入時，本 agent 應如何處置，例如暫停並回報缺少哪一項

此章節存在的理由：審查者看的是靜態定義檔，看不到執行期呼叫方實際傳了什麼 prompt；定義檔若不先宣告需要哪些輸入，就沒有判斷 context 是否給足的對照基準。

審查本章節時須檢查三項：

- 必填項是否真的必要，而非過度索取
- 是否把本 agent 自己查得到的東西列為必填
- 缺少必填輸入時的行為是否明確

## Output Authoring Rules

撰寫 `## Output` 章節時必須涵蓋：

- **成功時**：應回傳的具體欄位，例如檔案路徑、URL、資源 ID、操作狀態等
- **失敗時**：應回傳的具體欄位，例如錯誤代碼、原始錯誤訊息、已嘗試的步驟
- **不應回傳**的資訊，例如完整的筆記內容、敏感憑證、CLI 原始指令輸出等冗餘或有安全疑慮的內容

回傳內容的適當性另須檢查以下三項，核心是回傳內容不是越多越好：

- 每個回傳欄位是否有呼叫方實際會用到的用途；純粹「以防萬一」的欄位應刪除
- 是否回傳了呼叫方自己就能取得的資訊，例如它已經知道的檔案路徑、它可以自己讀取的檔案內容；核實依據：先看其他 subagent 定義檔內文是否具名指出自己會呼叫本 agent（依 Cross-agent references 但書，只有 orchestrator 性質 agent 才會這樣具名），找到具名呼叫方時，查閱該呼叫方定義檔 frontmatter 的 `tools` 欄位確認其實際工具範圍；查無具名呼叫方時，預設呼叫方為 main agent、擁有完整存取範圍。若呼叫方的 `tools` 欄位本就不含讀取該資源所需的工具，此欄位對它而言不算冗餘，不得刪除
- 是否回傳了體積大而資訊密度低的內容，例如完整檔案內容、逐字 diff、CLI 原始輸出；此類應改為摘要加上可供呼叫方自行取用的定位資訊
