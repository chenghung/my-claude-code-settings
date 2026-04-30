# 圖表輸出規則

在 CLI 中，需外部 renderer 顯示的圖表 DSL 直接輸出到 stdout 沒意義，本規則規定改寫入 `.md` 檔或以 kroki.io 預覽。

## 適用語法

受本規則約束的圖表語法：`mermaid`、`plantuml`、`graphviz` / `dot`、LaTeX `tikz`、`d2`，以及其他任何需外部 renderer 才能顯示的圖表 DSL。

## 設計階段委派

產出任何受本規則約束的圖表 DSL 之前，main agent 必須先呼叫 `diagram-designer` skill 完成圖表類型與語法選型；免除觸發的情境以該 skill 的 description 為準。

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 直接輸出到 stdout
1. 呼叫 `diagram-designer` skill 完成圖表類型選型與即時預覽
1. 需要持久保存 → 寫入 `.md` 檔，依 `markdown-editing` rule 委派處理
1. 任何情況下禁止將受本規則約束的 DSL 以圖表為目的直接輸出到 stdout
