---
name: circleci-ops
description: >
  Handle all CircleCI operations by delegating to the circleci-manager subagent. Triggers when the user mentions CircleCI, pastes a circleci.com or app.circleci.com URL, or requests to query pipeline, workflow, or job execution status, fetch failed job logs, artifacts, or test results, rerun a workflow, cancel a workflow or run (rerunning a run is not supported), validate or debug CircleCI config, or inspect CircleCI contexts or environment variables. Trigger keywords: CircleCI, circleci, circleci.com, app.circleci.com. Do not trigger for directly editing the contents of .circleci/config.yml, orb development or publishing, self-hosted runner management, triggering a pipeline or run, or any write operation other than rerun and cancel (such as setting or deleting envvars or context secrets).
---

# CircleCI Ops

## 目標

此 skill 負責將所有 CircleCI 相關操作轉交給 circleci-manager subagent 處理。Main agent 只負責觸發判斷與委派，不進行任何 CLI 操作，也不進行資料解析；所有實際的 CLI 執行與資料解析均由 subagent 全權負責。

## 執行方式

將使用者的意圖和相關資訊傳給 circleci-manager subagent，由 subagent 負責實際操作。

傳給 circleci-manager subagent 的 prompt 需包含以下內容：

- **操作類型**：使用者要做什麼，例如查詢 pipeline、workflow、job 的執行狀態、抓取失敗 job 的 log、artifact 或 test result、重跑 workflow、取消 workflow 或 run（不包含重跑 run）、驗證或除錯 config、查詢 context 或環境變數
- **重跑或取消的目標**：適用於重跑或取消操作，傳使用者指定的唯一一個 workflow ID 或 run ID，或指向單一 workflow 或 run 的 CircleCI URL。pipeline 層級的 URL 對應多個 workflow、只給分支名稱、或以「最新那個」之類的描述指稱目標時，一律視為不明確，先向使用者確認，不代為挑選
- **專案識別資訊**：若使用者提供了 CircleCI URL，將原始 URL 直接傳給 subagent，由 subagent 負責解析；若使用者改以 project slug 或 project-id 指定，則傳該識別資訊
- **config 檔路徑**：適用於 config 驗證或除錯操作
- **分支名稱**：適用於執行狀態查詢
- **context 名稱**：適用於 context 查詢
- **下載目的目錄**：適用於 artifact 下載，僅在使用者有指定時傳入

> [!NOTE]
> subagent prompt 只描述目標與所需事實，不包含任何 CLI 指令。CLI 指令的選擇與執行由 circleci-manager subagent 全權決定。
