---
name: diagram-designer
description: 圖表設計選型知識庫。當使用者要求繪製、設計或產生圖表（流程圖、架構圖、時序圖、ER 圖、心智圖、UML 元件圖、網路拓樸、介面草圖 wireframe / UI mockup 等），或詢問該用哪種圖表語法，或提供需求想把概念或實際數值資料視覺化時觸發。不應觸發：使用者只要 ASCII 示意圖、只是修正既有圖表的小錯字、已明確指定語法且只要原始碼。觸發關鍵字：畫圖、流程圖、架構圖、時序圖、ER 圖、心智圖、網路拓樸、UML、diagram、mermaid、d2、plantuml、graphviz、salt、wireframe、UI mockup、mockup、介面草圖、vega、vega-lite、vegalite、資料圖表、bar chart、line chart、scatter plot、效能圖表、趨勢圖、dashboard、儀表板、圖表選型
---

# Diagram Designer Skill

## 目標

此 skill 提供圖表語法選型知識與設計指引，協助 main agent 在設計階段從六種圖表服務（Mermaid、d2、PlantUML、Graphviz、Structurizr、Vega-Lite）中做出正確的選擇，並確保產出的圖表草稿可直接交由後續寫檔流程使用。Skill 本身不負責將圖表寫入任何檔案。

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
   - **當任務本質是「長期維護的多視角系統架構文件」而非單張圖時**，跳出單張圖的選型思維，改選 Structurizr。Structurizr 的核心抽象是「一份 model 加上多個 view」，能從同一份 DSL 自動產出 context、container、component、dynamic、deployment 等多張視圖，元件改名或重構時所有視圖同步更新。判斷訊號：預期圖數量達五張以上、跨團隊或跨季度維護、需要嚴格遵循 C4 model 階層。若只是單張一次性架構圖，仍應選 Mermaid 或 d2，不應為了單張圖引入 Structurizr。
   - **當意圖是「呈現介面長什麼樣、控制項怎麼排」而非「元件關係」時**，選 PlantUML salt。salt 歸於結構圖分支下，但獨立指名判斷，不與其餘結構圖服務混在一起選擇。

## 概念對應到圖表

| 想表達的概念 | 優先選擇 | 理由 |
| --- | --- | --- |
| 系統架構（high-level、含外部服務或元件） | d2（含 sketch render style）+ terrastruct icons | sketch 風格有設計感，icons 大幅提升辨識度（Mermaid 架構圖表達力不足，列為例外） |
| Grid diagram（矩陣排版、feature matrix、RACI 責任分配矩陣、資源排列） | d2（grid diagram） | Mermaid 與 PlantUML 沒有對等語法，d2 是唯一支援格狀自動排版的服務 |
| 多層巢狀容器架構圖（3 層以上，如 cloud account → VPC → subnet → service） | d2（container 巢狀語法） | Mermaid subgraph 在 3 層以上可讀性快速劣化，d2 的 container 語法天生為深度巢狀設計 |
| 系統元件互動 / API 呼叫順序 / 認證流程 | Mermaid `sequenceDiagram` | GitHub 與 HackMD 原生 render |
| 業務流程 / 決策樹 / 邏輯分支 | Mermaid `flowchart` | 原生 render，最通用 |
| 狀態機 / 物件生命週期 | Mermaid `stateDiagram-v2` | 原生 render |
| 資料庫 schema / 實體關係 | Mermaid `erDiagram` | 原生 render |
| OOP 類別繼承關係 | Mermaid `classDiagram` | 原生 render |
| UML component / deployment / use case | PlantUML | Mermaid 不支援或語法受限 |
| UML activity（含複雜分支與並行） | PlantUML | Mermaid `flowchart` 表達力不足 |
| UI/UX 介面草圖、wireframe、mockup（登入頁、表單、清單、對話框佈局） | PlantUML salt | 現有其他服務皆不擅長介面佈局；salt 是純文字 DSL，AI 可讀可改 |
| 網路拓樸或大型有向圖（節點 > 10） | Graphviz (dot) | 自動 layout 演算法處理大量節點 |
| 心智圖 / 概念發散 | Mermaid `mindmap` | 原生 render |
| 專案時程 / 甘特圖 | Mermaid `gantt` | 原生 render |
| Git 分支策略 | Mermaid `gitGraph` | 原生 render |
| 組織圖 / 階層結構（小型） | Mermaid `flowchart TB` | 原生 render |
| 大型系統架構文件（長期維護、跨團隊閱讀、需在多個視角之間同步） | Structurizr DSL | 單一 model 可自動產出 context、container、component、dynamic、deployment 多張視圖；元件改名一處同步全圖；天生為跨季度維護的架構文件設計 |
| 單張、小型、一次性的 C4 context 圖 | Mermaid `C4Context` | 原生 render；當系統夠單純、單張 context 圖就能說明完整時，不必引入 Structurizr 的多視角模型，Mermaid C4Context 較輕量 |
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
- 需要 grid diagram 表達矩陣式或格狀排版（Mermaid 與 PlantUML 不支援）
- 需要表達 3 層以上深度巢狀的容器結構，Mermaid subgraph 在此情境可讀性劣化

