---
name: search-handling
description: obsidian-notes skill 的搜尋結果回報協定，定義搜尋筆記後的 link 展開規則與 unresolved link 互動流程
---

# 搜尋結果回報協定

## 觸發條件

本協定僅在 SKILL.md 將 main agent 引導至本檔案時生效。外部觸發判準由 SKILL.md 負責，本檔案不重複列舉觸發情境。

## 核心原則

1. **搜尋找到 note 後主動列出關聯 links**：對每一筆結果，回報三個面向的 link 資訊——outgoing links（此 note 連出的 links）、backlinks（其他 note 連入此 note 的 links）、unresolved links（此 note 中指向尚未存在於 vault 之 note 的 links）
1. **link 一律只列 title，不附內容**：連結到的 note 內容由使用者明確要求時才另行抓取，不在搜尋回報階段主動展開
1. **link 資料委派 obsidian-manager 取得**：main agent 不指定 CLI 命令或內部實作方式，由 obsidian-manager 全權決定如何查詢

## 搜尋結果數量閘門

根據搜尋結果的筆數，採取不同的回報行為：

- **1 至 3 筆**：對每一筆 note 附上完整 link 列表（outgoing、backlinks、unresolved 三組）
- **超過 3 筆**：只列出 note titles，不附 links；使用者後續若指定某一筆，再按單筆規則處理該筆的 links

> [!NOTE]
> 3 筆是 main agent 一次掃完仍有意義的上限。超過 3 筆通常代表查詢尚未收斂，此時主動列出所有 links 會誤導探索方向，也會讓回應量過大而稀釋真正有用的資訊。

## Link 呈現格式

回報時必須按以下三組分組呈現，每個 link 只顯示 title：

- **Outgoing**：此 note 主動連出的 links
- **Backlinks**：其他 note 連入此 note 的 links
- **Unresolved**：此 note 中指向尚未存在於 vault 之 note 的 links，每個項目須加上 `unresolved:` 前綴明確標記

> [!NOTE]
> **什麼是 unresolved link**：在 Obsidian 中，以 wiki-link 語法（雙方括號）所寫的連結，若指向的 note 尚未存在於 vault 中，即為 unresolved link。這類 link 通常代表使用者當時有意擴展但尚未動筆的主題，是 vault 中潛在的知識缺口。

## Unresolved Link 處理流程

### 互動觸發條件

當搜尋結果中有任何 note 含有 unresolved links 時，main agent 必須在回報完 link 列表後，主動進入 unresolved 處理詢問流程，不可僅列出就帶過。

### 詢問粒度

以「每個 note」為單位集合詢問，不逐 link 個別發問。若某 note 有多個 unresolved links，在一次回應中一次列出全部並請使用者決定，而不是分多次發問。

### 建議與理由的義務

Main agent 必須對每個 unresolved link 主動提出建議方向，並說明理由。提出建議前，main agent 應先委派 obsidian-manager 取得 link 所在段落的上下文內容——沒有上下文支撐的建議不被允許。

建議選項只有兩種：

- **選項 A：移除並微調內容** — 刪除 link 包裝後，連帶微調該 link 周邊的句子或段落文字，讓敘述不再提到這個被移除的 link。「調整內容」不是獨立選項，而是「移除 link」的標準伴隨動作。
- **選項 B：建立缺失的 note** — 在 vault 中建立該 unresolved link 對應的新 note，可為空 note 或附帶初始內容。

**建議邏輯對照範例：**

**範例一（建議 B）**：unresolved link `[[批次處理優化]]` 出現在「相關技巧可參考 [[批次處理優化]]」這類引導性句子中，語意上明顯有「之後要展開這個主題」的意圖。→ 建議 B，建立缺失的 note。

**範例二（建議 A）**：unresolved link `[[GraphQL 訂閱機制]]` 出現在「順帶一提，[[GraphQL 訂閱機制]] 也有類似的優化空間」這類裝飾性提及中，只是順帶帶過，並非本 note 的核心脈絡。→ 建議 A，移除 link 並微調周邊文字。

### 使用者回應的處理

使用者可對同一 note 內的不同 unresolved links 選擇不同方向，例如 2 個用 A、1 個用 B；也可以選擇 **N（略過）**，不處理特定 link。

**選項 A 的執行**：Main agent 先提案改寫後的句子供使用者審核，使用者接受後，委派 obsidian-md-editor 編輯該 note 的 body，移除 link 並套用審核通過的微調文字。

**選項 B 的執行**：直接走 SKILL.md 既有的「建立筆記」情境分流。若使用者要求空 note 則依「建立不需要初始內容的空筆記」流程；若使用者要求附帶初始內容則依「建立需要初始內容的新筆記」流程。本 reference 不重複描述這些流程，僅指向 SKILL.md。

## 回報格式

搜尋結果回報給使用者時，至少須包含以下資訊：

- **Note title 與辨識資訊**：包含 note title 與路徑（或足以辨識的資訊）
- **Link 清單（筆數 ≤ 3 時）**：Outgoing、Backlinks、Unresolved 三組的 title 清單；Unresolved 項目須加 `unresolved:` 前綴
- **Unresolved 處理詢問（有 unresolved 時）**：每個 unresolved link 的周邊上下文摘要、main agent 的建議方向（A 或 B）與建議理由
