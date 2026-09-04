---
description: 派出多個獨立的 AI CLI（claude、codex、opencode、agy 中依所選組合而定）對同一個 GitHub Pull Request 各做一次完整 code review，結果張貼到該 PR 上：派出多家時彙整成一則，只派一家時是該平台未經交叉比對的原始 review。
---

# PR Review by Multi-Agents

觸發 `pr-review-by-multi-agents` skill，依該 skill 當時的定義執行完整流程。

## 參數

`$ARGUMENTS` 為自由文字，可包含下列兩項資訊，兩者皆可省略：

- 目標 PR 的連結或編號。省略時由 skill 依當前分支判斷要派往哪個 PR。
- 本次工作採用的 design document 絕對路徑。省略時 design 符合度這一審查軸會被略過。

issue 不必在此指定，由 skill 自行推導。

## 會動到什麼

會動到的：目標 PR 上新增一則 AI review comment（合流沒產出時退回逐則張貼，可能各平台各一則）；當前 repo 中 fetch base 分支與 pull ref 並強制更新 base 的遠端追蹤 ref、建立 worktree 與本地分支、強制刪除同形狀的陳舊分支（派出前先請你確認）、清掉前次執行殘留的 worktree 登記；家目錄下建立產出物目錄。收尾會清掉本次的 worktree 與分支，但有清不掉而留下的情形。

不會動到的：不 approve、不 merge、不 close PR 或 issue；不修改 PR 的程式碼（擋著的只有 worktree 的唯讀權限位元，同一個使用者身分改得回去），也不修改你 repo 裡的既有檔案（只有契約擋著，那裡沒有任何一層鎖）。

詳細清單與其界線見 `pr-review-by-multi-agents` skill 定義。
