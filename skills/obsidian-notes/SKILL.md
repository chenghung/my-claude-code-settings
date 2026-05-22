---
name: obsidian-notes
description: >
  統籌處理所有 Obsidian vault 操作，包含結構性操作（筆記建立、重新命名、移動、刪除、daily note、backlink 查詢、frontmatter 屬性讀寫、tag 操作、模板操作等）以及 vault 內既有筆記的內容撰寫與編輯（包括 Obsidian 專屬語法如 wiki-link、embed、block reference、callout、typed property 等）。觸發關鍵字：Obsidian、obsidian、vault、wiki-link、daily note、backlink、frontmatter property、嵌入筆記、block reference
---

# Obsidian Notes

## 定位

此 skill 統籌 Obsidian vault 的所有操作，涵蓋兩大類：

- **結構性操作**：建立、改名、移動、刪除筆記、daily note 操作、backlink 與 unresolved link 查詢、tag 操作、frontmatter 屬性讀寫、模板操作等
- **內容撰寫與編輯**：vault 內既有筆記的 body 內容，包括需要套用 Obsidian 專屬語法的場合

Skill 本身只負責情境判斷與委派，實際操作由對應的 subagent 執行。Main agent 不直接修改 vault 內的任何檔案。

## 涉及的 Subagent

**obsidian-manager** 負責所有涉及 vault 結構的問題，包含：建立、改名、移動、刪除筆記、daily note 的開啟與附加內容、backlink 與 unresolved link 查詢、tag 列舉與重新命名、frontmatter property 讀寫、模板插入等。

**obsidian-md-editor** 負責所有涉及 vault 內既有筆記 body 內容的問題，特別是需要套用 Obsidian 專屬語法（wiki-link、embed、block reference、Obsidian callout、typed property 等）的撰寫與編輯場合。

## 情境分流

### 目錄 index note 的偵測與雙向連結維護

此流程是所有「在某個目錄下建立新筆記」場景的共通前置與後置程序，適用於 vault 中任何子目錄，以及 vault 根目錄本身。

> [!NOTE]
> 當要建立的目標筆記**本身就是 index note** 時，跳過此流程以避免遞迴。

**Index note 的定義**：一份筆記是否為 index note，以其是否擁有名為 `index` 的 tag 判定，與檔名無關。允許 `index.md`、`_index.md`、與資料夾同名的 folder note、MOC 命名等不同慣例並存；所有 index note 必須包含 `index` tag。

**前置步驟（在建立筆記前執行）**：

1. Main agent 委派 `obsidian-manager`，查詢目標目錄下是否已存在帶有 `index` tag 的 note。
1. 若不存在：Main agent 以本節下方的「建立需要初始內容的新筆記」或「建立不需要初始內容的空筆記」流程，在該目錄先建立一份帶有 `index` tag 的 index note。建立此 index note 時視為 index note 本身，不再遞迴觸發本流程。
1. 若已存在：記錄該 index note 的路徑與顯示名稱，供後置步驟使用。

**後置步驟（在建立筆記後執行）**：

1. 在新建立的筆記中插入一條指向 index note 的 wiki-link，作為回到 index 的 back-link 入口。
1. 在 index note 中插入一條指向新筆記的 wiki-link，作為從 index 連向新筆記的正向連結。
1. 雙向連結的實際插入位置與排版由 `obsidian-md-editor` 自行判斷。內容寫入既有筆記時委派 `obsidian-md-editor` 執行；若涉及新建立筆記的內容寫入，沿用「先寫入暫存檔再由 `obsidian-manager` 建立」的交接模式。

### 建立需要初始內容的新筆記

> [!NOTE]
> 建立新筆記前，須先執行上方「目錄 index note 的偵測與雙向連結維護」的前置步驟；建立完成後，須執行其後置步驟。當本筆記本身即為 index note 時跳過該流程。
>
> 若使用者未完整指定 tag（完全未指定或只給了部分 tag），必須先執行下列前置步驟，再進入步驟一。

**前置步驟（tag 未完整指定時）**：Main agent 讀取本 skill 目錄下的 `references/tag-handling.md`，依其協定決定 tag。已決定的 tag 由 `obsidian-md-editor` 寫入暫存檔的 frontmatter，後續由 `obsidian-manager` 連同內容一併建立筆記。

1. Main agent 委派 `obsidian-md-editor`，將筆記內容寫入工作區 `.tmp` 目錄下的暫存檔（存放位置依 `tmp-file-usage` rule 規定）。
1. Main agent 委派 `obsidian-manager`，傳入暫存檔路徑，由其讀取內容並在 vault 內建立筆記。
1. 確認筆記建立成功後，main agent 清除暫存檔。

### 建立不需要初始內容的空筆記

> [!NOTE]
> 建立新筆記前，須先執行上方「目錄 index note 的偵測與雙向連結維護」的前置步驟；建立完成後，須執行其後置步驟。當本筆記本身即為 index note 時跳過該流程。

直接委派 `obsidian-manager`，由其在 vault 內建立空筆記。無需動用 `obsidian-md-editor`，也不需要暫存檔交接。

### 編輯既有筆記的內容

直接委派 `obsidian-md-editor`，操作 vault 內的目標檔案。無需動用 `obsidian-manager`，也不需要暫存檔交接。

**後置步驟（主題擴展時）**：若本次編輯涉及主題擴展（新增段落、引入新概念、新增章節），在編輯完成後，main agent 讀取本 skill 目錄下的 `references/tag-handling.md`，依其協定評估是否需要調整 tag。純錯字修正、潤飾、格式調整不觸發此步驟。需要調整 tag 時透過 `obsidian-manager` 寫入 frontmatter。

### 搜尋筆記

當使用者意圖是搜尋筆記時——無論搜尋方式是 keyword 全文搜尋、tag 查詢、frontmatter 條件查詢，或模糊問句（例如「我有寫過 X 嗎？」）——main agent 必須讀取本 skill 目錄下的 `references/search-handling.md`，依其協定執行搜尋回報與 unresolved link 後續處理。實際的搜尋與 link 資料取得委派 `obsidian-manager`。

> [!NOTE]
> 使用者明確指定 wiki-link（例如 `[[note 名稱]]`）並要求開啟或讀取該 note 的場合，屬於直接取用而非搜尋，不觸發此流程。

### 結構性操作

改名、移動、刪除筆記、修改 frontmatter property、查詢 backlink 與連結關係等，一律委派 `obsidian-manager`。

## 委派 Prompt 注意事項

傳給 subagent 的 prompt 只需包含目標、所需資訊與意圖，不應指定 subagent 內部應使用哪個工具或哪條 CLI 命令。實際執行細節由 subagent 全權決定。

> [!NOTE]
> 傳給任一 subagent 的 prompt 必須以純文字呈現，不得夾帶 markdown 格式語法。格式決策由 subagent 自行判斷處理。
