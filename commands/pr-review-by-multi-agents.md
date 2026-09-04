---
description: 派出多個獨立的 AI CLI（claude、codex、opencode、agy 中依所選組合而定）對同一個 GitHub Pull Request 各做一次完整 code review，各份結果彙整成該 PR 上一則 comment。
---

# PR Review by Multi-Agents

觸發 `pr-review-by-multi-agents` skill，依該 skill 當時的定義執行完整流程。

## 參數

`$ARGUMENTS` 為自由文字，可包含下列兩項資訊，兩者皆可省略：

- 目標 PR 的連結或編號。省略時由 skill 依當前分支判斷要派往哪個 PR。
- 本次工作採用的 design document 絕對路徑。省略時 design 符合度這一審查軸會被略過。

issue 不必在此指定，由 skill 自行推導。

## 會動到什麼

會動到的：目標 PR 上新增一則 AI review comment；當前 repo 中暫時建立 git worktree 與本地分支，並強制刪除同形狀的陳舊分支（派出前先請你確認）；家目錄下建立產出物目錄。

不會動到的：不 approve、不 merge、不 close PR 或 issue；不修改 PR 的程式碼與倉庫中的既有檔案。

詳細清單與其界線見 `pr-review-by-multi-agents` skill 定義。
