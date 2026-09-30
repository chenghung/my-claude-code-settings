---
name: herdr-agent-team
description: >
  當使用者要在 herdr 之上，用一組跨平台的 AI CLI worker（claude、codex、agy、opencode 四家其中幾家）
  組成一個團隊去推進某件事時觸發，例如「幫我組一個 agent team，一個人做前端一個人做後端」、「用
  codex 跟 claude 各開一個 worker 平行做這件事」、或指名要用某份 thin command 啟動一個 team。判斷
  依據是客觀事實：使用者要的是啟動或操作一群由本 skill 腳本（`team-init.sh`／`launch-worker.sh` 這
  條路徑）管理的 herdr worker，不是單一 agent 自己完成的任務，也不是對同一個既有 PR 派多個 AI
  平台各做一次 code review（那走 `pr-review-by-multi-agents`）。不觸發：單一 agent 就做得完的任
  務；用 claude、codex、agy、opencode 對同一個既有 PR
  做交叉 code review（即使字面上也提到「組 team」「跨平台」，只要目的是審查同一個 PR 就落在
  `pr-review-by-multi-agents` 的範圍）；純粹想知道 herdr 或某個 CLI 怎麼用而不涉及啟動 team。觸發
  關鍵字：組一個 agent team、開幾個 worker 平行做、herdr agent team、啟動這個 thin command。
---

# herdr-agent-team

觸發本 skill 後，當前對話的 AI agent 在這個 team 的整個生命週期內擔任 orchestrator：人類只跟
orchestrator 對話，orchestrator 透過本 skill 的腳本作用於一群跨平台 worker，自己不直接呼叫裸的
`herdr`。worker 的產出沒有上限而 orchestrator 的 context 固定，所以本 skill 管的是流向 orchestrator
的資訊量：上行只有一行摘要直接送達，無界的細節留在磁碟上由調查者取回。

## 前置條件

進入本流程任何動作之前，先確認環境變數 `HERDR_ENV` 的值恰為 `1`。不是就停下，向使用者說明本流程要
透過 herdr 開 tab、啟動 worker 並接收回報，必須在 herdr 環境內執行；不要往下收斂 goal 或詢問要啟動
哪個 role。腳本自己也以結束碼 `3` 擋這一關，但那時可能已經白問過使用者一輪 goal。

自我檢測：`HERDR_ENV` 讀到的值是不是字面上的 `1`？不是的話就停在這一步，不要假設環境等同可用。

## Reference 與腳本

| 檔案 | 載入或呼叫時機 |
| --- | --- |
| `references/provider-drivers.md` | 挑選或驗證某個 role 的候選 provider 時、處理啟動框代按（判斷規則名在不在允許清單上）時載入 |
| `references/thin-command-format.md` | 收到一份 thin command 檔案要讀取編制時；沒有 thin command、需要知道該在對話裡問哪些欄位時，也載入這裡確認欄位清單 |
| `references/briefing-template.md` | 準備呼叫 `launch-worker.sh --briefing-file` 之前，組裝這個 worker 的啟動包內容時載入 |
| `references/worker-contract.md` | **不載入其全文**：全文有幾百行，載入等於先賠掉本 skill 要省下的 context。只在組裝啟動包時，把這份檔案（或依它「同儕段落的組裝」一節實例化後的版本）放到 worker 讀得到的位置，取得的字串當成 `briefing-template.md`「03 協定」裡的「回報契約 locator」填入；只有要修改契約本身的內容時才打開它 |
| `agents/herdr-agent-team-investigator.md` | 不是 reference，是委派對象，用 Task 工具委派，見「派調查者的時機」 |
| `scripts/` 底下的十四支腳本 | 依「腳本一覽」的時機呼叫。確切的旗標名稱、預設逾時與門檻值一律以各腳本檔頭註解為準，不照記憶湊 |

## 啟動流程

