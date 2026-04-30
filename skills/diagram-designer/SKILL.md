---
name: diagram-designer
description: 圖表設計選型知識庫。當使用者要求繪製、設計或產生圖表（流程圖、架構圖、時序圖、ER 圖、心智圖、UML 元件圖、網路拓樸等），或詢問該用哪種圖表語法，或提供需求想把概念或實際數值資料視覺化時觸發。不應觸發：使用者只要 ASCII 示意圖、只是修正既有圖表的小錯字、已明確指定語法且只要原始碼。觸發關鍵字：畫圖、流程圖、架構圖、時序圖、ER 圖、心智圖、網路拓樸、UML、diagram、mermaid、d2、plantuml、graphviz、vega、vega-lite、vegalite、資料圖表、bar chart、line chart、scatter plot、效能圖表、趨勢圖、圖表選型
---

# Diagram Designer Skill

## 目錄

- [目標](#目標)
- [觸發時機](#觸發時機)
- [選型策略](#選型策略)
- [概念對應到圖表](#概念對應到圖表)
- [各服務適用情境](#各服務適用情境)
- [設計原則](#設計原則)
- [需求釐清](#需求釐清)
- [kroki.io 預覽 URL](#krokiio-預覽-url)
- [Reference 動態載入](#reference-動態載入)
- [輸出格式](#輸出格式)
- [與其他元件的協作](#與其他元件的協作)

## 目標

此 skill 提供圖表語法選型知識與設計指引，協助 main agent 在設計階段從五種圖表服務（Mermaid、d2、PlantUML、Graphviz、Vega-Lite）中做出正確的選擇，並確保產出的圖表草稿可直接交由後續寫檔流程使用。Skill 本身不負責將圖表寫入任何檔案。

## 觸發時機

應觸發的情境：

- 使用者要求繪製、設計或產生任何類型的圖表
- 使用者詢問應選用哪種圖表語法
- 使用者提供需求，希望把某個概念、流程或實際數值資料視覺化

不應觸發的情境：

- 使用者只需要 ASCII 字元示意圖（終端機可直接顯示，不需要 renderer）
- 使用者只是要修正既有圖表的小錯字，不涉及選型決策
- 使用者已明確指定語法，且目的是取得原始碼以供複製貼上至其他地方

## 選型策略

選型分三步進行。

1. 判斷意圖類型：

   - **結構圖**：表達元件之間的關係、流程的順序、階層的層級——例如系統架構、API 流程、ER 圖、狀態機等。意圖是「誰跟誰有什麼關係」。
   - **資料圖表**：把實際數值視覺化——例如效能趨勢、A/B 測試結果、分布比較、metric 報告。意圖是「數字呈現某種模式」。

1. 依意圖類型分流：

   - 結構圖 → 進入第三步的服務選擇。
   - 資料圖表 → 直接選 **Vega-Lite**，不進入第三步。

1. 服務選擇（僅結構圖適用）：先判斷最適合表達使用者概念的圖表類型，再從支援該類型的服務中選擇實作語法：

   - **優先選 Mermaid**：HackMD 與 GitHub markdown 均原生渲染 Mermaid，不需要透過 kroki.io 等第三方服務，是最輕量的選擇。
   - **只有在 Mermaid 不支援該圖表類型，或 Mermaid 的表達能力明顯不足時**，才考慮 d2、PlantUML、Graphviz。

## 概念對應到圖表

| 想表達的概念 | 優先選擇 | 理由 |
| --- | --- | --- |
| 系統架構（high-level、含外部服務或元件） | d2（含 sketch render style）+ terrastruct icons | sketch 風格有設計感，icons 大幅提升辨識度（Mermaid 架構圖表達力不足，列為例外） |
| 系統元件互動 / API 呼叫順序 / 認證流程 | Mermaid `sequenceDiagram` | GitHub 與 HackMD 原生 render |
| 業務流程 / 決策樹 / 邏輯分支 | Mermaid `flowchart` | 原生 render，最通用 |
| 狀態機 / 物件生命週期 | Mermaid `stateDiagram-v2` | 原生 render |
| 資料庫 schema / 實體關係 | Mermaid `erDiagram` | 原生 render |
| OOP 類別繼承關係 | Mermaid `classDiagram` | 原生 render |
| UML component / deployment / use case | PlantUML | Mermaid 不支援或語法受限 |
| UML activity（含複雜分支與並行） | PlantUML | Mermaid `flowchart` 表達力不足 |
| 網路拓樸或大型有向圖（節點 > 10） | Graphviz (dot) | 自動 layout 演算法處理大量節點 |
| 心智圖 / 概念發散 | Mermaid `mindmap` | 原生 render |
| 專案時程 / 甘特圖 | Mermaid `gantt` | 原生 render |
| Git 分支策略 | Mermaid `gitGraph` | 原生 render |
| 組織圖 / 階層結構（小型） | Mermaid `flowchart TB` | 原生 render |
| C4 模型 context level | Mermaid `C4Context` | 原生 render |
| 資料圖表（趨勢、分布、比較、效能 metric） | **Vega-Lite** | 唯一原生處理數值視覺化的服務，其他服務不擅長 |

表格僅作為快速參考；當使用者需求不在表中或跨多個概念時，仍應依「選型策略」章節的三步驟流程判斷。

## 各服務適用情境

### Mermaid

最優先選用。適合絕大多數常見圖表類型，GitHub 與 HackMD 均原生 render，無需外部服務。

| 類型 | 適合場景 |
| --- | --- |
| `flowchart` | 流程、決策樹、邏輯分支 |
| `sequenceDiagram` | 系統間互動、API 呼叫順序、認證流程 |
| `classDiagram` | OOP 類別關係與繼承結構 |
| `stateDiagram-v2` | 狀態機、物件生命週期 |
| `erDiagram` | 資料庫 schema、實體關係模型 |
| `gantt` | 專案時程規劃 |
| `mindmap` | 概念發散、心智圖 |
| `gitGraph` | Git 分支策略與合併流程 |
| `C4Context` | 系統架構的 context level 概覽 |

### d2

Mermaid 表達能力不足時的替代方案，透過 kroki.io 以圖片方式嵌入 markdown。適用情境：

- 需要手繪風格視覺效果（sketch render style）
- 需要搭配 terrastruct icons 提升架構圖辨識度
- 需要現代感視覺設計，Mermaid 預設樣式無法滿足時

d2 的 layout 引擎包含 dagre（預設）、elk、tala；render style 分為預設精緻風格與 sketch 手繪風格（透過 `--sketch` flag 啟用）。詳細選用指引請見 `references/d2-layout-engines.md`。

### PlantUML

完整 UML 家族的首選，在 Mermaid 較弱的 UML 類型上表達能力更完整，透過 kroki.io 嵌入。適用情境：

- Component diagram（元件圖）
- Deployment diagram（部署圖）
- Activity diagram（活動圖，含進階分支與並行語法）
- Use case diagram（使用案例圖）
- 其他 Mermaid 不支援或語法限制較多的 UML 類型

### Graphviz

以 dot 語法撰寫，適合需要自動 layout 演算法的大型圖，透過 kroki.io 嵌入。適用情境：

- 複雜有向圖或無向圖
- 網路拓樸（節點數量多、邊關係複雜）
- 節點數量龐大、手動排版不切實際，需要 Graphviz 自動計算最佳 layout

### Vega-Lite

五種服務中唯一處理「資料 → 圖表」的服務；Mermaid、d2、PlantUML、Graphviz 皆為結構圖工具，不適合用來做數值視覺化。

適用情境：

- bar chart（含 grouped、stacked）
- line chart 與 area chart
- scatter plot
- heatmap 與 box plot
- histogram
- pie chart 等統計圖表

Vega-Lite 採用 JSON declarative 語法，LLM 寫出正確 spec 的機率高，且官方 example gallery 已涵蓋絕大多數常見圖表類型。透過 kroki.io 以圖片方式嵌入 markdown。

不適用情境：流程、架構、關係圖等結構性表達——這些請使用其餘四種服務。

## 設計原則

產出圖表草稿時應遵守以下原則：

- **單一主題**：一張圖只表達一個主題，若範圍過寬應主動建議拆成多張圖
- **節點命名簡短具體**：避免長句，以 3 至 5 個字為宜
- **流向一致**：同一張圖內統一由上而下或由左而右，不混用
- **樣式用於區分類別**：顏色或樣式應服務於資訊區分，不為美觀而濫用
- **描述性 alt text**：無論使用哪種語法，最終嵌入 markdown 時必須提供讓不能看圖的讀者也能理解圖意的 alt text

## 需求釐清

若使用者的需求尚不足以確定圖表範圍或類型，應先以 1 至 2 個關鍵問題釐清，再產出草稿。優先詢問：

- 這張圖的目標讀者是誰（開發者、利害關係人、新人入職等）
- 最重要的一條主軸流程或關係是什麼

確認需求後再選型，避免草稿完成後需要大幅重畫。

## kroki.io 預覽 URL

產出圖表草稿後，必須額外提供一個 kroki.io 預覽 URL，讓使用者可以在寫入檔案前直接點開瀏覽器確認視覺效果。此規定對五種服務皆適用，包含 Mermaid。

URL 格式：

```text
https://kroki.io/<diagram_type>/svg/<encoded_source>
```

`diagram_type` 對應如下：

| 服務 | diagram\_type |
| --- | --- |
| Mermaid | `mermaid` |
| d2 | `d2` |
| PlantUML | `plantuml` |
| Graphviz | `graphviz` |
| Vega-Lite | `vegalite` |

`encoded_source` 的正確編碼方式為：將原始碼先做 raw deflate 壓縮，再做 URL-safe base64 編碼。純 base64（未壓縮）對短內容偶爾可用但不可靠，必須使用 deflate + base64url。

可直接套用的編碼指令：

```bash
echo -n "$SOURCE" | python3 -c "import sys,zlib,base64; print(base64.urlsafe_b64encode(zlib.compress(sys.stdin.buffer.read(),9)).decode())"
```

將圖表原始碼放進 `SOURCE` 環境變數或 heredoc，輸出即為可直接拼接到 URL 末端的 `encoded_source`。

預覽 URL 不取代寫檔流程，最終仍由 `markdown-editor` 或 `obsidian-md-editor` 將圖表寫入 `.md` 檔案。

## Reference 動態載入

本 skill 在 `references/` 目錄下提供額外參考檔案，僅在特定場景才需載入，避免污染 main agent context。

| 參考檔案 | 觸發條件 |
| --- | --- |
| `references/d2-terrastruct-icons.md`（索引檔） | 使用 d2 並需要 terrastruct icons 時，**第一階段**先載入此索引檔，確認 provider 結構與 URL pattern |
| `references/d2-terrastruct-icons/<provider>.md`（子檔） | **第二階段**依使用者需求載入對應 provider 子檔（例如畫 AWS 架構圖 → 載入 `aws.md`）；不要一次載入全部子檔，只載入當下需要的 provider |
| `references/plantuml-stdlib-includes.md` | 使用 PlantUML 並需要 C4 model、AWS / Azure / GCP / Kubernetes 圖示庫時 |
| `references/d2-layout-engines.md` | 使用 d2 且圖較複雜，需要決定 layout engine 或 render style 時 |

Vega-Lite 不需動態載入 reference，因官方 example gallery 已在 LLM 訓練資料中，且 spec 結構穩定。

## 輸出格式

Main agent 回應使用者時應包含以下四個部分：

1. **選型說明**：選用哪種服務與哪種圖表類型，以及理由（一至兩句）
1. **圖表草稿**：以 fenced code block 呈現，語言標籤對應所選語法
1. **kroki.io 預覽 URL**：可點擊的完整 URL，讓使用者在寫入前先確認視覺效果
1. **後續說明**：說明正式寫入 markdown 時的嵌入方式——Mermaid 以 fenced code block 直接嵌入，d2、PlantUML、Graphviz、Vega-Lite 則透過 kroki.io 圖片語法嵌入

## 與其他元件的協作

此 skill 只負責設計階段：提供選型建議與圖表語法草稿。

圖表確認後，寫入 `.md` 檔案的工作依以下規則委派：

- 依 `rules/diagram-output.md` 的規定，圖表必須寫入 `.md` 檔案，不得直接輸出到聊天訊息
- 依 `rules/markdown-editing.md` 的規定，實際寫入由 `markdown-editor` 或 `obsidian-md-editor` 執行
- Main agent 不得自行寫入任何 markdown 檔案
- 五種服務的圖表草稿確認後，均透過上述委派流程寫入，不因服務不同而有差異
