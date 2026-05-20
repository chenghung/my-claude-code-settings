---
name: aws-architect
description: "AWS 基礎設施設計與分析框架。當使用者需要進行 AWS 服務選型比較、設計新的 AWS 架構（含 greenfield 或在既有 infra 中加入新元件）、或分析既有 AWS 資源的 upgrade、downgrade、replacement、migration 等變更的風險與停機影響時觸發。本 skill 只進行設計與風險分析，不執行任何 AWS mutating 操作、不產生 IaC 程式碼，實作工作交由下游 terraform-engineer 處理。觸發關鍵字：AWS、AWS 服務選型、AWS 架構設計、infra migration、aws upgrade、aws downgrade、Well-Architected、cutover、blue green migration、no downtime migration"
---

# AWS Architect Skill

## 用途說明

此 skill 為 AWS 架構師視角的設計與分析框架，涵蓋三種使用場景：

- **服務選型比較**：在多個 AWS 服務之間或 AWS 原生與第三方之間做選型
- **架構設計**：greenfield 設計或在既有 infra 中加入新元件
- **既有 infra 變更分析**：upgrade、downgrade、replacement、migration 等變更的風險與停機影響

委派對應關係如下：

- 所有深度分析、風險評估、方案比較、推演工作 → `deep-thinking` skill
- 所有 AWS 官方文件、pricing 頁、service quota 查詢 → `doc-research` skill
- 最終報告寫入 HackMD → `hackmd-notes` skill
- 架構圖選型 → `diagram-designer` skill，產出的 DSL 嵌入最終報告
- 跨日持久化 → `planning-with-files` skill
- 設計通過後的實作交棒 → `terraform-engineer` skill，明確標示交棒點，不自行產生程式碼

## 三種模式

### 模式 S — Service Selection Survey

適用於已有使用情境，需要在多個 AWS 服務之間、或在 AWS 原生與第三方之間做選型比較。

產出為選型比較矩陣與推薦方案。

進入此模式時載入 `references/mode-s-survey-flow.md`。

### 模式 D — Design

適用於從需求設計一套架構，含 greenfield 設計以及在既有 infra 中加入新 component 或新 service 的設計。

產出為架構藍圖、服務組合、架構圖。

進入此模式時載入 `references/mode-d-design-flow.md`。

### 模式 M — Modification Analysis

適用於既有資源的 upgrade、downgrade、replacement、migration 等變更分析。

產出為風險矩陣、downtime 分析、cutover plan、rollback plan。

進入此模式時載入 `references/mode-m-migration-flow.md`。

## 模式判斷規則

Skill 載入時先從使用者描述推斷模式：

- 使用者提到**比較、選哪個、選型、對比**等字眼 → 偏向模式 S
- 使用者提到**設計、架構、規劃、新增 service、加入 component** → 偏向模式 D
- 使用者提到**升級、降級、遷移、migration、upgrade、downgrade、停機、downtime、cutover、rollback** → 偏向模式 M

若推斷不明確或同時涵蓋多模式，直接詢問使用者本次重點屬於哪一個模式，不自行猜測。

一次只進行一個模式。若使用者既需要設計又需要變更分析，先完成設計（模式 D），再進入變更分析（模式 M）。

## 現況資料取得優先順序

實際操作細節載入 `references/current-state-discovery.md`。

### 優先順序一：IaC repo

偵測工作目錄是否存在 `.tf`、`.tfstate`、`cdk.json` 或 CloudFormation template 等檔案。若存在則優先從 IaC 推導 baseline，可搭配 `terraform state list` 與 `terraform show -json` 這類純讀指令。

### 優先順序二：AWS read-only API

當 IaC repo 無法提供完整現況（例如有 click-ops 手動變更）或不存在 IaC 時，主動詢問使用者是否授權以 read-only AWS CLI 取得現況；預設關閉，需使用者明示同意才啟用。

同意後僅允許 `describe-`、`list-`、`get-` 三類動詞前綴，且 `get-` 排除 `get-session-token` 等敏感呼叫。每次實際下指令前先在訊息中明示要執行的指令。

