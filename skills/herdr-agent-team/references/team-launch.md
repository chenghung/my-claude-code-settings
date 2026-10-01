# 啟動流程

本檔由 orchestrator 在啟動 team、中途新增 worker（只走第 7 步），或需要重掛、判讀 `watchdog.sh` 是否還活著（第 6 步）時載入。

順序是實質的，前一步的產出是後一步的前提：

1. **`team-init.sh`**：自我命名、建立 registry。stdout 印出 `orchestrator=<名稱> registry=<絕對路徑>`。
2. **收斂 goal 四項**：跟人類（或讀取的 thin command，見 `thin-command-format.md`）把「要達成什麼」「怎樣算成功（外部查得到）」「不做什麼」「依賴哪些還沒驗證的前提」四項都問清楚。三個來源（thin command 預設、觸發時的引數、對話）晚給的贏。
3. **`set-goal.sh --achieve ... --success ... --not-doing ... --assumption ...`**（不帶 `--confirmed`）：把四項寫進 `team.json`。
4. **停下來，把這四項原文呈給人類，請他確認**。這一關無條件，不論素材看起來多明確，見 `SKILL.md`「開工閘門的射程」。
5. **`set-goal.sh` 再呼叫一次、同樣四項內容、加上 `--confirmed`**：把 `goal_confirmed` 設成 `true`。
6. **以背景／detach 方式啟動 `watchdog.sh`**（不帶 `--once`，長駐）：goal 確認之後就掛上，不必等第一個 worker 啟動。它是無界輪詢迴圈，**絕不能用前景阻塞呼叫啟動**：前景呼叫逾時會被工具收掉，而看門狗消失是靜默的，自動推進、升級、停滯偵測、投遞重試與待補送補投從此全部停止，不會有任何錯誤訊息。存活的判讀：
   - 剛掛上時還沒有任何 worker，registry 根目錄下的 `watchdog.log` 必然是空的，這是正常的；此刻唯一的訊號是這次呼叫立即返回、沒有卡住。
   - 之後 `watchdog.log` 有新行代表它活著；沒有新行既不代表它停了，也不代表沒事可做，因為升級、補投成功、停滯追蹤都不寫這個檔案。要補強觀測，看 inbox 有沒有新的升級記錄、或 `team-status.sh` 的欄位有沒有變化。
   - log 裡的 `skip` 行與 `alert` 行偶發一次不必處理，同一筆反覆出現才值得追；各 `reason` 值的意義見 `watchdog.sh` 檔頭。例外是 `alert reason=orchestrator_name_missing`：它每次名稱遺失只寫一次，出現即依 `session-recovery.md` 處置。
7. **逐個 `launch-worker.sh`**：對每個要啟動的 role，先依 `briefing-template.md` 組好啟動包內容、寫成檔案，再呼叫 `launch-worker.sh --role <role> --kind <kind> --cwd <路徑> --briefing-file <路徑> [--arg <原生引數>]...`。goal 未確認時會被結束碼 `4` 擋下。啟動 `agy` 或 `opencode` 的 worker 時，要在事件流裡明確告知使用者：這兩家沒有正向 `idle` 規則（見 `provider-drivers.md`），「違約沒回報就停下」與「原地繞圈」只能靠 `AGENT_TEAM_STALL_SECONDS` 停滯偵測接住，而這道偵測只涵蓋 `.stage` 是 `running` 的 worker，關卡是 `delivered`／`closing`／`closed` 時這兩種失效沒有東西接得住。
