# 既有 Infra 現況資料取得程序

此檔在以下兩種情境中動態載入：模式 D 中使用者明確要求在既有 infra 加入新元件時，以及模式 M 任何步驟需要取得既有資源現況時。

依優先順序一（IaC repo）、優先順序二（AWS read-only API）、優先順序三（使用者口述）依序選擇資料來源。盡可能從高優先順序取得；低優先順序作為補齊或 fallback。

## 優先順序一：IaC Repo

偵測工作目錄是否存在以下指標檔案：

- Terraform：副檔名為 `.tf` 的檔案、`.tfvars`
- CDK：`cdk.json`、`cdk.context.json`
- SAM / CloudFormation：`samconfig.toml`、`template.yaml`、`template.yml`、`template.json`
- Serverless Framework：`serverless.yml`
- Pulumi：`pulumi.yaml`

### Terraform

允許使用以下純讀指令取得 baseline：

- `terraform fmt -check`
- `terraform validate`
- `terraform state list`
- `terraform state show`
- `terraform show -json`

絕對禁止執行 `terraform apply`、`terraform destroy`、`terraform import`、`terraform state mv`、`terraform state rm` 或任何會修改 state 或實際資源的指令。

### CDK

允許讀取 `cdk.context.json` 與 `cdk.out/` 目錄下的合成結果。絕對禁止執行 `cdk deploy`、`cdk destroy`。

### CloudFormation 與 SAM

允許讀取 template 檔案。絕對禁止透過本 skill 執行 `aws cloudformation deploy`、`create-stack`、`update-stack`、`delete-stack` 或 `sam deploy`。

### IaC Baseline 的重要限制

IaC 推導出的 baseline 與實際 AWS 部署之間可能存在差距（例如存在 click-ops 手動變更造成的 drift），須在最終報告中明確標註此假設。建議在重要決策前以優先順序二（read-only API）抽樣驗證關鍵資源的實際狀態。

## 優先順序二：AWS Read-Only API

### 啟用條件

每個 session 中第一次需要此來源時，必須先詢問使用者授權，不可預設啟用。詢問範例：

> 本次分析需要直接從 AWS 帳號讀取現況以驗證 IaC 推導的 baseline，是否授權我使用 read-only AWS CLI 指令存取？預設關閉，等待您明示同意才會啟用。

### 允許的指令範圍

允許的動詞前綴：`describe-`、`list-`、`get-`。

例外排除：`get-session-token`、`get-federation-token` 等取得 credential 的呼叫絕對禁止。

`aws sts get-caller-identity` 僅允許用於確認帳號身分，其輸出中的 access key ID 或 session 資訊不可寫入 context。

### 執行前提

所有 read-only 呼叫須使用 read-only IAM role 或 read-only profile。本 skill 不負責建立該 profile，假設由使用者預先設定好。本 skill 不主動執行 `aws configure` 或修改 `~/.aws/credentials`。

### 執行細節

每次實際下指令前先在訊息中明示要執行的指令，等使用者確認後再執行。批次操作時可一次列出多個指令請使用者一次確認。

### 資訊保密

以下資訊可入 planning file 與最終報告：

- IAM policy 內含的具體 resource ARN
- KMS key id
- Secrets Manager 名稱
- VPC id、subnet id

以下資訊絕對不可入 context、planning file 或最終報告：

- access key、secret access key、session token
- 明文密碼
- Secrets Manager 中的具體 secret 值

## 優先順序三：使用者口述

### 啟用條件

前兩者不可得，或使用者明確拒絕授權 API 存取時啟用。

### 執行方式

主動列出本次討論需要的關鍵資訊清單請使用者補齊，包含：

- 被變更或新增資源的類型與身分（service name、resource id）
- 相關 VPC 與 subnet 的 CIDR
- 所有上下游依賴
- 流量規模
- 現有 SLA 與 SLO
- 現有監控配置

明示告知使用者：口述模式下的風險評估精度受限，建議提供任何可貼上的 console 截圖、配置檔片段、IaC 程式碼片段以提升精度。

## 安全邊界（無條件適用）

以下限制不論使用哪個優先順序來源皆無條件適用：

- 絕對禁止執行任何 mutate API
- 絕對禁止執行任何 IaC 部署指令
- 絕對禁止將 credentials 具體值寫入 context、planning file 或最終報告
- 絕對禁止透過 assume-role 進入非 read-only role

偵測到自己即將觸碰上述禁區時，必須立即停止並向使用者報告，並建議改委派 `terraform-engineer` 處理。