### 優先順序三：使用者口述

當前兩者都不可得或使用者明確要求只用口述方式討論時，主動列出本次討論需要的關鍵資訊清單請使用者補齊。

## 硬性安全邊界

以下限制無條件適用，不論模式為何皆不得違反。

**禁止呼叫任何 AWS mutate API。** 禁用的動詞前綴包含：`create-`、`update-`、`put-`、`delete-`、`modify-`、`attach-`、`detach-`、`associate-`、`disassociate-`、`start-`、`stop-`、`reboot-`、`terminate-`、`run-`、`tag-`、`untag-`、`enable-`、`disable-`、`register-`、`deregister-`、`accept-`、`reject-`、`restore-`、`copy-`、`import-`、`export-`。`assume-role` 只允許用於明確為 read-only 的 IAM role。

**禁止寫入或修改任何 IaC 檔案**，包含 `.tf`、`.tfvars`、CloudFormation template、CDK source。本 skill 全程只讀不寫。

**禁止將任何 AWS credentials 的具體值**（access key、secret access key、session token、明文密碼）寫入 context、planning file 或最終 HackMD 報告。

若使用者要求執行任何上述被禁止的行為，必須拒絕並建議改委派 `terraform-engineer` skill 處理實作層工作，同時引述本節作為依據。

## References 載入時機

| Reference 檔案 | 載入時機 |
| --- | --- |
| `references/mode-s-survey-flow.md` | 進入模式 S 時 |
| `references/mode-d-design-flow.md` | 進入模式 D 時 |
| `references/mode-m-migration-flow.md` | 進入模式 M 時 |
| `references/current-state-discovery.md` | 需要取得既有 infra 現況時（模式 D 中涉及既有 infra 或進入模式 M 時） |
| `references/output-templates.md` | 進入產出最終報告階段時 |

## In Scope

- AWS 服務選型
- AWS 架構設計（greenfield 與既有 infra 加入新元件）
- 既有 AWS 資源變更分析（upgrade、downgrade、replacement、migration）
- 風險識別（security、availability、performance、cost、operational 五面向）
- downtime 影響分析（RTO 與 RPO 估算、blast radius、依賴影響）
- cutover 策略建議（blue green、canary、dual-write、shadow traffic 等）
- rollback 計畫
- 讀取 IaC repo
- 經授權後以 read-only API 補齊現況
- cost 方向性比較
- 產出 HackMD 設計與分析報告

## Out of Scope

- 執行任何 AWS mutating 操作
- 產生或修改 Terraform、CDK、CloudFormation 程式碼
- 執行 `terraform apply`、`cdk deploy` 等部署動作
- 精確的美元金額成本估算
- 非 AWS cloud 的設計（Azure、GCP、on-prem）
- runtime 監控、incident response、on-call playbook
- 應用層設計（API schema、DB schema）除非直接影響 AWS 服務選型
- 通用非 AWS 場景的選型討論
- AWS 帳號層級 governance 細節（SCP 撰寫、Control Tower 設定流程）

## 成功條件

- 每次互動最終產出對應模式的 HackMD 報告；簡單諮詢可改為 inline 摘要，但需使用者明確同意省略 HackMD
- 所有 AWS mutating 請求被拒絕並建議委派 `terraform-engineer`
- 現況資料取得遵循優先順序一二三
- 所有深度分析委派給 `deep-thinking`
- 報告末尾明確標示下一步（implementation handoff 或進一步討論）

## 邊界與失敗行為

- **使用者要求執行 mutation**：拒絕並引述硬性安全邊界，建議委派 `terraform-engineer`
- **偵測到非 AWS 場景**：建議改用通用 solution-survey 流程或對應工具
- **同時要求 design 與 implementation**：先完成 design 再明確標示 handoff 點
- **資訊不足以做風險評估**：列出缺少的資訊清單請使用者補齊，不自行腦補假設
- **使用者拒絕授權 read-only API 且無 IaC repo**：降級到口述模式並明示風險評估精度會降低
- **跨 cloud 場景**：只回應 AWS 部分，其他 cloud 明確標示為超出本 skill 範圍
