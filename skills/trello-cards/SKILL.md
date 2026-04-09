---
name: trello-cards
description: >
  Handle all Trello card operations by delegating to the trello-manager subagent. Triggers when the user mentions Trello, pastes a trello.com URL, or requests query, create, update, delete, comment, or move operations on Trello cards. Trigger keywords: trello, Trello, trello.com
---

# Trello Cards

- [目標](#目標)
- [觸發情境](#觸發情境)
- [URL 解析規則](#url-解析規則)
- [禁止行為](#禁止行為)
- [執行方式](#執行方式)

## 目標

此 skill 負責將所有 Trello 相關操作轉交給 trello-manager subagent 處理。Main agent 本身不直接執行任何 Trello CLI 命令，只負責解析使用者意圖並將資訊傳遞給 subagent。

## 觸發情境

符合以下任一條件時，此 skill 即應被觸發：

- 使用者訊息中出現 `Trello` 或 `trello` 關鍵字
- 使用者貼上 `trello.com` 的 URL
- 使用者要求對 Trello cards 執行以下任一操作：查詢、建立、更新、刪除、留言、搬移

## URL 解析規則

當使用者提供 trello.com URL 時，main agent 需先從 URL 中提取 card short ID，再將其傳給 trello-manager subagent。

Trello card URL 的格式如下：

```text
https://trello.com/c/{shortLink}/{slug}
```

其中 `shortLink` 即為 card ID，`slug` 為選擇性的 card 標題文字。例如 `https://trello.com/c/abc123/some-card-title` 中，card ID 為 `abc123`。

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
- **Card ID**：若使用者提供了 URL，附上已解析的 card short ID
- **Board 名稱**：若使用者有指定操作目標的 board
- **操作內容**：使用者希望新增或修改的 card 內容（適用於建立與更新操作）

> [!NOTE]
> subagent prompt 只描述目標與所需資訊，不包含任何 CLI 命令。CLI 命令的選擇與執行由 trello-manager subagent 全權負責。