順序是實質的，前一步的產出是後一步的前提：

1. **`team-init.sh`**：自我命名、建立 registry。stdout 印出 `orchestrator=<名稱> registry=<絕對路徑>`。
2. **收斂 goal 四項**：跟人類（或讀取的 thin command，見 `thin-command-format.md`）把「要達成什麼」「怎樣算成功（外部查得到）」「不做什麼」「依賴哪些還沒驗證的前提」四項都問清楚。三個來源（thin command 預設、觸發時的引數、對話）晚給的贏。
3. **`set-goal.sh --achieve ... --success ... --not-doing ... --assumption ...`**（不帶 `--confirmed`）：把四項寫進 `team.json`。
4. **停下來，把這四項原文呈給人類，請他確認**。這一關無條件，不論素材看起來多明確，見「開工閘門的射程」。
5. **`set-goal.sh` 再呼叫一次、同樣四項內容、加上 `--confirmed`**：把 `goal_confirmed` 設成 `true`。
6. **以背景／detach 方式啟動 `watchdog.sh`**（不帶 `--once`，長駐）：goal 確認之後就掛上，不必等第一個 worker 啟動。它是無界輪詢迴圈，**絕不能用前景阻塞呼叫啟動**：前景呼叫逾時會被工具收掉，而看門狗消失是靜默的，自動推進、升級、停滯偵測、投遞重試與待補送補投從此全部停止，不會有任何錯誤訊息。存活的判讀：
   - 剛掛上時還沒有任何 worker，registry 根目錄下的 `watchdog.log` 必然是空的，這是正常的；此刻唯一的訊號是這次呼叫立即返回、沒有卡住。
   - 之後 `watchdog.log` 有新行代表它活著；沒有新行既不代表它停了，也不代表沒事可做，因為升級、補投成功、停滯追蹤都不寫這個檔案。要補強觀測，看 inbox 有沒有新的升級記錄、或 `team-status.sh` 的欄位有沒有變化。
   - log 裡的 `skip` 行與 `alert` 行偶發一次不必處理，同一筆反覆出現才值得追；各 `reason` 值的意義見 `watchdog.sh` 檔頭。
7. **逐個 `launch-worker.sh`**：對每個要啟動的 role，先依 `briefing-template.md` 組好啟動包內容、寫成檔案，再呼叫 `launch-worker.sh --role <role> --kind <kind> --cwd <路徑> --briefing-file <路徑> [--arg <原生引數>]...`。goal 未確認時會被結束碼 `4` 擋下。啟動 `agy` 或 `opencode` 的 worker 時，要在事件流裡明確告知使用者：這兩家沒有正向 `idle` 規則（見 `provider-drivers.md`），「違約沒回報就停下」與「原地繞圈」只能靠 `AGENT_TEAM_STALL_SECONDS` 停滯偵測接住，而這道偵測只涵蓋 `.stage` 是 `running` 的 worker，關卡是 `delivered`／`closing`／`closed` 時這兩種失效沒有東西接得住。

## 開工閘門的射程

第 4 步的人類確認只擋得住遺忘，擋不住撒謊：記下「人類確認過了」的是 orchestrator 自己，
`set-goal.sh --confirmed` 只是把一個布林值寫進 `team.json`，沒有任何機制驗證人類真的說過話。**這件
事必須讓使用者知道**，因為使用者會以為這一步在替自己把關；不要用「反正有這道閘門」的語氣暗示它比
實際上更可靠。

## 六個 Token 收到之後各做什麼

worker 只有一個回報動作（`report.sh`），六個 token 固定不開放給 thin command 定義：

