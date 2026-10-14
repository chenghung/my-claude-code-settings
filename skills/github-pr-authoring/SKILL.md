---
name: github-pr-authoring
description: "依本機分支相對 base branch 的 diff 撰寫 GitHub PR 的標題與 description，並交付發佈。建立 PR，或修改 PR 的標題或 description 時觸發；審查 PR、回覆或收合審查留言、唯讀查詢 PR、只改 label、assignee、reviewer 等中繼資料時不觸發。"
---

# GitHub PR Authoring

目標：加速人類 review PR。Summary 讓人類建立心智模型，Merge Danger 指出風險來源與該細看的改動，Evidence 讓人類不必自己重現。

## 輸入

- base branch：修改既有 PR 時，以該 PR 的 base branch 為 base；其餘情況未指定時用 repo 預設分支。
- head：本機分支，PR 可尚未建立。
- 關聯 issue 編號：可省略。

## 流程

修改既有 PR 時，先委派 `github-manager` 取回現有標題、description、base branch 與 head 分支名。

修改既有 PR 且使用者未提供 issue 編號時，從取回標題的結尾與 description 的開頭擷取既有的關聯 issue 參照作為 issue 編號；兩處都沒有時才視為無關聯。

只改標題時，跳過草稿與審查，直接委派 `github-manager` 改標題，並附 issue 編號或無關聯 issue 的聲明。

只改 description 時，沿用現有標題，不重新產生；交給 `github-manager` 前去掉標題結尾的關聯 issue 參照。

撰寫或修改 description 時：

1. 修改既有 PR 且本機分支與取回的 head 分支名不一致時，停下回報，不計算 diff、不 push。
1. 計算 diff 前先 fetch base 分支；遠端已有 head 分支時一併 fetch。
1. 遠端 head 有本機沒有的 commit 時，停下回報。
1. 計算 diff 前，tracked 檔有未 commit 的改動時，停下回報，untracked 檔不算；三點 diff 與 push 都不含未 commit 的改動。
1. 改動描述以 `git diff <base>...<head>` 的三點 diff 為唯一來源，不依賴對話中對改動的記憶；三點 diff 與 `pr-content-reviewer` 核對的範圍相同。
1. base 用遠端追蹤分支，例如 `origin/<base>`，不用本機 base 分支。
1. 把 description 草稿寫入暫存檔。
1. 委派 `pr-content-reviewer` 審一輪，提供草稿檔絕對路徑，以及與計算 diff 時相同的 base ref 與 head ref。
1. `pr-content-reviewer` 回報失敗時，停下回報，不發佈。
1. 自行判斷每項 finding 是否成立，修正成立者，不再送審。
1. 本機 head 有遠端沒有的 commit 時，先自行 push；`github-manager` 不做 push。
1. push 被拒或需要 force push 時，停下回報。
1. 委派 `github-manager` 發佈，提供標題、草稿檔路徑，以及關聯 issue 編號或無關聯 issue 的聲明；建立 PR 時另提供不含 remote 前綴的 base 與 head 分支名；修改既有 PR 時另提供 PR 編號。

修改既有 PR 的 description 時，依本檔骨架整份重寫並替換；保留現有 description 中無法從 diff 重現的內容，依其性質放回對應段落；只排除 description 開頭的關聯 issue 參照，其他位置引用的 issue 照常保留。repo 不是 public 時，不保留外部 renderer 的圖片 URL。

## 撰寫規則

- 標題用英文，簡潔且易於搜尋。
- 不在標題結尾與 description 開頭寫關聯 issue 的參照，`github-manager` 收到 issue 編號後自行補上；description 其他位置的 issue 引用照常保留。
- description 的 `##` 段落標題用英文，其餘內容用繁體中文；粗體標籤照骨架原樣使用。
- 不寫開場白，文字簡短。
- repo 有 `GLOSSARY.md` 時，使用其中的領域用語。
- 以合併後的最終改動為主角，不逐一說明 commit。
- 沒有關聯 issue 時，寫成不必讀任何 issue 也能理解的 Summary。

## Description 骨架

