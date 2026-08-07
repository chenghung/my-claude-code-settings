---
name: github-issue-pr-authoring
description: >
  本 skill 是 GitHub issue 與 PR 標題、內文及 comment 序列的撰寫規範庫，定義骨架、順序與圖優先等撰寫判準；由 issue-pr-publisher 透過 frontmatter 的 skills 欄位在啟動時預載取用，不由 main agent 依觸發關鍵字呼叫。
---

# GitHub Issue / PR Authoring

## 目標

本 skill 定義撰寫或修改 GitHub issue 與 PR 標題、內文及 comment 序列時應遵守的規範，確保產出由淺入深、由全局概觀逐步帶入細節，降低讀者的認知負載。具體做法由以下三條核心原則統攝。

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

**Multi-issue 情境下的 parent description**：在採用解法概觀之後、關鍵決策之前，插入「拆解總覽」一段；內容規範見 Multi-Issue 撰寫規範。

**Comment 序列**（順序原則，非固定段數）：

以下是相對順序，某一類若沒有內容，就不張貼該則 comment：

1. **解法探索全紀錄** — 考慮過哪些候選方案、為何否決、各自的優劣取捨。
1. **決策推導明細** — 每項關鍵決策的完整考量與優劣。
1. **實作規劃** — 實作步驟、順序與工作項拆解。複雜時可拆成兩到三則（例如先總體規劃、再分階段細節），前提是維持由粗到細的順序。

## PR 撰寫規範

**標題**：用英文撰寫，簡潔、易懂、容易被搜尋。標題結尾的 issue 參照由 github-manager 自動補上，本 skill 不自行加入——這是 github-manager 連結 issue 時的無條件預設行為，自行添加只會造成無法清除的重複內容。

**Description**（繁體中文，只用 description 分層，不開 comment；PR description 可整體替換且支援折疊展開，分層需求由 description 本身承載，靠標題層級與折疊區塊做由淺入深的揭露）：

1. **Issue 連結** — 由 github-manager 自動補上，本 skill 不撰寫此段。
1. **TL;DR** — 一兩句話說明這個 PR 解決什麼、產生什麼行為變更；背景指向 issue，不重複。
1. **行為變更** — 這個 PR 被 merge 後可觀察的前後對照。
1. **風險與 Reviewer 重點** — 列出最該被仔細審的改動、為何有風險、希望 reviewer 確認什麼；風險高的排前面。
1. **詳細 Walkthrough** — 逐模組或逐關注點導覽，用折疊區塊預設收合，reviewer 想深入再展開。
1. **Conclusion** — 總結此 PR 的意義與後續注意事項。

以最終 code change 為主角，禁止用逐一說明每個 commit 的方式來描述。

**邊界情況：PR 無關聯 issue** — 並非每個 PR 都連到 issue。當 PR 沒有關聯的 issue 時，Issue 連結段省略，整份 PR description（含 TL;DR）改寫成自包含、能獨立讀懂，禁止留下指向不存在 issue 的死連結。

## Multi-Issue 撰寫規範（Parent 與 Sub-Issue）

當一個複雜任務要拆成一個 parent issue 加多個 GitHub 原生 sub-issue 時適用本節；本節疊加在既有 Issue 撰寫規範之上，不取代它。

**拆解規劃階段**：在派工 issue-pr-content-drafter 產生大綱之前，先由 issue-pr-publisher 產出一份「拆解地圖」，內容包含 parent 的整體目標、sub-issue 清單（每個附一句話範圍），以及 sub-issue 之間的順序與依賴關係（誰阻擋誰、誰解鎖誰）。拆解規劃留在 issue-pr-publisher 層、不委派給 issue-pr-content-drafter，因為拆解需要完整的 plan file 與對話脈絡，而 issue-pr-content-drafter 沒有這些脈絡。拆解地圖產出後，連同來源材料一起提供給 issue-pr-content-drafter，由它在同一次派工中為 parent 與每個 sub-issue 各自產出分層大綱。

**Sub-issue 專屬輕量骨架**：sub-issue 不照抄 parent 的完整 description 骨架，也不開分層 comment 序列，改用以下四段，繁體中文依序排列：

