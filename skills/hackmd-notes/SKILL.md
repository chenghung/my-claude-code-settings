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

當操作類型為**匯出或取得筆記完整內容**時，subagent 會將筆記內容寫入暫存檔案，並回報檔案路徑。Main agent 後續可視需要直接讀取該檔案。

Subagent 不會在回報中包含筆記內容本身，以避免同一份內容重複佔用 context window 的 token。

當使用者明確要求取得最新版本時（例如使用「重新取得」、「最新版」等用語），main agent 應在 prompt 中指示 subagent 強制重取。

> [!NOTE]
> subagent prompt 只描述目標與所需資訊，不包含任何 CLI 命令。CLI 命令的選擇與執行由 hackmd-manager subagent 全權負責。