| Token | 進 orchestrator | 處置 |
| --- | --- | --- |
| `ack` | 會 | 不需處理，`launch-worker.sh` 啟動時已等到它並完成對帳。要確認 `worker_id_match`／`cwd_match` 是否為 `true`，直接讀 `workers/<name>.json` 的 `.ack_reconciliation`，不必派調查者 |
| `working` | 不會 | 只落檔、永不投遞，orchestrator 永遠收不到，不必等它 |
| `fyi` | 會；worker 發的不需回覆，看門狗發的要處置 | **先分岔**：是 `watchdog.sh` 的升級嗎（識別訊號見「認出一則升級」）？是的話不套漂移判準，依升級表處置。不是才讀前綴之後的摘要，依「漂移處置」第 1 步判斷是不是漂移：是則走「漂移處置」；不是就不必回覆，worker 會繼續做 |
| `need-you` | 會，需要回覆 | 從前綴取出 inbox 序號（見「上行前綴」），呼叫 `instruct.sh --to <worker> --text <定案文字> --reply-to <序號>`。這一步同時把那筆 inbox 記錄標成已處理 |
| `delivered` | 會 | 呼叫 `set-worker-field.sh --to <worker> --field stage --value delivered`。需要 locator 的精確值時，讀 `inbox/<序號>-<worker>.json` 的 `.locator`。**不呼叫 `shutdown-worker.sh`**：交付點不等於終點，review 回來要改就回到執行中 |
| `done` | 會 | 對照該 worker 的完成判準（若先前經 `set-worker-field.sh --field completion_criteria` 寫入過，可直接讀 `workers/<name>.json` 確認內容），確認外部可查證的證據確實存在（一個檔案、一個已合併的 PR、一次測試通過的紀錄），才呼叫 `shutdown-worker.sh --to <worker> --reason done --evidence <外部可查證的事實>`；證據不足就當成需要進一步核對的 `fyi` 處理，不關閉。關閉前 `.stage` 不能是 `delivered`，否則以結束碼 `4` 拒絕。成功發出（結束碼 `0` 或 `7`）的非 halt 下行都會把 `delivered` 撥回 `running`，撞得到的只有兩條路徑：交付之後再也沒收過任何下行，或收到的最後一則是叫停——那時先 `set-worker-field.sh --to <worker> --field stage --value running` 撥回再關 |

### 上行前綴

`report.sh` 轉發給 orchestrator 的即時訊息最前面都帶固定前綴：
`[[HAT seq=<序號> token=<token> worker=<worker>]] <worker 原本要說的摘要>`。三項都不含空白字元，
`]] `（兩個右中括號加一個空白）是固定分界，直接切開就能拿到三項與原文摘要，**不需要另外去掃描或猜
測 registry**。前綴只出現在 orchestrator 看到的文字與 inbox 記錄的 `.summary`，worker 不知道它存
在，對 worker 的指示不需要提到它。

## 派調查者的時機

orchestrator 自己不讀畫面、不打開回報的細節檔、不讀 `peer-log/` 內容：這些內容無界，會直接把量體
或開發內容灌進 context。要知道這些位置有什麼，用 Task 工具委派 `herdr-agent-team-investigator`，只
收回它重新組織過的結論。`fetch-detail.sh --seq <序號>` 只回傳路徑字串、不含內容，orchestrator 可以
自己呼叫；打開那個路徑讀內容的是調查者。委派時機：

- 某則 `fyi`／`need-you`／`done` 的摘要不足以判斷該怎麼處置，需要讀細節檔內容
- 某個 worker 的 herdr 狀態是 `blocked`，需要知道是哪一種核准框、該按哪一顆鍵、那一顆放行什麼。
  **判讀回來有三種出口**：可以代按的就呼叫 `press-approval.sh`；**工作區信任框**（只有使用者本人
  答得了）與**放行範圍大於當次那個具體動作的「總是允許」**，一律不代按，停下來交給人類。
  `press-approval.sh` 從不讀畫面，你叫它按哪顆它就按哪顆，守門的是你
