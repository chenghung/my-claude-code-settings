# Output Templates

此檔在各模式進入最終報告產出階段時載入。報告本身透過 hackmd-notes skill 建立；本檔僅描述各模式的章節結構與每章節應包含什麼內容，實際 HackMD 內文格式由 hackmd-notes 與 LLM 自行決定。

## 模式 S 報告模板

**標題建議格式**：AWS Service Selection Survey — ＜簡短描述使用情境＞

### Background 與 Use Case

說明業務情境、觸發此次選型的背景，以及最終使用者或系統的使用方式。

### Requirements 與 Constraints

列出功能需求、非功能需求（效能、可用性、擴展性等），以及技術、成本、合規方面的限制條件。

### Solution Candidates

每個候選方案各佔一個子章節，內容包含：

- Brief intro：方案概述
- Pros：優點
- Cons：缺點
- Limitations 與 Risks：限制與潛在風險
- 適合度評估：針對本次需求的契合程度說明
- AWS Service Quotas 影響：相關配額限制與是否可申請調整
- 官方文件 URL：列於此處並同步收錄至 References

### Comparison Matrix

表格形式，列出每個方案在各評估維度的 1–10 評分。維度須與需求對應，並涵蓋 Well-Architected 相關支柱、cost direction、quota fit。

### Recommendation

- 推薦哪一個方案
- 推薦理由
- 會改變推薦的情境
- 已知取捨

### References

每個外部 URL 標示對應方案名稱與類型。類型包含但不限於：official docs、pricing、blog post、benchmark report、whitepaper。

---

## 模式 D 報告模板

**標題建議格式**：AWS Architecture Design — ＜簡短描述設計目標＞

### Goals 與 Non-Goals

明確界定本次架構設計的目標範圍與刻意排除的項目。

### Constraints

從四個面向說明限制條件：

- 技術限制
- 成本限制
- 合規限制
- 運維能力限制

### Existing Infra Context

若是在既有 infra 上加入新元件，列出相關現況摘要與每項資料的來源（IaC、AWS API 或使用者口述）。Greenfield 專案可省略此章節。

### Service Selection by Layer

依下列各層說明服務選型與理由：

- Compute
- Storage
- Database
- Network
- Security
- Observability
- CI/CD

### Architecture Diagram

嵌入 diagram-designer 產出的 DSL，並附簡短文字說明架構全貌與資料流向。

### Well-Architected Self-Review

逐項說明本架構對 AWS Well-Architected Framework 六支柱的契合度與潛在風險：

- Operational Excellence
- Security
- Reliability
- Performance Efficiency
- Cost Optimization
- Sustainability

### Cost Model

說明主要 cost driver、相對成本方向、可能的成本優化機會。本章節明確聲明不做精確估算，僅提供方向性參考。

### Open Questions 與 Assumptions

列出所有尚未明確的灰色地帶，一律標示為 assumption，不得當作已確認事實陳述。

### Next Steps

明確標示交棒給 terraform-engineer 進入 IaC 實作，並列出尚待釐清的決策點。

### References

每個外部 URL 標示對應服務或主題名稱與類型。

---

## 模式 M 報告模板

**標題建議格式**：AWS Modification Analysis — ＜簡短描述變更目標＞

### Change Goals 與 Constraints

說明此次變更的目標，以及 downtime 限制與風險容忍度。

### Current State Summary

描述變更前的現況。每項資料須明確標註來源：IaC、AWS API 或使用者口述。

### Target State

描述變更後的預期狀態。

### Change Diff

以逐項比對方式呈現 current state 與 target state 的差異。

### Risk Matrix

從五個面向評估風險，每項說明風險等級（高／中／低）、觸發條件、緩解措施：

- Security
- Availability
- Performance
- Cost
- Operational

### Downtime Analysis

- In-place 與 zero-downtime 兩種路徑的評估
- 預估 RTO 與 RPO
- Blast radius 描述
- No downtime 可達性結論

### Cutover Strategy

說明推薦策略與推薦理由，並說明為何不採用其他策略。

### Rollback Plan

- Rollback 觸發條件
- 步驟描述
- 資料一致性處理方式

### Step-by-step Runbook

逐階段列出操作步驟，包含：

- 每個步驟的具體操作
- 需要 terraform-engineer 處理的 IaC 變更摘要
- 以 read-only 指令（如 `aws describe-*`、`terraform plan`）進行的驗證方式
- 關鍵節點以 **CHECKPOINT** 標記

### Validation Checklist

列出變更完成後的驗收項目清單。

### Next Steps

明確標示交棒給 terraform-engineer 進入實作，或建議先在 dry-run / staging 環境驗證 runbook 後再進行。

### References

每個外部 URL 標示對應服務或主題名稱與類型。

---

## 共通要求

以下要求適用於所有模式的報告：

- 以繁體中文撰寫報告全文
- 每個外部 URL 須在 References 章節集中列出並標註類型
- 任何尚未明確的灰色地帶須明示為 assumption，不得當作已確認事實陳述
- 不在報告中包含任何 credentials 或 secrets 的具體值
- 不包含人工維護的 Table of Contents
