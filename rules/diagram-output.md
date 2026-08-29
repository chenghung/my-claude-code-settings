# 圖表輸出規則

在 CLI 中，需外部 renderer 顯示的圖表 DSL 直接輸出到 stdout 沒意義，本規則規定改寫入 `.md` 檔，或透過本地／遠端 renderer 預覽。

## 適用語法

受本規則約束的圖表語法：`mermaid`、`plantuml`、`graphviz` / `dot`、LaTeX `tikz`、`d2`，以及其他任何需外部 renderer 才能顯示的圖表 DSL。

## 設計階段委派

產出任何受本規則約束的圖表 DSL 之前，決定圖表類型並撰寫該 DSL 內容的一方必須先呼叫 `diagram-designer` skill 完成圖表類型與語法選型；免除觸發的情境以該 skill 的 description 為準。此義務只跟隨決定類型並撰寫內容的角色，不適用於僅將已完成的 DSL 文字轉寫、持久化或傳輸到檔案或外部服務的角色。

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 直接輸出到 stdout
1. 呼叫 `diagram-designer` skill 完成圖表類型與語法選型；此步驟對所有產出方一律適用，不得因產出方的能力差異而豁免
1. 具備執行即時預覽所需能力時 → 以該能力呼叫 `diagram-designer` skill 提供的方式進行即時預覽；不具備者略過本步驟，直接進入下一步
1. DSL 的最終去處屬於由其他流程管轄的內容組裝時 → 不依 `markdown-editing` rule 委派，改依該內容組裝流程本身的規範處理
1. 除前項情境外，需要持久保存 → 寫入 `.md` 檔，依 `markdown-editing` rule 委派處理
1. 任何情況下禁止將受本規則約束的 DSL 以圖表為目的直接輸出到 stdout