```markdown
## Summary

<一句話：解決什麼問題，以及對既有行為改了什麼>

<視圖，各附緊鄰的短文字>

## Merge Danger

**Door**：<單向門或雙向門>。<回退方式>

**Blast Radius**：<模組內、跨模組、使用者或外部系統>。<可能後果>

**風險來源**：

1. <風險>：<為何有風險>

**Focus**：

- `<檔案或位置>`：<要確認什麼>
- 可快速略過：<機械式改動的範圍>

## Evidence

- **Before**：<截圖或執行結果>
- **After**：<截圖或執行結果>
```

### Summary

- 開場一句說明解決什麼問題，以及對既有行為改了什麼；未改既有行為時寫明既有行為不變。
- 以視圖呈現改動，文字只用來支撐視圖。
- 依改動性質選最小且最能說清楚重點的視圖：

  | 改動性質 | 視圖 |
  | --- | --- |
  | 邏輯或演算法 | pseudocode |
  | 執行期控制流程 | call tree |
  | UI 結構 | component tree，標出 state 與模組邊界 |
  | 檔案職責或大範圍重構 | 淺層 file tree，附註解 |
  | 元件互動或資料流 | mermaid sequence diagram |

- 結構原本存在時用 diff sketch：把視圖寫成 `diff` 區塊，以 `+`、`-` 標出變化，不貼實際的程式碼 diff。例如 call tree 的變化：

  ```diff
   submitForm
     createSession
  +    expandSkillMention
       launchAgent
  -  navigateToSession
  ```

- 新增的元素多於既有元素時，給完整區塊，不用 diff sketch。
- 每個視圖緊鄰支撐它的短文字。
- 視圖只留與本次改動相關的節點、檔案、state 與邊界。
- 可用一種或幾種視圖，不全用。
- repo 不是 public 時，視圖只用本機工具預覽，本機工具不可用時略過預覽；`render.sh` 印出 kroki.io URL 時不開啟，視為略過預覽。
- repo 不是 public 時，需算繪的視圖用 GitHub 能原生算繪的 mermaid，不以外部 renderer 的圖片 URL 嵌入 description，因為每次瀏覽都會把圖送到第三方。
- 上兩條優先於 `diagram-output` rule 與 `diagram-designer` skill 的預覽要求與語法建議。

### Merge Danger

- 合併後無法單靠 revert 這個 PR 復原的改動是單向門，例如破壞性的資料 migration、刪除資料、已被外部使用的介面或格式的改動。
- Blast Radius 依實際波及範圍，從由小到大的模組內、跨模組、使用者、外部系統中選波及最遠的一個。
- 風險來源依嚴重度由高到低排序。
- 沒有風險來源時，風險來源寫「無」，不湊數。
- Focus 先列入每一項單向門改動，以及 Blast Radius 超出被修改模組的改動。
- diff 含非機械式改動時，Focus 至少列出一項最核心的改動位置。
- 沒有單向門或 Blast Radius 超出被修改模組的改動，且整個 diff 都是機械式改動時，Focus 的核心位置寫「無」。
- diff 含機械式改動，例如重新命名、格式化或產生的檔案時，在 Focus 用一行標明可快速略過的部分；核心位置寫「無」時也照列。

### Evidence

- 視覺改動用截圖，其他改動用執行結果。
- 截圖需要可存取的圖片 URL；沒有時，視覺改動也改用執行結果。
- repo 不是 public 時，截圖不上傳到第三方圖床；拿不到合規的圖片 URL 時改用執行結果。
- 修 bug 或新增行為且 diff 含對應測試時，以 pseudocode 寫出該測試的斷言與新舊行為。
- 有實際執行取得的結果時，測試 pseudocode 放在 Before 與 After；沒有時，放在驗證方式說明中，不放 Before 與 After。
- 只有實際在 base 與 head 各執行過該測試時，才寫之前失敗、現在通過的執行結果。
- base 端的失敗限於該測試斷言本身失敗；因環境或缺依賴而失敗時，改寫驗證方式說明。
- head 新增的測試可複製到 base 的 worktree 執行，其斷言失敗算作 base 端失敗。
- 在 base 執行測試時，另開 worktree 執行，跑完後移除，不在目前工作樹 checkout 或 stash；stash 堆疊由所有 worktree 共用。
- 只引用存在於 head 且與 diff 相關的測試檔、測試案例或指令。
- 不寫未實際執行取得的輸出。
- 沒有實際執行取得的結果時，不寫 Before 與 After，改寫實際做過的驗證方式；沒有任何驗證時，寫明未驗證。