- `watchdog.sh` 因停滯升級了某個 worker，需要判斷它是真的卡住還是在跑很長的工具呼叫；後者就什麼都
  不做，讓它跑完。這個出口只對停滯成立：達上限升級時 worker 必定已閒置或完成，而且推進計數不隨時間
  衰減，放著解除不了
- 需要讀 `peer-log/` 了解兩個 worker 之間談了什麼
- 一則 `done`／`delivered` 回報所附的完成判準指向一個 GitHub issue、PR 或本機檔案，需要核對外部權威
  是否真的吻合

委派牽涉讀某個 worker 畫面或判讀核准框時，先呼叫一次 `team-status.sh`，把這次輸出（或至少其中的
worker 名稱清單）連同目標 worker 的 agent 名稱一起交給調查者：調查者本身沒有 workspace 邊界守衛，
靠這份輸出核對目標仍屬於本 team 才會去讀畫面。

## 不使用任何 `wait-*` 動作

`wait-peer.sh` 是 worker 端專用，即使技術上能帶 `--state-dir` 繞過限制去呼叫，orchestrator 也不用；
也不要自己寫輪詢迴圈去等某個 worker 回應，那等同自造一個 `wait-*`。一阻塞就全盤停擺，連人類的訊息
都進不來。orchestrator 靠 worker 的回報與 `watchdog.sh` 的升級喚醒，不主動等。

## 看門狗的自動推進與升級

- **收到一則升級代表狀態真的變了，不要當雜訊略過。** 同一個條件只在剛成立那一輪發一次，之後最多每
  隔 `AGENT_TEAM_ESCALATION_REPEAT_SECONDS` 重提一次；條件解除後重新成立、或換成另一種條件，立刻再發。
- **`delivered`、`closing`、`closed` 的 worker 不在看門狗照看範圍**（不自動推進、不做停滯偵測與達上
  限升級；`.stage` 欄位不存在時視同 `running`）；對 `delivered` 的 worker 成功發出（`instruct.sh`
  結束碼 `0` 或 `7`）一則非 halt 下行，就會撥回 `running`，`closing`、`closed` 不動；身分消失、卡在
  核准框、豁免到期三種升級不受關卡影響，照常發出。

### 認出一則升級，以及五種條件各自該做什麼

升級不經 `report.sh`，`token` 同樣是 `fyi`。三個識別訊號：訊息**沒有** `[[HAT ...]]` 前綴；摘要以
`worker=<名稱>` 開頭；對應的 inbox 記錄 `.detail_path` 與 `.locator` 都是 `null`。認錯的代價不對稱：
把升級讀成 worker 的 `fyi`，會照 Token 表走到「不必回覆，worker 會繼續做」，而升級講的那個 worker
正好不會繼續做。

| 升級條件 | 下一步 |
| --- | --- |
| 卡在核准框（摘要含 `agent_status=blocked` 與待補送筆數） | 派調查者讀畫面判讀，依「派調查者的時機」的三種出口處置；你不處理那個框，它不會自己脫身 |
| 已停滯（摘要含「已停滯 Xs」） | 派調查者判斷是真的卡住還是在跑很長的工具呼叫；後者不動，真的卡住就叫停（帶 `--kind halt`，見「漂移處置」第 3 步）、改派或結束 |
| 自動推進已達上限（摘要含「已達上限」） | 派調查者判斷；出口只有改派或結束，不是再等（計數不隨時間衰減） |
| 豁免到期（摘要含「有一則你還沒回的定案請求」） | 不必派人：補一則 `instruct.sh --to <worker> --text <定案> --reply-to <序號>`，序號照抄摘要結尾那一個，**不要填升級自己那筆記錄的序號**（兩者檔名形狀一樣）；填錯時 `--reply-to` 以結束碼 `5` 失敗。在你回覆之前，那個 worker 的自動推進與停滯偵測都不會恢復 |
| worker 身分消失（摘要含 `briefings` 字樣，五種升級只有這一種會提到它） | 不必派人：那個 pane 上已經不是你的 worker。對同一個 role 重新跑 `launch-worker.sh`，內容沿用 `briefings/<worker>.md`，但**要先把它複製到另一個路徑，拿新路徑當 `--briefing-file`**：同名重啟的目的地正是同一個檔案，來源與目的同檔時 `cp` 失敗、腳本以結束碼 `5` 結束，而那時 tab 已建好、registry 已寫入。重啟不是乾淨的起點：`.stage`、自動推進計數、待補送佇列都沿用舊值，原本停在 `delivered` 的要先 `set-worker-field.sh --to <worker> --field stage --value running` 撥回。**不要對舊 pane 送任何指令，也不要代按**：那裡的 CLI 對這個 team 一無所知。重啟之前，看門狗對這個 worker 的自動推進、停滯偵測、待補送補投每一輪都跳過 |