1. **定位** — 這個 sub-issue 屬於哪個 parent、是整體計畫的第幾步（共幾步）、依賴哪些 sub-issue、完成後解鎖哪些；並重述最小必要背景，讓這個 sub-issue 能獨立讀懂。
1. **Spec** — 具體要做什麼，實作範圍與規格。
1. **完成後的系統行為變化** — 這個 sub-issue 被 merge 後可觀察的前後對照。
1. **Acceptance Criteria** — 這個 sub-issue 的驗收條件。

圖優先原則、以及來源不足即省略、不捏造內容的原則，同樣適用於 sub-issue。

**雙向連結**：sub-issue 端由定位段承載回連 parent 與依賴標註。parent 端則在其 description 新增「拆解總覽」一段，列出所有 sub-issue 與其順序、依賴關係，優先用一張依賴圖表達，依圖示策略章節完成選型；parent 末尾的 Signposting 導讀也要擴充，指向各 sub-issue。自包含帶來的最小背景重述是刻意的取捨，換來 reviewer 逐一查看 sub-issue 時零跳躍。

**兩階段建立與冪等性**：parent 的拆解總覽要引用 sub-issue 編號、sub-issue 的定位段要引用 parent 與手足的編號——這些交叉引用編號在 issue 建立前都還不存在，形成循環，因此建立分兩階段進行：

1. **階段一** — 建立 parent 與所有 sub-issue，取得各自編號；此時內文尚無法填入還不存在的交叉引用編號。
1. **階段二** — 所有編號到手後，issue-pr-publisher 委派 issue-pr-content-drafter 產出含完整交叉引用的最終內文，彙整結果後交由 github-manager 就地更新各 issue 內文，並建立原生父子關聯。

冪等性上與更新冪等性章節一致：內文更新是整體替換，沒有重複風險；委派建立原生父子關聯同樣是冪等的，重複委派不會產生重複關聯，由 github-manager 自行保證。

## 更新冪等性

- **Issue**：更新既有 issue 前，必須先請 github-manager 取回該 issue 現有的分層 comment（內容與各則的識別），作為就地更新的依據；issue-pr-publisher 本身不執行 gh，無法自行取得此資訊。取得既有 comment 現況後，針對對應內容做就地更新，而不是重新張貼一整串。本 skill 讓 issue 帶有有序的 comment 序列，若更新時重跑整套流程，同一份分層內容就會被重複貼成多串。
- **PR**：此風險不適用。每次編輯 PR 是整體替換內文，不存在重複問題。

## 圖示策略

圖優先原則適用於全篇——包含 description 與 comment——不限定只用在特定段落。

所有圖在產生之前，都必須先完成圖表類型的選型，以符合此 repo 既有的圖表輸出規範。

對本 repo 的 issue 與 PR 而言，外部 renderer 可接受；當 d2、PlantUML
等需經外部 renderer 的圖在表達力上更適合時，可直接選用，不必為了原生
算繪而退回表達力較弱的圖。安全邊界不變：含有敏感或內部資訊的圖不得送往
kroki 這類外部 renderer，遇此情況應改用原生可算繪的圖，或退回結構化的
表格與清單文字。

## 建立與修改一致性

不論是建立全新的 issue 或 PR，還是修改既有的 issue 或 PR，都必須維持相同的大綱結構。修改既有 description 時，如果發現缺少某些段落，要主動補齊並重排 description 骨架；重排僅適用於 description，不適用於 comment 序列。

修改既有 issue 的 comment 時，依更新冪等性規則就地更新對應則次，不嘗試重建順序；若既有順序有誤，應在 comment 內容中說明，而非刪除重建。

## Comment 輕量溝通

對 issue 或 PR 的一般 comment，預設使用繁體中文撰寫，不套用任何結構模板——這類 comment 是日常輕量溝通，不需要強制結構化。

注意：此節的「comment」指日常討論回覆，與 Issue 撰寫規範中作為分層揭露載體的結構化 comment 序列是不同用途，兩者不應混淆。
