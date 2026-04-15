---
globs: "**/*.md"
---

# Markdown 編輯規則

建立或修改任何 markdown 檔案時，必須使用 `markdown-editor` subagent 執行實際的編輯工作。

## Main Agent 的責任

Main agent 只負責提供以下資訊給 subagent，內容必須以**純文字**呈現：

- **目標檔案路徑**：要建立或修改的檔案絕對路徑
- **修改意圖**：說明要新增、更新或刪除哪些部分
- **內容重點摘要**：以條列式純文字描述要傳達的資訊

## 明確禁止的行為

Main agent 傳給 subagent 的 prompt 必須是純文字，不得夾帶任何 markdown 格式語法。所有實際的格式決策由 subagent 自行判斷處理。
