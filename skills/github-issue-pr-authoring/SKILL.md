---
name: github-issue-pr-authoring
description: >
  當使用者想建立或修改 GitHub issue 或 PR 的標題或內文時觸發。在主對話層完成分層內容組裝，再將組裝好的標題、內文與 comment 清單交給 github-manager 執行實際的 gh 指令。純查詢、列表、檢視等唯讀操作不觸發本 skill，直接交給 github-manager 處理即可。觸發關鍵字：github issue、github pr、pull request、開 issue、建立 issue、修改 issue、開 PR、issue description、PR description。
---

# GitHub Issue / PR Authoring

## 目標

本 skill 在主對話層（main agent）完成 issue 或 PR 的內容組裝，再把組裝好的標題、內文與 comment 清單交給 github-manager 執行實際的 gh 指令；main agent 本身不執行 gh。

採這種分層是因為內容組裝需要 plan file 與整段對話脈絡，而解法圖示的類型選型也必須在 main agent 層先完成——這些都是執行型 subagent 拿不到或做不好的工作，因此讓內容在主層組裝、執行交給 github-manager。

核心目標是讓產出的 issue 與 PR 內文由淺入深、由全局概觀逐步帶入細節，降低讀者的認知負載。具體做法由以下三條核心原則統攝。

## 三條核心原則

### 抽象邊界

決策結論留在 description，推導過程下沉到 comment。

判斷某段內容該放在哪裡，使用以下測試問句：

> 讀者是否需要這段才能理解並同意這個決策、知道接下來要做什麼？

- 需要 → 留在 description
- 屬於支撐決策的推導、證據或實作規劃 → 下沉到 comment

### 順序動線

comment 序列依照「從為什麼到怎麼做」的方向、由粗到細排列，讀者一篇一篇往下讀就完成由淺入深的理解。

本 skill 釘住的是相對順序，不釘固定段數。

### 圖優先加結構化拆解

- 能用圖表達就用圖，圖為主、文字為輔。
- 需要用文字解釋一件事情或一張圖時，優先用表格或清單逐步拆解，而非長段落。
- 圖能降低理解成本才畫，圖無助理解時退回結構化的表格或清單文字。

## 觸發與不觸發

觸發時機：建立或修改 issue 或 PR 的標題或內文。

不觸發的情況：純查詢、列表、檢視等唯讀操作。這類操作直接交給 github-manager，不經本 skill。同樣地，若只是調整 label、assignee、狀態等中繼資料，而完全沒有更動標題或內文，也不觸發本 skill，直接交給 github-manager 處理。

## 內容來源與省略原則

組裝內容時，優先取用 plan file 的內容。當沒有 plan file 或 plan file 內容不足時，才以對話的最終脈絡補足。

- 來源不足以支撐某個段落時，省略該段落，不得捏造內容，也不得用 TBD 之類的佔位字填充。發佈出去的 issue 或 PR 不應出現佔位符。
- 不適用於當前變更的段落直接省略，不強迫補滿固定結構。

## Issue 撰寫規範

**標題**：用英文撰寫，簡潔、易懂、容易被搜尋。

**Description 骨架**（繁體中文，依序排列）：

1. **Summary / TL;DR** — 結論先行，一段話說明此 issue 的核心訴求。
1. **Background** — 先描述當前現況，再帶出痛點；現況必要時可用 mindmap 或類似目的的圖描述。
1. **Goal** — 明確列出 In Scope 與 Out of Scope。
1. **Impact** — 正面影響、負面影響與風險。
1. **採用解法概觀** — 只放最終選定的方案，加一張全局概觀圖。
1. **關鍵決策** — 只條列決定了什麼；完整推導下沉到 comment。
1. **Acceptance Criteria** — 如何驗收以確認有達到 Goal。
1. **References** — 參考來源。
1. **Signposting 導讀** — 末尾一行說明，明示更深入的解法探索、決策推導、實作規劃見下方留言，建議依序閱讀。

**Comment 序列**（順序原則，非固定段數）：

以下是相對順序，某一類若沒有內容，就不張貼該則 comment：

1. **解法探索全紀錄** — 考慮過哪些候選方案、為何否決、各自的優劣取捨。
1. **決策推導明細** — 每項關鍵決策的完整考量與優劣。
1. **實作規劃** — 實作步驟、順序與工作項拆解。複雜時可拆成兩到三則（例如先總體規劃、再分階段細節），前提是維持由粗到細的順序。

