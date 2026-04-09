---
name: trello-cards
description: >
  Handle all Trello card operations by delegating to the trello-manager subagent. Triggers when the user mentions Trello, pastes a trello.com URL, or requests query, create, update, delete, comment, or move operations on Trello cards. Trigger keywords: trello, Trello, trello.com
---

# Trello Cards

- [目標](#目標)
- [禁止行為](#禁止行為)
- [執行方式](#執行方式)

## 目標

此 skill 負責將所有 Trello 相關操作轉交給 trello-manager subagent 處理。Main agent 只負責觸發判斷與委派，不進行任何邏輯處理。

## 禁止行為

> [!WARNING]
> 嚴禁以下任何方式直接存取 Trello 內容，違反此規則將導致操作結果不可靠。

禁止使用的方式包括：

- `curl` 或 `wget` 等命令列 HTTP 工具
- `WebFetch` 或任何 HTTP 請求工具
- 任何非 Trello CLI 的替代手段
- 直接讀取 `~/.trello-cli/default/config.json` 中的 API key 或 token

所有操作必須透過 trello-manager subagent 執行。

## 執行方式

將使用者的意圖和相關資訊傳給 trello-manager subagent，由 subagent 負責實際的 CLI 操作。

傳給 trello-manager subagent 的 prompt 需包含以下內容：

- **操作類型**：使用者要執行的動作（查詢、建立、更新、刪除、留言、搬移等）
- **Card URL**：若使用者提供了 trello.com URL，將原始 URL 直接傳給 subagent，由 subagent 負責解析
- **Board 名稱**：若使用者有指定操作目標的 board
- **操作內容**：使用者希望新增或修改的 card 內容（適用於建立與更新操作）

> [!NOTE]
> subagent prompt 只描述目標與所需資訊，不包含任何 CLI 命令。CLI 命令的選擇與執行由 trello-manager subagent 全權負責。
