---
name: circleci-ops
description: >
  Handle all CircleCI operations by delegating to the circleci-manager subagent. Triggers when the user mentions CircleCI, pastes a circleci.com or app.circleci.com URL, or requests to query pipeline, workflow, or job execution status, validate or debug CircleCI config, or inspect CircleCI contexts or environment variables. Trigger keywords: CircleCI, circleci, circleci.com, app.circleci.com
---

# CircleCI Ops

## 目標

此 skill 負責將所有 CircleCI 相關操作轉交給 circleci-manager subagent 處理。Main agent 只負責觸發判斷與委派，不進行任何 CLI 或 API 操作，也不進行資料解析；所有實際的 CLI 執行、唯讀 API 呼叫與資料解析均由 subagent 全權負責。

## 執行方式

將使用者的意圖和相關資訊傳給 circleci-manager subagent，由 subagent 負責實際操作。

傳給 circleci-manager subagent 的 prompt 需包含以下內容：

- **操作類型**：使用者要做什麼，例如查詢 pipeline、workflow、job 的執行狀態、驗證或除錯 config、查詢 context 或環境變數
- **專案識別資訊**：若使用者提供了 CircleCI URL，將原始 URL 直接傳給 subagent，由 subagent 負責解析；若使用者改以 project slug 或 project-id 指定，則傳該識別資訊
- **config 檔路徑**：適用於 config 驗證或除錯操作
- **分支名稱**：適用於執行狀態查詢
- **context 名稱**：適用於 context 查詢

> [!NOTE]
> subagent prompt 只描述目標與所需事實，不包含任何 CLI 指令或 API 端點。CLI 與 API 的選擇與執行由 circleci-manager subagent 全權決定。