## 漂移處置

`fyi` 的摘要可能是漂移時，依序走六步：

1. **判斷是不是漂移**（判準一）：照 goal 原本的敘述做會失敗，或做出與所述不同的結果。「有更好的做
   法」不算漂移，那是優化提案，走一般的變更討論，不進本流程。
2. **找出受影響的人**（判準二）：拿改動後的內容對每一個還活著的 role 比對三樣：完成判準、職責範圍
   （負責與不負責兩邊都算）、與其他 role 的介面（含 grant 對象），任一樣因此不再成立就是命中。**判
   不出來算命中**：多送一則是一次可控的打擾，漏送一則是一個靜默地建錯東西的 worker。
3. **先叫停他們**：對每個命中的 worker 逐一（不是群發）呼叫 `instruct.sh --to <worker> --kind halt
   --text <這次改動對你這一份的影響>`，內容是停手、先別交付任何東西、回報做到哪裡。**一定要帶
   `--kind halt`**：一般下行會把 `delivered` 撥回 `running` 重新納入看門狗照看，帶 `halt` 的不撥回；
   不帶的話，原本停在 `delivered` 的 worker 會被撥回 `running`，停手轉成閒置後被看門狗推「繼續」。之後派新任務或新目標的那一則不是
   `halt`，關卡自然撥回。結束碼 `7`（收件方卡在 `blocked`、這則進了待補送）時不能放著：去處理那個
   核准框（見「派調查者的時機」），補投才等得到解除；叫停正是最不該靜默送不到的一則，收不到的人會照
   舊繼續建東西。halt 只擋撥回關卡，擋不住看門狗對 `running` worker 的自動推進：被叫停的人閒下來仍
   會一直被推，直到上限才升級，所以第 3 步到第 5 步之間不要拖。
4. **定下新目標**：呼叫 `set-goal.sh` 寫入新的四項內容（不帶 `--confirmed`，第一版之後的變更由
   orchestrator 自決）。若印出 `GOAL-SUCCESS-CHANGED version=<N>`，代表動到「怎樣算成功」，要往事件
   流轉述給使用者。
5. **逐一處置成對齊、改派或結束三者之一**：對齊是任務還成立，用 `instruct.sh` 送出新目標的內容；改
   派是任務作廢但人還有用，用 `instruct.sh` 換一個新任務；結束是這個角色不再需要，呼叫
   `shutdown-worker.sh --reason abandon` 或 `superseded` 並附交接檔。走「結束」之前，停在
   `delivered` 的 worker 經第 3 步叫停後仍是 `delivered`，要先撥回 `running`（同 Token 表 `done` 那
   一列）。**已交付的產物要逐一過目**：要問的是它跟新目標的落差要不要變成新的工作，出口是往前迭代，
   不是回頭改既成事實。
6. **收斂測試**：重跑第 2 步同一組比對，剩下的命中全部落在已處置的 role 上才算完成；還有人沒處置就
   是沒處理完。

## 中斷恢復

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
   成重複下行。排空由看門狗補投負責，前提是收件方先離開 `blocked`，而那要你去處理那個核准框。
