---
name: obsidian-notes
description: >
  統籌處理所有 Obsidian vault 操作，包含結構性操作（筆記建立、重新命名、移動、刪除、daily note、backlink 查詢、frontmatter 屬性讀寫、tag 操作、模板操作等）以及 vault 內既有筆記的內容撰寫與編輯（包括 Obsidian 專屬語法如 wiki-link、embed、block reference、callout、typed property 等）。觸發關鍵字：Obsidian、obsidian、vault、wiki-link、daily note、backlink、frontmatter property、嵌入筆記、block reference
---

# Obsidian Notes

- [定位](#定位)
- [涉及的 Subagent](#涉及的-subagent)
- [情境分流](#情境分流)
  - [建立需要初始內容的新筆記](#建立需要初始內容的新筆記)
  - [建立不需要初始內容的空筆記](#建立不需要初始內容的空筆記)
  - [編輯既有筆記的內容](#編輯既有筆記的內容)
  - [結構性操作](#結構性操作)
- [委派 Prompt 注意事項](#委派-prompt-注意事項)

## 定位

此 skill 統籌 Obsidian vault 的所有操作，涵蓋兩大類：

- **結構性操作**：建立、改名、移動、刪除筆記、daily note 操作、backlink 與 unresolved link 查詢、tag 操作、frontmatter 屬性讀寫、模板操作等
- **內容撰寫與編輯**：vault 內既有筆記的 body 內容，包括需要套用 Obsidian 專屬語法的場合

Skill 本身只負責情境判斷與委派，實際操作由對應的 subagent 執行。Main agent 不直接修改 vault 內的任何檔案。

## 涉及的 Subagent

**obsidian-manager** 負責所有涉及 vault 結構的問題，包含：建立、改名、移動、刪除筆記、daily note 的開啟與附加內容、backlink 與 unresolved link 查詢、tag 列舉與重新命名、frontmatter property 讀寫、模板插入等。

**obsidian-md-editor** 負責所有涉及 vault 內既有筆記 body 內容的問題，特別是需要套用 Obsidian 專屬語法（wiki-link、embed、block reference、Obsidian callout、typed property 等）的撰寫與編輯場合。

## 情境分流

### 建立需要初始內容的新筆記

1. Main agent 委派 `obsidian-md-editor`，將筆記內容寫入工作區 `.tmp` 目錄下的暫存檔（存放位置依 `tmp-file-usage` rule 規定）。
1. Main agent 委派 `obsidian-manager`，傳入暫存檔路徑，由其讀取內容並在 vault 內建立筆記。
1. 確認筆記建立成功後，main agent 清除暫存檔。

### 建立不需要初始內容的空筆記

直接委派 `obsidian-manager`，由其在 vault 內建立空筆記。無需動用 `obsidian-md-editor`，也不需要暫存檔交接。

### 編輯既有筆記的內容

直接委派 `obsidian-md-editor`，操作 vault 內的目標檔案。無需動用 `obsidian-manager`，也不需要暫存檔交接。

### 結構性操作

改名、移動、刪除筆記、修改 frontmatter property、查詢 backlink 與連結關係等，一律委派 `obsidian-manager`。

## 委派 Prompt 注意事項

傳給 subagent 的 prompt 只需包含目標、所需資訊與意圖，不應指定 subagent 內部應使用哪個工具或哪條 CLI 命令。實際執行細節由 subagent 全權決定。

> [!NOTE]
> 傳給任一 subagent 的 prompt 必須以純文字呈現，不得夾帶 markdown 格式語法。格式決策由 subagent 自行判斷處理。
