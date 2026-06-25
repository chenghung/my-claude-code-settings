---
name: github-issue-pr-authoring
description: >
  當使用者想建立或修改 GitHub issue 或 PR 的標題或內文時觸發。依結構化模板在主對話層完成內容組裝，再將組裝好的標題與內文交給 github-manager 執行實際的 gh 指令。純查詢、列表、檢視等唯讀操作不觸發本 skill，直接交給 github-manager 處理即可。觸發關鍵字：github issue、github pr、pull request、開 issue、建立 issue、修改 issue、開 PR、issue description、PR description。
---

# GitHub Issue / PR Authoring

## 目標

本 skill 在主對話層（main agent）完成 issue 或 PR 的內容組裝，再把組裝好的標題與內文交給 github-manager 執行實際的 gh 指令；main agent 本身不執行 gh。

採這種分層是因為內容組裝需要 plan file 與整段對話脈絡，而解法圖示的類型選型也必須在 main agent 層先完成——這些都是執行型 subagent 拿不到或做不好的工作，因此讓內容在主層組裝、執行交給 github-manager。

## 觸發與不觸發

觸發時機：建立或修改 issue 或 PR 的標題或內文。

不觸發的情況：純查詢、列表、檢視等唯讀操作。這類操作直接交給 github-manager，不經本 skill。同樣地，若只是調整 label、assignee、狀態等中繼資料，而完全沒有更動標題或內文，也不觸發本 skill，直接交給 github-manager 處理。

## 內容來源優先序

組裝內容時，優先取用 plan file 的內容。當沒有 plan file 或 plan file 內容不足以填滿模板時，才以對話的最終脈絡補足。

## Issue 撰寫規範

**標題**：用英文撰寫，簡潔、易懂、容易被搜尋。

**內文**：用繁體中文，採以下八段固定結構：

1. **Background** — 先描述當前現況，再順勢帶出為什麼需要做這個變更（現況下的問題或痛點），讓讀者自然理解此 issue 的必要性。
1. **Goal** — 說明想達到的目標。必須明確列出 In Scope 與 Out of Scope，清楚界定這個 issue 只針對哪些範圍的行為或功能進行變更。
1. **Impact** — 說明這個變更可能帶來的正面與負面影響以及風險。
1. **Possible Solutions** — 說明討論過哪些可能的解法。以圖示為主、文字為輔，採由上而下循序漸進的方式把解法講清楚。
1. **Made Decisions** — 記錄討論過程中做了哪些重要決定、這些決定的考量是什麼、以及各自的優缺點。
1. **Acceptance Criteria** — 說明如何驗收以確認有達到 Goal。
1. **Summary** — 總結。
1. **References** — 列出討論過程中重要的參考資料來源。

## PR 撰寫規範

**標題**：用英文撰寫，簡潔、易懂、容易被搜尋。標題結尾的 issue number 由 github-manager 自動補上，本 skill 不自行加入。

**內文**：用繁體中文，採以下四段固定結構。開頭的 issue 連結由 github-manager 自動補上，本 skill 實際組裝的是後三段：

1. **Issue 連結** — 由 github-manager 自動補上，本 skill 不撰寫此段。
1. **解法摘要** — 簡略說明採用的解法，細節請 reviewer 參考對應的 issue description，不在 PR 重複。
1. **行為變更與重點提示** — 以整個 PR 的實際 code change 為基礎，說明這個 PR 被 merge 後會產生哪些行為變更，以及 reviewer 需要特別關注與確認的重要變更。禁止以逐一說明每個 commit 的方式來描述——每個 commit 自己的 message 已經說明了它的目的，逐 commit 重述只是浪費。
1. **Conclusion** — 結語。

## 圖示策略

所有圖示在產生之前，都必須先完成圖表類型的選型，以符合此 repo 既有的圖表輸出規範。

預設使用 mermaid 程式碼區塊——GitHub 會原生把它算繪成圖，純文字內文就能呈現圖示。當 mermaid 無法表達所需的圖形時，改用 kroki.io 把圖表算繪成圖片，再以 HTML 的 `<img>` 標籤嵌入到 issue 或 PR 內文中。

## 建立與修改一致性

不論是建立全新的 issue 或 PR，還是修改既有的 issue 或 PR，都必須維持相同的大綱結構。修改既有內容時，如果發現缺少某些段落，要主動補齊並重排成標準結構。

## Comment

對 issue 或 PR 的 comment，預設使用繁體中文撰寫，但不套用任何結構模板——comment 屬於輕量溝通，不需要強制結構化。

## 委派執行

把組裝好的最終標題與內文交給 github-manager 去執行實際的 gh 指令。

整合細節：github-manager 在處理連結 issue 的 PR 時，會自動在 PR 標題結尾補上 issue 參照、並在內文開頭補上 issue 連結，且此行為無法關閉。因此本 skill 在組裝 PR 內容時，不自行添加這兩項；只需把對應的 issue number 提供給 github-manager，由它自動補上，這樣才不會重複。
