# 中斷恢復

本檔由 orchestrator 在自己的 session 重啟、要接回一個既有 team，或名稱遺失（使用者告知 tab label 出現 `🚨 ORCHESTRATOR NAME LOST:` 前綴，或 registry 根目錄的 `watchdog.log` 出現 `alert reason=orchestrator_name_missing`）時載入。

先分岔：只有名稱遺失（上述兩個訊號任一）、session 並沒有重啟時，只跑一次 `team-init.sh --recover`（即下面第 1、3 步），並依第 3 步處置 `pending-resend` 行，**不重掛 `watchdog.sh`**：腳本沒有防多實例的機制，重掛會多出第二支。此時 `team-init.sh --recover` 會清空升級閂鎖，仍在執行的 watchdog 會在下一輪重發所有仍成立的升級；收到後先對照目前的處置進度，不要重複派調查者。session 重啟時才依序走完六步。

orchestrator session 重啟之後依序走六步。第 1 步與第 3 步由同一次 `team-init.sh --recover` 呼叫完成：

1. **重新自我命名**：herdr 眼中人類直接啟動的 session 沒有名字，且名稱會在被取代時清空，所以每次恢
   復都要重做。多數 orchestrator 端腳本（不含 `watchdog.sh`、`fetch-detail.sh`）雖然會盡力把名稱續租
   回來，**`--recover` 仍然一定要跑**：只有
   它會還原警示 tab label、收回持有旗標、清空升級閂鎖，並以目前這個 pane 重寫
   `.orchestrator_pane`。名稱遺失時看門狗與 `report.sh` 會把你的 tab label 換成
   `🚨 ORCHESTRATOR NAME LOST: ` 前綴，但這道警報是盡力而為（registry 缺欄位或 tab 操作失敗時不會
   出現），不能當成唯一的偵測手段。名稱遺失期間投遞失敗的上行，名稱恢復後由看門狗重投。
2. **讀 registry 重建進度**：讀 `team.json` 與各 `workers/<name>.json`，重建目前有哪些 worker、各自
   的關卡（`.stage`）。
3. **收回持有旗標與升級閂鎖**（同一次 `--recover` 呼叫）：把殘留在 `true` 的 `.held` 收回成
   `false`、清空升級閂鎖，並逐行印出 `pending-resend worker=<名稱> count=<筆數>`。**這幾行只告知積
   壓量，不要自己呼叫 `instruct.sh` 補送**：那支腳本對 `.pending_resend` 只追加不移除，手動補送會造
   成重複下行；`team-status.sh` 的 `pending_resend=` 欄位顯示積壓時同理。排空由看門狗補投負責，前提是收件方先離開 `blocked`，而那要你去處理那個核准框（見 `SKILL.md`「派調查者的時機」）。
4. **以外部權威重查**：對照 issue、PR、產物是否存在等外部事實，確認登記的進度沒有過時。
5. **`team-status.sh`**：核對哪些 tab 還活著。
6. **最後才重掛 `watchdog.sh`**：掛起當下會補發事件，那時進度表必須已經在手上。背景啟動的舊 watchdog 可能撐過 session 重啟，而腳本沒有防多實例的機制，兩支同時跑會重複推進、重複升級，補投也可能重送同一則下行；所以重掛前先確認本 team 沒有仍在執行的 `watchdog.sh`，確認不了時不重掛，回報使用者由他決定。重掛一樣要以背景／detach 方式、不帶 `--once`，理由見 `team-launch.md` 第 6 步。
