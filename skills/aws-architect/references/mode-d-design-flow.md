# 模式 D：AWS 架構設計流程

此檔案僅在 aws-architect skill 進入模式 D（Design）時動態載入，用於指導 AWS 架構設計的執行步驟，涵蓋 greenfield 新建與在既有 infra 中加入新元件兩種情境。

每個步驟結束時必須以 **CHECKPOINT** 明確標示，等待使用者確認後才能進入下一步。執行期間每則訊息都須在開頭標示目前所在步驟，例如「【步驟二：需求釐清】」。

## 步驟一：啟動 Planning File

若使用者已透過 planning-with-files skill 觸發本流程，直接沿用現有的 planning file。否則主動觸發 planning-with-files skill 建立新的 planning file，後續所有步驟的輸出都寫入此檔。

**CHECKPOINT** — 確認 planning file 已就緒後繼續。

## 步驟二：需求釐清

先請使用者自由描述以下三個面向，不設格式限制：

- 要解決的問題
- 預期使用情境
- 業務目標

收到描述後，委派 deep-thinking skill 產生 clarifying questions。問題必須涵蓋但不限於：

- 規模假設與成長預期
- 預算範圍
- 效能 SLA
- 可用性目標（含 RTO 與 RPO）
- 合規與資料主權要求
- 團隊運維能力
- 既有技術棧與整合需求
- 安全需求
- 未來演進方向
- 是否需相容於既有 infra

將問題清單整理後呈現給使用者，逐輪收集答案，每輪結束將問答記錄寫入 planning file。

**CHECKPOINT** — 確認需求已充分釐清後繼續。

## 步驟三：既有 Infra 現況判斷

若使用者明確要求在既有 infra 中加入新元件，必須先依 `references/current-state-discovery.md` 的程序取得現況資料。特別關注以下項目：

- VPC CIDR 是否有餘裕
- Subnet 與 routing table 結構
- IAM 結構與既有角色
- 既有 security group 規則
- 是否會觸及 Service Quotas 限制
- 現有監控與告警體系

將現況摘要寫入 planning file，並明確標註每項資料的來源（IaC、AWS API 或使用者口述）。

若為 greenfield 情境則跳過此步驟。

**CHECKPOINT** — 確認現況資料已完整取得（或確認為 greenfield 已跳過）後繼續。

## 步驟四：需求與約束 Spec

彙整前兩步驟的所有輸入，輸出結構化文件，包含以下五個區塊：

- **Goals** — 設計目標
- **Non-goals** — 明確不在範圍內的項目
- **Constraints** — 硬性約束（預算上限、合規要求、技術棧限制等）
- **Open Questions** — 尚未釐清的問題
- **Assumptions** — 在資訊不足時所做的假設

將此 spec 寫入 planning file。

**CHECKPOINT** — 確認 spec 內容無誤後繼續。

## 步驟五：分層服務選型

按以下分層逐層選定 AWS 服務或第三方方案，每層選型理由寫入 planning file：

- **Compute layer**
- **Storage layer**
- **Database layer**
- **Network layer**
- **Security layer**（IAM、KMS、Secrets Manager 等）
- **Observability layer**（CloudWatch、X-Ray 或第三方）
- **Deployment 與 CI/CD layer**

若某層有兩個以上強候選方案，委派 deep-thinking skill 進行比較，比較結果連同最終選型寫入 planning file。

**CHECKPOINT** — 確認各層選型完成後繼續。

## 步驟六：架構圖選型與繪製

委派 diagram-designer skill 完成圖表類型選型，由 diagram-designer 決定使用哪種 DSL（mermaid、d2 等）。產出的圖表 DSL 保留供最終報告嵌入使用。

**CHECKPOINT** — 確認架構圖草稿完成後繼續。

## 步驟七：Well-Architected 自審

委派 deep-thinking skill 對草案架構逐支柱套用 AWS Well-Architected Framework 六大支柱：

- Operational Excellence
- Security
- Reliability
- Performance Efficiency
- Cost Optimization
- Sustainability

每個支柱標示潛在風險與對應的改善建議，結果寫入 planning file。

**CHECKPOINT** — 確認自審完成且改善建議已記錄後繼續。

## 步驟八：Cost 方向估算

識別主要 cost driver，包含但不限於：compute、data transfer、storage、licensing、support tier。

給出方向性比較，說明哪幾項是 cost dominant，以及是否存在明顯的成本優化機會，例如：

- Savings Plans 或 Reserved Instances
- Spot Instances
- S3 storage class 選擇

明確聲明：本 skill 不做精確美元金額估算。需要精確估算時，請使用 AWS Pricing Calculator、AWS Pricing API 或 Cost Explorer。

**CHECKPOINT** — 確認 cost 分析已呈現後繼續。

## 步驟九：產出設計藍圖報告

透過 hackmd-notes skill 建立 HackMD 報告。報告章節依照 `references/output-templates.md` 中模式 D 的模板。報告末尾的 **Next Steps** 章節須明確標示：設計階段結束，交棒給 terraform-engineer skill 進入 IaC 實作階段。

**CHECKPOINT** — 確認報告已成功建立並取得 HackMD 連結後，本流程完成。

## 共通原則

- 所有深度分析委派給 deep-thinking skill
- 架構圖透過 diagram-designer skill 產出
- HackMD 報告透過 hackmd-notes skill 建立
- 本 skill 不撰寫任何 IaC 程式碼
- 所有假設與未知項目明確標示為 open questions
- 範圍最小化，只解決使用者描述的設計問題