d2 的 layout 引擎包含 dagre（預設）、elk、tala；render style 分為預設精緻風格與 sketch 手繪風格（透過 `--sketch` flag 啟用）。詳細選用指引請見 `references/d2-layout-engines.md`。

### PlantUML

完整 UML 家族的首選，在 Mermaid 較弱的 UML 類型上表達能力更完整，透過 kroki.io 嵌入。適用情境：

- Component diagram（元件圖）
- Deployment diagram（部署圖）
- Activity diagram（活動圖，含進階分支與並行語法）
- Use case diagram（使用案例圖）
- Wireframe / UI mockup（salt 語法，`@startsalt` 包住；diagram type 仍為 `plantuml`）
- 其他 Mermaid 不支援或語法限制較多的 UML 類型

### Structurizr

專為大型、長期維護的 C4 架構文件設計，透過 kroki.io 嵌入 markdown。與其他結構圖服務最根本的差異在於核心抽象不同：其他服務是「一張圖一份原始碼」，Structurizr 是「一份 model 加上多個 view」。這個差異決定了它所有的優勢與限制。

適用情境：

- 系統元件數量多（例如十個以上），且需要同時在 context、container、component、dynamic、deployment 等多個層級呈現
- 文件預期維護一年以上、由多人或多團隊共同編輯
- 元件命名與關係需要作為 single source of truth——改一處要同步反映在所有視圖
- 需要嚴格遵循 C4 model 階層，避免抽象層級在不同人筆下混亂
- 需要 filtered view（例如針對某個 team 或某個 bounded context 自動篩選出對應的圖）

取捨：

- Layout 仰賴 Graphviz 預設演算法，遇到複雜圖經常需要在 Structurizr Lite UI 手動拖拉調整；手動座標儲存在另一份 JSON，不會回寫 DSL，與 git workflow 整合度有限
- DSL 學習曲線高於 Mermaid 與 d2，使用者需先理解 C4 model 的抽象階層才能寫好 DSL

不適用情境：單張一次性架構圖、ad-hoc 設計討論、非系統架構主題的流程或關係圖——這些情境引入 Structurizr 屬於過度工程，請仍選 Mermaid 或 d2。

### Graphviz

以 dot 語法撰寫，適合需要自動 layout 演算法的大型圖，透過 kroki.io 嵌入。適用情境：

- 複雜有向圖或無向圖
- 網路拓樸（節點數量多、邊關係複雜）
- 節點數量龐大、手動排版不切實際，需要 Graphviz 自動計算最佳 layout

### Vega-Lite

六種服務中唯一處理「資料 → 圖表」的服務；Mermaid、d2、PlantUML、Graphviz、Structurizr 皆為結構圖工具，不適合用來做數值視覺化。