4. **以外部權威重查**：對照 issue、PR、產物是否存在等外部事實，確認登記的進度沒有過時。
5. **`team-status.sh`**：核對哪些 tab 還活著。
6. **最後才重掛 `watchdog.sh`**：掛起當下會補發事件，那時進度表必須已經在手上。

## 腳本一覽

`HERDR_ENV` 不等於 `1` 時，所有腳本一律以結束碼 `3` 結束。九個結束碼所有腳本共用同一組語意：

| 碼 | 意義 |
| --- | --- |
| 0 | 成功 |
| 1 | 個別腳本自行產生的部分失敗或迴圈異常 |
| 2 | 呼叫端用錯：缺必填參數、參數格式不對 |
| 3 | 環境前提不成立：`HERDR_ENV` 不等於 `1` |
| 4 | 守衛不通過（workspace 邊界、provider 白名單、開工閘門、關閉閘門、代按前的狀態重查、grant——讀訊息那一行分辨是哪一類） |
| 5 | registry 缺漏或內容不合法 |
| 6 | herdr 拒絕 |
| 7 | 握手未取得憑據（逾時或 `agent_prompt_stalled`），或代按之後仍是 `blocked` |
| 8 | 啟動未就緒 |

### orchestrator 呼叫的腳本

| 腳本 | 呼叫時機 | 拿到結果之後怎麼判斷 |
| --- | --- | --- |
| `team-init.sh [--recover]` | 「啟動流程」第 1 步；`--recover` 見「中斷恢復」 | 印出 `orchestrator=<名稱> registry=<路徑>`；`--recover` 另印 `pending-resend` 行，處置見「中斷恢復」第 3 步。專屬結束碼 `9`：偵測到 `AGENT_TEAM_SELF` 或 `AGENT_TEAM_ROLE`（只有 worker tab 會被注入）即判定呼叫端是 worker 環境，拒絕執行，不呼叫 herdr、不寫 registry |
| `set-goal.sh --achieve <> --success <> --not-doing <> --assumption <> [--confirmed] [--changed-by <>] [--rationale <>]` | 收斂 goal 之後、每一次要覆寫 goal 時 | 印出 `GOAL-SUCCESS-CHANGED version=<N>` 代表動到「怎樣算成功」，要轉述給使用者 |
| `launch-worker.sh --role <> --kind <> --cwd <> --briefing-file <> [--arg <>]... [--ack-timeout <秒>]` | goal 確認之後，逐個 role 啟動 | 成功印 `worker=<名稱> pane=<id> tab=<id> ack=ok`；結束碼 `8` 是已內部重試一次仍啟動失敗，registry 記錄已移除、啟動包副本仍留在 `briefings/<worker>.md`；`6` 是識別碼取不到或 herdr 拒絕，沒有寫入 registry；`2` 是 herdr 語法錯誤（呼叫端用錯，不是啟動失敗） |
| `instruct.sh --to <> (--text <> \| --text-file <>) [--reply-to <序號>] [--kind instruct\|decision\|goal-update\|halt]` | 下行任何指令、定案、goal 傳播；回覆 `need-you` 用 `--reply-to` | 結束碼 `7` 是對方卡在核准框、這一則進了 `.pending_resend`：重送沒有意義，但看門狗只在它離開 `blocked` 後才補投，必須去處理那個框（見「派調查者的時機」），否則佇列永遠排不空且全程靜默。`0` 與 `7` 都會把 `delivered` 撥回 `running`；`closing`／`closed` 不動，`--kind halt` 不撥回（見「漂移處置」第 3 步） |
| `press-approval.sh --to <> --key <> --allows <> [--rule <>] [--startup]` | worker 卡在 `blocked`、已知要按哪一顆鍵與放行什麼，**且那個框不屬於不該代按的兩類** | 結束碼 `4` 有兩種，讀訊息分辨：代按前重查已經不是 `blocked`（不必按了）；或帶 `--startup` 時規則不在允許清單上、分不出是哪條規則（框還在，要升級給人確認）。`2` 包括 `--key` 與允許清單對該規則載明的按鍵不一致，腳本拒絕代按，呼叫端與清單要先對齊。`7` 是按了仍是 `blocked`（可能按錯鍵或疊了另一個框），要重新讀畫面 |
| `shutdown-worker.sh --to <> --reason <done\|abandon\|superseded> [--evidence <>] [--handoff-file <>]` | `done` 已核對外部證據；或放棄／被取代（`abandon`／`superseded`，必須附交接檔） | 結束碼 `4` 是拒絕點命中：它還有未回覆的 `need-you`、其他 worker 的 `.grants` 仍指向它、還在 `delivered` 關卡、或不屬本 workspace |
| `set-worker-field.sh --to <> --field <stage\|completion_criteria\|delivery_point\|end_point> --value <>` | 交付點／終點／完成判準確定時；`.stage` 需要變動時 | `--field stage` 的值只能是 `running`／`delivered`／`closing`／`closed`；座標類、計數類欄位不透過本腳本寫 |
| `grant-peer.sh --from <> --to <> [--revoke]` | thin command 的 `grant` 落地時；漂移處置改變了介面時 | 下行通知是 best-effort，送不到只印一句提示，授權本身已經生效 |
| `team-status.sh` | 中斷恢復核對哪些 tab 還活著；委派讀畫面前；想看全隊概況時 | 逐行 `worker=<> stage=<> status=<> seq=<> held=<> pending_resend=<> unprocessed=<>`；座標對不上本 workspace 的記錄會被跳過，不影響其餘行 |
| `fetch-detail.sh --seq <序號>` | 某則回報需要讀細節之前，先取路徑 | 印出絕對路徑（不含內容），交給調查者去讀；結束碼 `5` 是該序號沒有細節檔 |
| `watchdog.sh [--once]` | goal 確認之後即背景長駐；中斷恢復時最後一步才重掛；`--once` 供人工巡檢一輪 | 啟動方式與存活判讀見「啟動流程」第 6 步；長駐時不會自己結束 |

