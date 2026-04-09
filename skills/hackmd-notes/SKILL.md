---
name: hackmd-notes
description: >
  Handle all HackMD note operations by delegating to the hackmd-manager subagent. Triggers when the user mentions HackMD, pastes a hackmd.io URL, or requests search, create, update, delete, or export operations on HackMD notes. Trigger keywords: hackmd, HackMD, hackmd.io
---

# HackMD Notes

- [目標](#目標)
- [禁止行為](#禁止行為)
- [執行方式](#執行方式)

## 目標

此 skill 負責將所有 HackMD 相關操作轉交給 hackmd-manager subagent 處理。Main agent 只負責判斷觸發時機並委派任務，不進行任何資料解析或邏輯處理，所有實際操作均由 subagent 全權負責。

## 禁止行為

> [!WARNING]
> 嚴禁以下任何方式直接存取 HackMD 內容，違反此規則將導致操作結果不可靠。

禁止使用的方式包括：

- `curl` 或 `wget` 等命令列 HTTP 工具
- `WebFetch` 或任何 HTTP 請求工具
- 任何非 HackMD CLI 的替代手段

所有操作必須透過 hackmd-manager subagent 執行。

## 執行方式

將使用者的意圖和相關資訊傳給 hackmd-manager subagent，由 subagent 負責實際的 CLI 操作。

傳給 hackmd-manager subagent 的 prompt 需包含以下內容：

- **操作類型**：使用者要執行的動作（搜尋、建立、更新、刪除、匯出等）
- **HackMD URL**：若使用者提供了 hackmd.io URL，將原始 URL 直接傳給 subagent，由 subagent 負責解析
- **操作內容**：使用者希望新增或修改的筆記內容（適用於建立與更新操作）
- **其他條件**：搜尋關鍵字或其他使用者指定的篩選條件

當操作類型為**匯出或取得筆記完整內容**時，main agent 必須在 prompt 中指定暫存檔案路徑，格式為 `/tmp/hackmd-export-<note-id>.md`，其中 `note-id` 為筆記在 HackMD 上的實際 ID。使用筆記 ID 作為識別碼的好處是，同一篇筆記重複匯出時會覆蓋舊檔，避免產生多餘的暫存檔。Subagent 寫入檔案後只需回報成功與檔案路徑，不需回傳筆記內容本身。Main agent 後續可視需要直接讀取該檔案。

當使用者明確要求取得最新版本時（例如使用「重新取得」、「最新版」等用語），main agent 應在 prompt 中指示 subagent 強制重取，忽略既有快取。

Subagent 在執行匯出操作時，必須嚴格依照以下步驟順序執行，不得跳過任何步驟：

1. **檢查本地快取檔案是否存在** — 檢查 main agent 指定的暫存檔案路徑是否已存在。若檔案存在，且 main agent 未指示強制重取，則直接回報使用快取並提供檔案路徑，結束流程。若檔案不存在，或 main agent 指示強制重取，則繼續步驟二。
1. **執行匯出** — 透過 HackMD CLI 匯出筆記完整內容，將內容寫入 main agent 指定的暫存檔案路徑，回報匯出成功與檔案路徑，結束流程。

> [!IMPORTANT]
> 此快取機制的目的是避免筆記全文經由 subagent 回傳結果進入 main agent 的 context window，造成同一份內容重複佔用 token。所有情況下，subagent 均不得在回報中包含筆記內容本身。

> [!NOTE]
> subagent prompt 只描述目標與所需資訊，不包含任何 CLI 命令。CLI 命令的選擇與執行由 hackmd-manager subagent 全權負責。
