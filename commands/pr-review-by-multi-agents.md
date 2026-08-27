---
description: 派出多個獨立的 AI CLI（claude、codex、opencode、agy 中依所選組合而定）對同一個 GitHub Pull Request 各做一次完整 code review，各份結果彙整成該 PR 上一則 comment。
---

# PR Review by Multi-Agents

觸發 `pr-review-by-multi-agents` skill，依該 skill 當時的定義執行完整流程；本 command 不重新描述那些步驟，也不改寫其中任何一步——重複描述會在 skill 演進後變成兩份互相矛盾的說明。

## 參數

`$ARGUMENTS` 為自由文字，可包含下列兩項資訊，兩者皆可省略：

- 目標 PR 的連結或編號。省略時由 skill 依當前分支自行判斷要派往哪個 PR；是否需要先向使用者確認，依 skill 當時的定義處理，不在此重述。
- 本次工作採用的 design document 絕對路徑。省略時，design 符合度這一審查軸會被略過，reviewer 會在各自的 review 中據實載明未審此軸，最後貼上 PR 的那則彙整內容也會照實承接。

issue 不需要在這裡指定，由 skill 依當時的定義自動處理，不在此重述推導方式。

## 影響範圍

會動到的：目標 PR 上通常只新增一則彙整過的 AI review comment，只有彙整失敗時才退回逐則張貼、每份可信的 review 各成一則；執行期間會在使用者當前 repo 暫時建立一個工作用的 git worktree 與本地分支，並對 base 分支的遠端追蹤 ref 做強制更新、強制刪除陳舊的同形狀分支——完整清單見 `pr-review-by-multi-agents` skill 定義中的「已知限制」節。腳本另會在使用者家目錄下建立一整套產出物目錄；正常（全綠）結束時由腳本與 main agent 自動清理，非全綠的執行則會把這個目錄整個保留——位置與保留規則見該 skill 定義中的「產出物位置」節。

不會動到的：不修改 PR 本身的程式碼或倉庫中的任何既有檔案，不 approve、不 merge、不 close PR 或 issue；本次派出的每個 reviewer CLI 對被審查的程式碼一律唯讀。
