---
description: Analyze the Voice Fusion Trello board and generate a sprint review report with retrospective discussion topics.
---

# VoiceFusion Board Sprint Review

## 目標 Board 資訊

此 command 針對 Voice Fusion Trello board 進行分析。Board members 不預先定義，統一從各 card 的 assignees 動態取得。

### Lists

Board 包含以下 lists，代表 sprint 工作流程的各個狀態：

| List 名稱 | 說明 |
| --- | --- |
| Incoming | 待處理的新工作項目 |
| In Progress | 正在進行中的工作 |
| Code Review | 等待或進行中的程式碼審查 |
| Staging / Tech Reviewing | 部署至 Staging 環境進行技術審查 |
| QA Verified In Staging | 在 Staging 環境通過 QA 驗證 |
| QA Failed In Staging | 在 Staging 環境 QA 驗證失敗 |
| Ready To Prod | 準備部署至正式環境 |
| Prod / User Reviewing | 部署至正式環境進行使用者驗收 |
| Closed | 已完成並關閉的工作項目 |

### Labels

Board 使用以下 labels 分類工作類型：

- Backend
- Frontend
- Feature
- Bug
- Chore
- DevOps
- Operation
- Hot Fix
- Research
- Meeting
- Need Info

## 分析目標

此 command 的分析目標涵蓋以下面向：

- 快速發現當前 sprint 中影響團隊開發節奏的問題
- 深入分析找出可優化日常開發流程的方法
- 產出 retrospective meeting 可討論的問題點
- 標記團隊的高效率亮點，例如快速完成的 card、review 速度優異的案例
- 卡片生命週期基準：一張 card 從 Incoming 到 Prod / User Reviewing 的理想時間為 1 週，除非該 task 本身規模較大

## 執行流程

整個流程分為三個階段：資料收集、資料分析、報告產出。

### 第一階段：資料收集

針對 Voice Fusion board 上的每一個 list，各派一個 trello-manager subagent（haiku model）並行查詢，以提高資料收集效率。各 subagent 只負責資料的取得，不進行任何分析。

每個 trello-manager subagent 的 prompt 需包含以下內容：

- **Goal**：取得該 list 中所有的 cards 及其完整資訊
- **Board 名稱**：Voice Fusion
- **List 名稱**：指定查詢的 list 名稱
- **Return**：期望回傳每張 card 的以下資料：
  - card 基本資訊：name、id、URL、assignees、due date、creator
  - card comments
  - card checklists（todos）
  - card labels
  - card attachments（特別標記 GitHub issue/PR URL）
  - card action history（用於計算 card 在各 list 間的移動時間）

> [!NOTE]
> subagent prompt 只描述目標與期望回傳的資料結構，不包含任何 CLI 命令。

### 第二階段：資料分析

由 main agent 全部負責，分為共同分析和各 list 特定分析。

#### 共同分析

所有 list 的 cards 都需要執行以下分析：

- 利用 action history 計算 card 從上一個 list 移動到當前 list 後的停留時間
- 彙整每張 card 的 comments、checklists、labels
- 彙整每張 card 的基本資訊（name、id、URL、due date）
- 統計 card creator 分佈

#### 各 List 特定分析

針對每個 list 執行對應的分析邏輯：

- **Incoming**：card 內容是否清晰；是否有正確填入 labels、description、title；偵測長期滯留的 card（開卡後超過一定時間仍未移至 In Progress），標記為潛在的 backlog 阻塞
- **In Progress**：card attach 的 GitHub issue/PR；comments 中的 task 補充或討論；GitHub issue 是否有完整 task 描述與 design；計算 card 在此 list 的停留時間，偵測停留超過 3 天的 card，分析可能原因（task 太大、blocked、缺少資訊等）
- **Code Review**：針對以下兩個階段分別進行分析：
  - 等待 review 時間：card 從 In Progress 移到 Code Review 後，多久才有第一個 reviewer 的動作（comment 或 checklist 更新），超過 1.5 天標記為 review 等待過久
  - review 後修改時間：如果 card 從 Code Review 被移回 In Progress 再回到 Code Review，計算這個來回花了多久，標記為 revision cycle
- **Staging / Tech Reviewing**：card 移到此 list 後是否太久沒測試；GitHub PR 是否都已 merged
- **QA Verified In Staging**：理論上應被移到 Ready To Prod；確認還停留的原因
- **QA Failed In Staging**：停留時間；是否有嘗試修復；card 中有無 failure 補充說明
- **Ready To Prod**：預備下週一上 production 的 cards；不需額外分析
- **Prod / User Reviewing**：有無後續補充如 production 測試結果；確認是否沒問題
- **Closed**：從 Prod list 移到 Closed 的 gap 時間