適用情境：

- bar chart（含 grouped、stacked）
- line chart 與 area chart
- scatter plot
- heatmap 與 box plot
- histogram
- pie chart 等統計圖表
- 迴歸線 / 趨勢擬合（`regression`、`loess` transform）
- 分布圖：density、violin（皆以 `density` transform 計算）
- faceting 小多圖（`facet` / `row` / `column`）
- 多視圖組合：`layer` 疊圖、`hconcat` / `vconcat` 儀表板式排版
- 互動圖表：`params` selection（縮放、篩選、聯動）

Vega-Lite 採用 JSON declarative 語法，LLM 寫出正確 spec 的機率高，且官方 example gallery 已涵蓋絕大多數常見圖表類型。透過 kroki.io 以圖片方式嵌入 markdown。

#### 資料形狀 → 圖型

面對數值資料時，應依資料形狀判斷圖型，而非直接套用使用者口中提到的圖表名稱：

- 兩個連續變數想看相關性 → scatter + 迴歸線
- 時間序列且需比較多組 → 多線圖；組數過多、線條互相遮蔽時改用 faceting 小多圖
- 需要比較分布差異 → violin 或 box
- 表達佔比 → 類別數少用 pie，類別數一多改用 bar（pie 類別一多，角度差異難以判讀）

資料圖表另需注意以下設計原則（延伸「設計原則」章節，僅適用於資料視覺化）：

- **顏色語意跨圖一致**：同一資料維度在同一份文件中應維持相同的顏色對應，避免同一類別在不同圖表換色，讀者才能靠顏色比對資料
- **軸是否含 0 基準視圖表類型而定**：以長度表達數值的圖型（如長條圖）必須從 0 開始，避免視覺上誇大差異；以趨勢為重的圖型（如折線圖）可視需要局部放大
- **圖例可讀性**：類別數量一多，圖例應緊鄰對應圖形或直接標籤在資料點旁，避免讀者反覆對照圖例與圖形

不適用情境：流程、架構、關係圖等結構性表達——這些請使用其餘五種服務。

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

## 圖表預覽

預覽一律透過 `~/.claude/skills/diagram-designer/scripts/render.sh <diagram_type>` 產生，圖表 DSL 原始碼由 stdin 餵入，不透過命令列參數傳遞。main agent 呼叫前須先把環境變數 `DIAGRAM_TMP_DIR` 設為工作區 `.tmp`（依 `tmp-file-usage` rule 解析出的實際路徑）。

`diagram_type` 對應表（即 render.sh 的第一個參數）：

| 服務 | diagram\_type |
| --- | --- |
| Mermaid | `mermaid` |
| d2 | `d2` |
| PlantUML | `plantuml` |
| Structurizr | `structurizr` |
| Graphviz | `graphviz` |
| Vega-Lite | `vegalite` |

render.sh 依序嘗試三層渲染，任一層成功即在 stdout 印出單一行「可開啟目標」並結束，stderr 說明是哪一層產生的結果：

1. 本機原生 CLI（Mermaid 對應 mmdc、d2 對應 d2、Graphviz 對應 dot）
1. 本地 docker kroki——僅在加上 `--docker` flag 且容器可連通時才會嘗試；容器需自行手動啟動，render.sh 不會代為啟動。預設不加 `--docker`，僅在使用者明確要求本地或離線預覽、或遠端 kroki.io 不可用時才加
1. 遠端 kroki.io——前兩層皆不可用時的最終回退

stdout 印出的單行，本地渲染成功時是暫存 SVG 的絕對路徑，回退遠端時是 `https://kroki.io/<diagram_type>/svg/<encoded>`。main agent 取得這一行後，不論是本地路徑或遠端 URL，一律以同一種方式在背景開啟：