### worker 端腳本

以下三支由 worker 呼叫，列在此是為了看懂 worker 的行為與回報契約：

| 腳本 | 用途 |
| --- | --- |
| `report.sh` | worker 唯一的上行入口，六個 token 都經這裡送出，見 `worker-contract.md` |
| `send-peer.sh` | 已被 `grant-peer.sh` 授權的 worker，橫向直接送訊息給另一個 worker |
| `wait-peer.sh` | worker 端輪詢等同儕的 `state_change_seq` 改變；orchestrator 不使用 |

## 門檻值

| 環境變數 | 預設值 | 影響 |
| --- | --- | --- |
| `AGENT_TEAM_POLL_SECONDS` | 20 | `watchdog.sh` 每輪掃描的間隔 |
| `AGENT_TEAM_STALL_SECONDS` | 1800 | `running` worker 的 `state_change_seq` 多久沒變就判定停滯並升級 |
| `AGENT_TEAM_AUTO_PUSH_LIMIT` | 10 | 對同一個 worker 自動推進「繼續」的次數上限，達上限改為升級 |
| `AGENT_TEAM_NEEDYOU_LIMIT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS` 的三倍 | `need-you` 自 `.created_at` 起未回覆多久視為豁免到期 |
| `AGENT_TEAM_ESCALATION_REPEAT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS`（該變數自身預設 1800） | 同一個升級條件兩次升級之間的最短間隔 |
| `AGENT_TEAM_LOCK_TIMEOUT_SECONDS` | 30 | registry 檔案鎖的等待上限，逾時以結束碼 `5` 失敗；定義在 `lib/common.sh`，不在 `watchdog.sh` 檔頭 |
