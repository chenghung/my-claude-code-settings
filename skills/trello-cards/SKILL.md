---
name: trello-cards
description: >
  Handle all Trello card operations by delegating to the trello-manager subagent. Triggers when the user mentions Trello, pastes a trello.com URL, or requests query, create, update, delete, comment, or move operations on Trello cards. Trigger keywords: trello, Trello, trello.com
---

# Trello Cards

- [目標](#目標)
- [執行方式](#執行方式)

## 目標

此 skill 負責將所有 Trello 相關操作轉交給 trello-manager subagent 處理。Main agent 只負責觸發判斷與委派，不進行任何邏輯處理。

## 執行方式

將使用者的意圖和相關資訊傳給 trello-manager subagent，由 subagent 負責實際的 CLI 操作。

傳給 trello-manager subagent 的 prompt 需包含以下內容：

- **操作類型**：使用者要執行的動作（查詢、建立、更新、刪除、留言、搬移等）
- **Card URL**：若使用者提供了 trello.com URL，將原始 URL 直接傳給 subagent，由 subagent 負責解析
- **Board 名稱**：若使用者有指定操作目標的 board
- **操作內容**：使用者希望新增或修改的 card 內容（適用於建立與更新操作）

> [!NOTE]
> subagent prompt 只描述目標與所需資訊，不包含任何 CLI 命令。CLI 命令的選擇與執行由 trello-manager subagent 全權負責。