```bash
# DIAGRAM_TMP_DIR 由 main agent 設為工作區 .tmp；開啟 render.sh 印出的單行目標
target="$(printf '%s' "$DSL" | DIAGRAM_TMP_DIR=<workspace>/.tmp ~/.claude/skills/diagram-designer/scripts/render.sh <diagram_type>)"
google-chrome-stable "$target" & disown
```

若 `google-chrome-stable` 不可用或執行失敗，才退回將該行內容直接提供給使用者查看。任何情況下均不得僅在聊天訊息中展示原始路徑或 URL 而不嘗試開啟。

遠端層所需的 zlib 壓縮 + base64 url-safe 編碼，由 render.sh 內部呼叫 `scripts/kroki-encode.py` 完成，LLM 不自行編碼、也不自行拼組 kroki URL。

預覽不取代寫檔流程，最終仍須將圖表寫入 `.md` 檔案。

## Reference 動態載入

本 skill 在 `references/` 目錄下提供額外參考檔案，僅在特定場景才需載入，避免污染 main agent context。

| 參考檔案 | 觸發條件 |
| --- | --- |
| `references/d2-terrastruct-icons.md`（索引檔） | 使用 d2 並需要 terrastruct icons 時，**第一階段**先載入此索引檔，確認 provider 結構與 URL pattern |
| `references/d2-terrastruct-icons/<provider>.md`（子檔） | **第二階段**依使用者需求載入對應 provider 子檔（例如畫 AWS 架構圖 → 載入 `aws.md`）；不要一次載入全部子檔，只載入當下需要的 provider |
| `references/plantuml-stdlib-includes.md` | 使用 PlantUML 並需要 C4 model、AWS / Azure / GCP / Kubernetes 圖示庫時 |
| `references/plantuml-salt.md` | 使用 PlantUML salt 畫 wireframe / UI mockup 時載入 |
| `references/d2-layout-engines.md` | 使用 d2 且圖較複雜，需要決定 layout engine 或 render style 時 |

Vega-Lite 不需動態載入 reference（含 `regression`、`facet`、`layer`、`selection` 等進階 spec）——官方 example gallery 與這些 spec 結構已在 LLM 訓練資料中；資料圖的強化聚焦於選型與設計判斷，而非語法教學。

## 輸出格式

Main agent 回應使用者時應包含以下三個部分：

1. **選型說明**：選用哪種服務與哪種圖表類型，以及理由（一至兩句純文字）
1. **預覽呈現**：說明已呼叫 render.sh 取得預覽目標並在瀏覽器開啟；目標路徑或 URL 本身不貼到聊天回應，實際開啟流程依 `diagram-output` rule 執行
1. **後續寫入說明**：若使用者要將圖表寫進 `.md` 檔，依 `markdown-editing` rule 委派處理；DSL 原始碼透過該委派流程交付，不經聊天回應中轉

圖表 DSL 原始碼（mermaid、d2、plantuml、graphviz、structurizr、vega-lite 等）禁止以 fenced code block 或任何其他形式直接貼入聊天回應。此規定對所有支援的服務皆適用，包含 Mermaid，不因 Mermaid 在部分 markdown 環境可原生渲染而例外。此禁令的適用範圍僅限於本 skill 被觸發後的設計產出流程；`diagram-output.md` 已劃出「使用者明示要原始碼」與「只需要 ASCII 字元圖示」這兩條例外路徑，在那兩種情境下本 skill 根本不應被觸發，故此禁令不覆蓋那兩條路徑。

## 與其他元件的協作

此 skill 只負責設計階段：提供選型建議與圖表語法草稿。

圖表確認後，寫入 `.md` 檔案的工作依以下規則委派：

- 依 `rules/diagram-output.md` 的規定，圖表必須寫入 `.md` 檔案，不得直接輸出到聊天訊息
- 依 `rules/markdown-editing.md` 的規定，實際寫入由 `markdown-editor` 或 `obsidian-md-editor` 執行
- Main agent 不得自行寫入任何 markdown 檔案
- 六種服務的圖表草稿確認後，均透過上述委派流程寫入，不因服務不同而有差異
