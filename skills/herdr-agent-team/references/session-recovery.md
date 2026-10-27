# 中斷恢復

本檔由 orchestrator 在自己的 session 重啟、要接回一個既有 team，或名稱遺失（使用者告知 tab label 出現 `🚨 ORCHESTRATOR NAME LOST:` 前綴，或 registry 根目錄的 `watchdog.log` 出現 `alert reason=orchestrator_name_missing`）時載入。

先分岔：只有名稱遺失（上述兩個訊號任一）、session 並沒有重啟時，你的 context 裡還有進度表，只走第 1、3、6 步：停看門狗並跑一次 `team-init.sh --recover`、依第 3 步處置 `pending-resend` 行、最後啟動看門狗。`--recover` 會清空升級閂鎖，看門狗重新啟動後第一輪會重發所有仍成立的升級；收到後先對照目前的處置進度，不要重複派調查者。session 重啟時依序走完六步。

orchestrator session 重啟之後依序走六步。第 1 步與第 3 步由同一次 `team-init.sh --recover` 呼叫完成：

1. **先停看門狗，再重新自我命名**：先呼叫 `shutdown-watchdog.sh`，印 `watchdog=stopped` 或 `watchdog=not-running` 都算完成，以 `1` 結束（10 秒內仍存活）或 `5` 結束（沒有 `AGENT_TEAM_HOME` 也沒有 workspace 指標檔，或 `AGENT_TEAM_HOME` 是相對路徑；恢復情境下指標檔理應存在，出現 5 代表環境異常）時停下、把訊息交給人類；`--recover` 會改寫看門狗也在寫的欄位，看門狗存活時 `team-init.sh --recover` 以結束碼 `4` 拒絕執行。接著呼叫 `team-init.sh --recover`。herdr 眼中人類直接啟動的 session 沒有名字，且名稱會在被取代時清空，所以每次恢
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
6. **最後才啟動 `watchdog.sh`**：掛起當下會補發事件，那時進度表必須已經在手上。帶上次啟動時的同一組門檻環境變數（沒帶會回到預設值）；session 重啟後不知道上次的值時，先問人類。啟動方式與結束碼判讀見 `team-launch.md` 第 6 步。
