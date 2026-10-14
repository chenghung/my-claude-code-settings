---
name: github-issue-authoring
description: >
  把 spec 或對話中提供的內容寫成 GitHub issue 的標題與 description 並交付發佈。建立或修改 GitHub issue 的標題或 description 時觸發，包含沒有 spec 的 issue，以及發佈一組已拆好的 parent 與 sub-issue。唯讀查詢、只改 label、assignee 或狀態等中繼資料、產生 spec、拆分任務，都不觸發本 skill。
---

# GitHub Issue Authoring

目標：把 spec 或對話中提供的內容寫成 GitHub issue，description 只放 feature spec、high-level 系統架構與 Key Decisions。

## 來源

- 有 spec 時，來源為 spec 檔。
- 沒有 spec 時，來源為使用者在對話中提供的內容，寫成精簡 issue，只寫來源有依據的段落。
- 整組發佈時另需拆分資訊：parent 與各 sub-issue 的內容範圍與依賴關係。
- 整組發佈缺拆分資訊時，停下回報，不自行拆分。
- 有 spec 而 spec 沒有 user story 時，停下回報，不自行編寫。
- 拆分資訊的依賴有循環時，停下回報，不建立任何 issue。

## 共同規則

- 標題用英文，description 用繁體中文。
- 來源沒有依據的段落省略，不捏造，不填 TBD。
- issue 只發佈 description，不張貼結構化 comment。
- description 不寫推導與探索過程。
- description 不引用本機或 repo 內的 spec 檔，讀者只看 issue 就能讀懂。
- description 的 `##` 段落標題照本檔骨架的段名原樣使用。

## 單一 issue 與 parent 的段落

依序為：

1. **Summary**：一段話說明要做什麼與為什麼。
1. **Background**：現況與痛點。
1. **Goal**：In Scope 與 Out of Scope。
1. **Spec**：來源中全部 user story，每則底下附情境式 AC，格式見 Spec 格式。
1. **Architecture**：只畫服務、模組、外部系統之間的關係與資料流向，不列 class、function 或檔案；需求沒有改變系統層級結構時整段省略。
1. **Key Decisions**：只放改變系統層級結構或使用者可觀察行為的決策；每項寫結論加一行理由，不寫被否決的方案。
1. **References**：只放第三方重要資訊，例如官方文件、RFC、上游 issue。

spec 中其餘實作層級的決策，例如 Implementation Decisions 裡的介面與 schema 細節，只用來推導 AC，不列入 Key Decisions。

parent 在 Architecture 與 Key Decisions 之間加「拆解總覽」：以依賴圖列出所有 sub-issue 的順序與依賴，每個 sub-issue 附一句範圍說明。

## sub-issue 的段落

sub-issue 只有兩段：

1. **定位**：所屬 parent、第幾步共幾步、依賴誰、解鎖誰，加上讓本 sub-issue 能獨立讀懂的最小背景。
1. **Spec**：列出拆分資訊分給它的 story 與 AC；只完成某則 story 的一部分時，改寫成技術 story，角色依 Spec 格式，並註明它支撐 parent 的哪一則 story。

## Spec 格式

- story 保留英文骨架 `As a`、`I want`、`so that`，內容用繁體中文。
- 技術 story 的角色為開發者或下游系統。
- AC 關鍵字 `Given`、`When`、`Then` 保留英文，描述用繁體中文。
- AC 可用 `And` 延續 `Given` 或 `Then`。
- 每個 AC 有一個非常簡短的名稱。
- spec 中沒有 AC 的 user story，逐則依該 story 與 spec 中的 Testing Decisions、Implementation Decisions 等內容寫出 AC；已有 AC 的 story 只補推得出依據、卻缺少的情境類別。
- 由此寫出的每個 AC 都能追溯到 spec 的某則 user story 或某項決策。
- 決策指 spec 中所有決策段落的每一條，包含 Implementation Decisions 與 Testing Decisions。
- 來源是對話且沒有 user story 時，Spec 段改為直接描述問題與預期行為，不湊 user story。
- 來源是對話時，AC 只在對話內容能支撐時才寫。
- 每則 user story 的 AC 涵蓋正常、邊界與失敗情境；某類情境在來源中推不出依據時才省略。

```text
As a <角色>, I want <需求>, so that <目的>

AC：<名稱>
Given <前提>
When <動作>
Then <可驗證的結果>
```

## 圖

