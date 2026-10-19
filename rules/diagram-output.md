# 圖表輸出規則

在 CLI 中，需外部 renderer 顯示的圖表 DSL 直接輸出到 stdout 沒意義，本規則規定改寫入 `.md` 檔，或透過本地／遠端 renderer 預覽。例外是 CLI 本身能在對話中畫出的 Mermaid，見「對話中直接畫 Mermaid」一節。

## 適用語法

受本規則約束的圖表語法：`mermaid`、`plantuml`、`graphviz` / `dot`、LaTeX `tikz`、`d2`，以及其他任何需外部 renderer 才能顯示的圖表 DSL。

## 對話中直接畫 Mermaid

在 Claude Code（裝有 prismantis mod）或 Codex 中，圖若是為了在對話中即時說明，可以直接在回覆中用 `mermaid` fenced code block 畫以下 5 種：`flowchart`（含 `graph`）、`sequenceDiagram`、`stateDiagram-v2`、`classDiagram`、`erDiagram`。此時不呼叫 `diagram-designer`，也不執行 `render.sh`。

- OpenCode、Antigravity 不適用本例外。
- 其他 Mermaid 種類，或要寫進檔案保存的圖，不適用本例外，照判斷流程處理。
- 圖過寬或過長時，CLI 會改印原始碼：保持精簡，畫不下就拆成多張圖，或改走判斷流程。
- 5 種都不適合表達時，回到判斷流程，呼叫 `diagram-designer`。

## 設計階段委派

產出任何受本規則約束的圖表 DSL 之前，main agent 必須先呼叫 `diagram-designer` skill 完成圖表類型與語法選型；免除觸發的情境以該 skill 的 description 為準。例外：`what` skill 產生的 HTML 內嵌 Mermaid，以及「對話中直接畫 Mermaid」的情境，不必先呼叫 `diagram-designer`。

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 直接輸出到 stdout
1. 屬於「對話中直接畫 Mermaid」的情境 → 直接在回覆中畫
1. 呼叫 `diagram-designer` skill 完成圖表類型選型與即時預覽（`what` skill 的 HTML 依上述例外，不呼叫）
1. 需要持久保存 → 寫入 `.md` 檔；目標為 Obsidian vault 筆記時，依 `obsidian-notes` skill 處理（`what` skill 的 HTML 依其說明存成 `.tmp/` 下的 `.html` 暫存檔，不適用此步）
1. 除第 1 至 3 步外，禁止將受本規則約束的 DSL 以圖表為目的直接輸出到 stdout
