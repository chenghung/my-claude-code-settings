# 啟動流程

本檔由 orchestrator 在啟動 team、中途新增 worker（只走第 7 步），或需要重新啟動、判讀 `watchdog.sh` 是否還活著（第 6 步）時載入。

順序是實質的，前一步的產出是後一步的前提：

1. **`team-init.sh`**：自我命名、建立 registry。stdout 印出 `orchestrator=<名稱> registry=<絕對路徑>`。結束碼 `4` 且 stdout 印出 `existing-team registry=<路徑> state=<running|finished> workers=<N> watchdog=<alive|dead>` 時，本 workspace 已有一個 team（一個 herdr workspace 只承載一個 team）：停下來，把這一行原文交給人類，由人類選：
   - **接回**：改讀 `session-recovery.md`。
   - **開新、`state=running`**：到另一個 herdr workspace 開新 team，本 workspace 的 team 原樣留著。
   - **開新、`state=finished`**：呼叫 `team-init.sh --archive`，舊 registry 改名歸檔（stdout 多一行 `archived=<路徑>`）後照常初始化，接著走第 2 步。

   `finished` 是推斷：曾派過 worker（`briefings/` 有啟動包副本）、目前沒有 worker 記錄、看門狗也沒在跑。所有啟動都失敗、或關掉一批準備改派時中斷，也會落在這個狀態；把這一點連同那一行交給人類。
2. **收斂 goal 四項**：跟人類（或讀取的 thin command，見 `thin-command-format.md`）把「要達成什麼」「怎樣算成功（外部查得到）」「不做什麼」「依賴哪些還沒驗證的前提」四項都問清楚。三個來源（thin command 預設、觸發時的引數、對話）晚給的贏。
3. **`set-goal.sh --achieve ... --success ... --not-doing ... --assumption ...`**（不帶 `--confirmed`）：把四項寫進 `team.json`。
4. **停下來，把這四項原文呈給人類，請他確認**。這一關無條件，不論素材看起來多明確，見 `SKILL.md`「開工閘門的射程」。
5. **`set-goal.sh` 再呼叫一次、同樣四項內容、加上 `--confirmed`**：把 `goal_confirmed` 設成 `true`。
6. **啟動 `watchdog.sh`**（不帶參數）：goal 確認之後就啟動，不必等第一個 worker。用一般的前景呼叫：腳本自己以 `setsid` 脫離目前的 session，長駐子行程撐得過 orchestrator 的 session 結束，呼叫本身立即返回。依結束碼判讀：
   - `0`：已掛上，stdout 印 `watchdog=started pid=<PID>`。
   - `2`：門檻環境變數不合法，stderr 說明是哪一項（約束見 `script-reference.md` 門檻值）；修正後重跑。
   - `4`：本 team 已有存活的看門狗，沿用它。
   - `1`：長駐子行程沒有就緒，原因在 registry 根目錄的 `watchdog.out`。

   之後要確認它還活著，看 `team-status.sh` 第一行的 `watchdog=alive|dead`。`watchdog.log` 的 `skip` 行與 `alert` 行偶發一次不必處理，同一筆反覆出現才值得追；各 `reason` 值的意義見 `watchdog.sh` 檔頭。例外是 `alert reason=orchestrator_name_missing`：它每次名稱遺失只寫一次，出現即依 `session-recovery.md` 處置。
7. **逐個 `launch-worker.sh`**：對每個要啟動的 role，先依 `briefing-template.md` 組好啟動包內容、寫成檔案，再呼叫 `launch-worker.sh --role <role> --kind <kind> --cwd <路徑> --briefing-file <路徑> [--arg <原生引數>]...`。goal 未確認時會被結束碼 `4` 擋下。啟動 `agy` 或 `opencode` 的 worker 時，要在事件流裡明確告知使用者：這兩家沒有正向 `idle` 規則（見 `provider-drivers.md`），「違約沒回報就停下」與「原地繞圈」只能靠 `AGENT_TEAM_STALL_SECONDS` 停滯偵測接住，而這道偵測只涵蓋 `.stage` 是 `running` 的 worker，關卡是 `delivered`／`closing`／`closed` 時這兩種失效沒有東西接得住。