- Architecture 與拆解總覽用圖呈現。
- repo 不是 public 時，圖只用本機工具預覽，本機工具不可用時略過預覽；`render.sh` 印出 kroki.io URL 時不開啟，視為略過預覽。
- repo 不是 public 時，圖用 GitHub 能原生算繪的 mermaid，不以外部 renderer 的圖片 URL 嵌入 issue，因為每次瀏覽都會把圖送到第三方。
- 上兩條優先於 `diagram-output` rule 與 `diagram-designer` skill 的預覽要求與語法建議。

## 流程

1. 整組時，寫草稿前先定好每個 issue 的標題，同一組 issue 的標題互不重複。自行訂定的標題重複時改名使其互不重複，不停下；拆分資訊給定的標題重複時，停下回報。
1. 每個 issue 的草稿各寫入一個暫存檔，草稿檔只放 description，不含標題；標題另交 `github-manager`。
1. 整組時，草稿中的交叉引用先以 `{{ref:<issue 標題>}}` 佔位。
1. 整組時，另把拆分資訊寫入暫存檔，標明每個 issue 的標題、每個草稿檔對應 parent 或哪一個 sub-issue，以及每個 sub-issue 負責的 AC 名稱。
1. 沒有 spec 時，把對話中的來源內容寫成來源暫存檔，只用來作為 spec 交給 `issue-content-reviewer`。
1. 交 `issue-content-reviewer` 審一輪，傳入全部草稿檔與 spec 檔的絕對路徑；整組時一併傳入拆分資訊檔的絕對路徑。
1. 同一任務要寫多個互不相關、非整組的 issue 時，每個 issue 各自送審一次，不一起送。
1. `issue-content-reviewer` 回報失敗（缺輸入、檔案讀不到或為空、草稿無法對應）時，停下回報，不發佈，不視為已審查。
1. 自行判斷每則 finding 是否成立，修正成立者，不再送審。
1. 交 `github-manager` 發佈；單一 issue 直接建立或替換，整組依下節兩階段進行。
1. `github-manager` 回報需由使用者處理的失敗（`gh` 未登入、rate limit）時，停下回報，不重跑。

### 整組兩階段發佈

1. 階段一：委派 `github-manager` 建立 parent 與全部 sub-issue，交出每個 issue 的標題與含佔位的 description 草稿檔，取得標題、編號與 URL 對照表。
1. 階段二開始前，核對對照表涵蓋 parent 與全部 sub-issue。
1. 對照表缺少的 issue 在 `github-manager` 回報的未完成項目中時，依下方重跑規則只重送那些項目。
1. 對照表缺少的 issue 不在未完成項目中時，停下回報，不重跑，因為重跑可能重複建立 issue。
1. 依對照表把草稿中的佔位換成實際編號。
1. 佔位中的標題不在對照表中時，停下回報，不進入階段二。
1. 搜尋全部草稿檔找不到 `{{ref:` 才算替換完成。
1. 階段二：另一次委派 `github-manager`，交出 parent 編號，以及每個 issue 的編號與其最終 description 檔的對應，整份更新每個 issue 並建立原生父子關聯。

- 任一階段中途失敗後重跑時，只委派 `github-manager` 回報為該階段未完成的項目。
- 每個階段最多重跑一次；重跑後仍失敗時，停下回報。
- 階段一重跑時，合併各次回傳的對照表，並把失敗回報中已完成項目的標題、編號與 URL 一併算入；已完成項目缺編號時，停下回報。

## 修改既有 issue

- 只改標題時，只交 `github-manager` 更新標題，不重寫 description，不送審。
- 修改 description 時依下列步驟：

1. 先請 `github-manager` 取回現有 description，以及該 issue 的 parent 與 sub-issue 關聯。
1. 該 issue 有 parent 或 sub-issue 時視為整組成員，另取回 parent 與全部 sub-issue 的編號與 description；沒有時視為單一 issue。
1. 來源為最新的 spec；使用者的修改要求沒有對應 spec 時，把既有 description 與修改要求寫成一份來源暫存檔，只用來作為 spec 交給 `issue-content-reviewer`，避免既有內容被判為捏造。
1. 此來源暫存檔比照來源是對話的規則處理：沒有 user story 時，Spec 段直接描述問題與預期行為。
1. 依本 skill 的段落骨架整份重寫，只補齊來源有依據的段落。
1. 整組成員另寫拆分資訊檔，內容為 parent 與全部 sub-issue 的既有編號、標題、範圍與依賴，並標明每個草稿檔對應哪一個 issue 與每個 sub-issue 負責的 AC 名稱；與草稿一併傳給 `issue-content-reviewer`。
1. 整組成員的交叉引用直接寫拆分資訊檔中的既有編號，不用佔位，不走兩階段發佈。
1. 依流程審查與修正後，交 `github-manager` 整份替換 description。