## PR 撰寫規範

**標題**：用英文撰寫，簡潔、易懂、容易被搜尋。標題結尾的 issue 參照由 github-manager 自動補上，本 skill 不自行加入。

**Description**（繁體中文，只用 description 分層，不開 comment；PR description 可整體替換且支援折疊展開，分層需求由 description 本身承載，靠標題層級與折疊區塊做由淺入深的揭露）：

1. **Issue 連結** — 由 github-manager 自動補上，本 skill 不撰寫此段。
1. **TL;DR** — 一兩句話說明這個 PR 解決什麼、產生什麼行為變更；背景指向 issue，不重複。
1. **行為變更** — 這個 PR 被 merge 後可觀察的前後對照。
1. **風險與 Reviewer 重點** — 列出最該被仔細審的改動、為何有風險、希望 reviewer 確認什麼；風險高的排前面。
1. **詳細 Walkthrough** — 逐模組或逐關注點導覽，用折疊區塊預設收合，reviewer 想深入再展開。
1. **Conclusion** — 總結此 PR 的意義與後續注意事項。

以最終 code change 為主角，禁止用逐一說明每個 commit 的方式來描述。

**邊界情況：PR 無關聯 issue** — 並非每個 PR 都連到 issue。當 PR 沒有關聯的 issue 時，Issue 連結段省略，整份 PR description（含 TL;DR）改寫成自包含、能獨立讀懂，禁止留下指向不存在 issue 的死連結。

## 更新冪等性

- **Issue**：更新既有 issue 前，必須先請 github-manager 取回該 issue 現有的分層 comment（內容與各則的識別），作為就地更新的依據；main agent 本身不執行 gh，無法自行取得此資訊。取得既有 comment 現況後，針對對應內容做就地更新，而不是重新張貼一整串。本 skill 讓 issue 帶有有序的 comment 序列，若更新時重跑整套流程，同一份分層內容就會被重複貼成多串。
- **PR**：此風險不適用。每次編輯 PR 是整體替換內文，不存在重複問題。

## 圖示策略

圖優先原則適用於全篇——包含 description 與 comment——不限定只用在特定段落。

所有圖在產生之前，都必須先完成圖表類型的選型，以符合此 repo 既有的圖表輸出規範。

預設使用 GitHub 原生可算繪的圖（包含 mermaid）。當原生圖無法表達所需圖形、改用 kroki 這類外部 renderer 把圖算繪成圖片嵌入時，必須注意：圖表原始碼會被送往外部服務，產生的圖片也由外部主機託管。含有敏感或內部資訊的圖不得送往外部 renderer，應改用原生可算繪的圖，或退回結構化的表格與清單文字。

## 建立與修改一致性

不論是建立全新的 issue 或 PR，還是修改既有的 issue 或 PR，都必須維持相同的大綱結構。修改既有 description 時，如果發現缺少某些段落，要主動補齊並重排 description 骨架；重排僅適用於 description，不適用於 comment 序列。

修改既有 issue 的 comment 時，依更新冪等性規則就地更新對應則次，不嘗試重建順序；若既有順序有誤，應在 comment 內容中說明，而非刪除重建。

## Comment 輕量溝通

對 issue 或 PR 的一般 comment，預設使用繁體中文撰寫，不套用任何結構模板——這類 comment 是日常輕量溝通，不需要強制結構化。

注意：此節的「comment」指日常討論回覆，與 Issue 撰寫規範中作為分層揭露載體的結構化 comment 序列是不同用途，兩者不應混淆。

## 委派執行

把組裝好的最終標題、內文，以及一份已排好序的 comment 清單交給 github-manager 執行實際的 gh 指令。

建立新 issue 或 PR 時，交付時載明輸出契約：

> 這是若干則獨立的 comment，請依此次序張貼。

更新既有 issue 時，comment 清單中每一則須明確標示性質：就地更新既有 comment 者附上對應既有 comment 的識別，新增 comment 者標示為新增；github-manager 依此無歧義地分別處理，若任何操作的可行性有疑慮，由它回報。

整合細節：github-manager 在處理連結 issue 的 PR 時，會自動在 PR 標題結尾補上 issue 參照、並在內文開頭補上 issue 連結，且此行為無法關閉。因此本 skill 在組裝 PR 內容時，不自行添加這兩項；只需把對應的 issue number 提供給 github-manager，由它自動補上，這樣才不會重複。
