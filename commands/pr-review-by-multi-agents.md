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

會動到的：目標 PR 上通常只新增一則彙整過的 AI review comment，只有彙整失敗時才退回逐則張貼、每份可信的 review 各成一則；執行期間會在使用者當前 repo 暫時建立一個工作用的 git worktree 與本地分支，並對 base 分支的遠端追蹤 ref 做強制更新。另會強制刪除當前 repo 中形狀為 `pr-review-` 接數字再接數字的陳舊分支，比對不看那是哪一個 PR 留下的、也不看有沒有合併過；但這一項不是無條件發生——派出前會先把符合這個形狀的分支全部列出來、逐一取得同意才派，這道閘門與它的界線見 `pr-review-by-multi-agents` skill 定義中的「呼叫腳本」節（不在「已知限制」節，那一節是遇到症狀時事後對照用的）。其餘寫入項目的完整清單見該 skill 定義中的「已知限制」節。

畫面上同樣會動到：會開一個新的 herdr tab，每個派出的 reviewer 各佔其中一格 pane，跑的是互動式 agent，可以切過去看進度或直接對話。期間可能需要使用者親自到某一格核准動作才會繼續（agy 那一格連寫出自己那份 review 檔都要核准），而未全部產出完整輸出檔時整個 tab 會留著不關——關閉條件見該 skill 定義中「回報」節的「收尾清理」。腳本另會在使用者家目錄下建立一整套產出物目錄；正常（全綠）結束時由腳本與 main agent 自動清理，非全綠的執行則會把這個目錄整個保留——位置與保留規則見該 skill 定義中的「產出物位置」節。

不會動到的：不 approve、不 merge、不 close PR 或 issue；不修改 PR 本身的程式碼，也不修改倉庫中的既有檔案。後面這兩項靠的是契約與檔案權限，不是機制保證：reviewer 這次必須寫得出自己那份 review 輸出檔，寫入工具因此是開著的，擋在被審查的程式碼前面的只有作業系統層的唯讀權限位元，而 reviewer 與腳本跑在同一個使用者身分底下、改得回去。真的被改動時，腳本在每個 reviewer 啟動前後的 git 狀態比對會抓到，那份 review 就不會被張貼——但這道比對只取兩個時間點的快照（該 reviewer 啟動前、它寫完 review 後），改完而在寫完 review 之前就還原的偵測不到，反方向也存在並發造成的誤標，完整缺口見 `pr-review-by-multi-agents` skill 定義中的「已知限制」節。
