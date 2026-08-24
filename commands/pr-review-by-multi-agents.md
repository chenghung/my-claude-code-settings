---
description: 派出 claude、codex、opencode 三個獨立的 AI CLI 對同一個 GitHub Pull Request 各做一次完整 code review，每一份結果成為該 PR 上一則獨立的 comment。
---

# PR Review by Multi-Agents

觸發 `pr-review-by-multi-agents` skill，依該 skill 當時的定義執行完整流程；本 command 不重新描述那些步驟，也不改寫其中任何一步——重複描述會在 skill 演進後變成兩份互相矛盾的說明。

## 參數

`$ARGUMENTS` 為自由文字，可包含下列兩項資訊，兩者皆可省略：

- 目標 PR 的連結或編號。省略時由 skill 依當前分支自行判斷要派往哪個 PR；是否需要先向使用者確認，依 skill 當時的定義處理，不在此重述。
- 本次工作採用的 design document 絕對路徑。省略時，design 符合度這一審查軸會被略過，reviewer 會在各自的 comment 中據實載明未審此軸。

issue 不需要在這裡指定：腳本會從目標 PR 內文的 closing keyword 自行推導，不必也不應在自由文字中重複給出。

## 影響範圍

會動到的：目標 PR 上會新增最多三則 AI review comment；執行期間會在使用者當前 repo 暫時建立一個工作用的 git worktree 與本地分支，並對 base 分支的遠端追蹤 ref 做強制更新、強制刪除陳舊的同形狀分支——完整清單見 `pr-review-by-multi-agents` skill 定義中的「已知限制」節。正常結束時由腳本與 main agent 自動清理。

不會動到的：不修改 PR 本身的程式碼或倉庫中的任何既有檔案，不 approve、不 merge、不 close PR 或 issue；三個 reviewer CLI 對被審查的程式碼一律唯讀。
