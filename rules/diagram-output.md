# 圖表輸出規則

- [適用語法](#適用語法)
- [預設行為](#預設行為)
- [允許情境](#允許情境)
- [判斷流程](#判斷流程)

在 CLI 終端機中，需要外部 renderer 才能顯示的圖表語法輸出到 stdout 後，使用者只會看到原始文字，無法看到圖形，純粹浪費 output token。本規則禁止此類語法直接出現在聊天訊息中，並規定應改寫入 `.md` 檔案讓使用者在支援預覽的環境中查看。

## 適用語法

下列圖表語法受本規則約束：

- `mermaid`
- `plantuml`
- `graphviz` / `dot`
- LaTeX `tikz`
- `d2`
- 其他任何需要外部 renderer 才能顯示為圖像的 markdown 圖表語法

## 預設行為

禁止將上述語法直接輸出到聊天訊息（stdout）。若任務需要產生此類圖表，必須寫入 `.md` 檔案：

- **持久性圖表**：寫入正式 `.md` 檔案，依 `markdown-editing` rule 委派給 `markdown-editor` 或 `obsidian-md-editor` 處理；main agent 不得自行寫入。
- **暫時性視覺化**：若僅是任務過程中的暫時性圖表，依 `tmp-file-usage` rule 寫入工作區的 `.tmp` 目錄。

## 允許情境

以下兩種情況可直接輸出到 stdout，不受本規則限制：

- **使用者明確要求原始碼**：例如「給我這段流程圖的 mermaid 原始碼讓我複製貼到別處」，此時圖表語法本身就是使用者要的純文字產出。
- **ASCII 圖示**：以 box-drawing 字元或純文字繪製的示意圖，在終端機中可直接觀看，不需要外部 renderer。

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 允許直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 允許直接輸出到 stdout
1. 其他情況需產生 mermaid、plantuml、graphviz、tikz、d2 等內容 → 必須寫入 `.md` 檔案，依 `markdown-editing` rule 委派處理