#### 流程診斷分析

針對整體開發流程進行以下診斷，所有計算均利用第一階段已收集的資料：

- **完整 Cycle Time 分析**：利用 action history 計算每張 card 經過各階段的時間加總，算出 Incoming 到 Prod / User Reviewing 的總時間，與 1 週基準比較，找出哪個階段是整體流程的瓶頸
- **回流偵測（Rework Detection）**：偵測 card 是否從後面的 list 被移回前面的 list（例如 QA Failed 移回 In Progress，或 Code Review 移回 In Progress），統計回流次數與涉及的 card
- **WIP 限制檢查**：計算 In Progress、Code Review、Staging / Tech Reviewing 三個 list 的 card 總數，除以團隊成員數（從 assignees 動態取得），判斷人均 WIP 是否合理（建議不超過 2）
- **異常值標記**：自動標記停留時間超過該 list 平均值 2 倍的 card
- **跨 Sprint 比較**：從 Closed list 的 card action history 中，依 card 被移入 Closed 的時間區分當前 sprint 與前一個 sprint 的 card，比較兩個 sprint 的完成數量、平均 cycle time、回流率等指標差異

#### 整體統計分析

- 各 list card 數量分佈
- 成員工作量（從 assignees 動態取得，統計每位成員在各 list 的 card 數量）
- label 分佈
- 完成率：Closed cards 數量 / 總 cards 數量
- 逾期 cards
- 需關注項目彙整：包含逾期 cards、QA Failed cards、長期滯留 Incoming 的 card、WIP 過高警告、高回流率的 card
- 團隊高效率亮點：標記 cycle time 明顯低於平均的 card 以及負責的成員，作為正面案例
- Retrospective 討論議題：基於以上分析自動產出 3 到 5 個建議討論的問題（例如「Code Review 等待時間過長，是否需要調整 review 分配機制？」）

### 第三階段：報告產出

將第二階段的分析結果以純文字和數據形式傳給 markdown-editor subagent，由其負責產生格式完整的報告。

**報告檔案路徑**：`/tmp/sprint-review-YYYY-MM-DD.md`（`YYYY-MM-DD` 替換為當日日期）

傳給 markdown-editor subagent 時，需說明報告應包含以下元素：

- **Card 狀態分佈圖**：使用 Mermaid pie chart 呈現各 list 的 card 數量分佈
- **工作類型分佈圖**：使用 Mermaid pie chart 呈現各 label 的 card 數量分佈
- **各 list Card 明細表格**：包含 card name、assignee、labels、due date、URL 欄位
- **成員工作量統計表格**：呈現每位成員在各 list 的 card 數量
- **需關注項目區塊**：專門列出逾期 cards 和 QA Failed cards
- **Sprint 整體摘要**：包含總卡片數、完成率、本次 sprint 的關鍵數據
- **流程瓶頸分析區塊**：呈現各階段平均停留時間，標記瓶頸階段
- **回流與重工統計**：列出有回流紀錄的 card 及回流路徑
- **跨 Sprint 比較區塊**：對比當前與前一個 sprint 的完成數量、平均 cycle time、回流率等關鍵指標
- **團隊亮點區塊**：展示 cycle time 明顯低於平均的高效率案例及負責成員
- **Retrospective 建議討論議題區塊**：列出 3 到 5 個建議討論的問題
- **報告語言**：繁體中文

## 重要規則

遵守以下規則以確保流程正確執行：

- **分析結果傳遞方式**：不要在 main agent 預先撰寫任何 markdown 格式內容，將分析結果以純文字和數據傳給 markdown-editor subagent
- **subagent 職責分工**：trello-manager subagent 只負責資料取得（CRUD），不進行任何分析；所有分析邏輯由 main agent 執行
- **subagent prompt 格式**：trello-manager subagent prompt 只描述目標和期望回傳的資料，不包含任何 CLI 命令
- **並行處理**：各 list 的查詢彼此獨立，必須並行派發 subagents 以提高效率
- **成員來源**：不預先定義 board members，統一從各 card 的 assignees 動態取得
- **報告語言**：報告內容使用繁體中文
- **效率優先**：所有新增分析都利用第一階段已收集的資料完成，不額外發起 subagent 呼叫或 API 請求
- **卡片生命週期基準**：一張 card 從 Incoming 到 Prod / User Reviewing 的理想時間為 1 週，分析中以此為標準判斷是否異常
- **跨 Sprint 比較資料來源**：僅限 Closed list 的 action history，不額外查詢歷史資料
