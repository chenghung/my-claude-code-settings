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

確認通過之後：啟動 team 或新增 worker 讀 `references/team-launch.md`；session 重啟要接回既有 team，或名稱遺失（訊號見下表）讀 `references/session-recovery.md`。

## Reference 與腳本

| 檔案 | 載入或呼叫時機 |
| --- | --- |
| `references/provider-drivers.md` | 挑選或驗證某個 role 的候選 provider 時、處理啟動框代按（判斷規則名在不在允許清單上）時載入 |
| `references/thin-command-format.md` | 收到一份 thin command 檔案要讀取編制時；沒有 thin command、需要知道該在對話裡問哪些欄位時，也載入這裡確認欄位清單 |
| `references/briefing-template.md` | 準備呼叫 `launch-worker.sh --briefing-file` 之前，組裝這個 worker 的啟動包內容時載入 |
| `references/worker-contract.md` | **不載入其全文**：全文有幾百行，載入等於先賠掉本 skill 要省下的 context。只在組裝啟動包時，把這份檔案（或依它「同儕段落的組裝」一節實例化後的版本）放到 worker 讀得到的位置，取得的字串當成 `briefing-template.md`「03 協定」裡的「回報契約 locator」填入；只有要修改契約本身的內容時才打開它 |
| `agents/herdr-agent-team-investigator.md` | 不是 reference，是委派對象，用 Task 工具委派，見「派調查者的時機」 |
| `references/team-launch.md` | 啟動 team、新增 worker、重掛或判讀 watchdog 是否存活 |
| `references/watchdog-escalations.md` | 依三個識別訊號認出一則升級時 |
| `references/drift-handling.md` | `fyi` 可能是漂移、使用者要求變更 goal，或要叫停、改派、結束 worker（`done` 除外）時 |
| `references/session-recovery.md` | session 重啟要接回既有 team，或名稱遺失：使用者告知 tab label 出現 `🚨 ORCHESTRATOR NAME LOST:` 前綴，或 `watchdog.log` 出現 `alert reason=orchestrator_name_missing` 時 |
| `references/script-reference.md` | 任何腳本非 0 結束，或輸出出現核心未說明的格式，或要覆寫門檻時 |
| `scripts/` 底下的十四支腳本 | 依本檔與上列 reference 流程中寫明的時機呼叫，總表見 `references/script-reference.md`。確切的旗標名稱、預設逾時與門檻值一律以各腳本檔頭註解為準，不照記憶湊 |

本檔是 compact 後會重附的核心，上列 reference 只在觸發時讀；compact 後先前讀過的不保證還在，碰到觸發情境或流程中途遇上 compact，一律重讀所屬 reference（`references/worker-contract.md` 依上表該列不載入，不在重讀之列）。

腳本以結束碼 `0` 結束、輸出仍要處置的情況：`set-goal.sh` 印出 `GOAL-SUCCESS-CHANGED version=<N>` 代表動到「怎樣算成功」，要轉述給使用者；`team-init.sh --recover` 的 `pending-resend` 行或 `team-status.sh` 的 `pending_resend=` 欄位顯示積壓時，都不要自己用 `instruct.sh` 補送（理由見 `references/session-recovery.md` 第 3 步）。

## 開工閘門的射程

啟動流程第 4 步（`references/team-launch.md`）無條件停下、把四項原文交人類確認，這道確認只擋得住遺忘，擋不住撒謊：記下「人類確認過了」的是 orchestrator 自己，
`set-goal.sh --confirmed` 只是把一個布林值寫進 `team.json`，沒有任何機制驗證人類真的說過話。**這件
事必須讓使用者知道**，因為使用者會以為這一步在替自己把關；不要用「反正有這道閘門」的語氣暗示它比
實際上更可靠。

## 六個 Token 收到之後各做什麼

worker 只有一個回報動作（`report.sh`），六個 token 固定不開放給 thin command 定義：

| Token | 進 orchestrator | 處置 |
| --- | --- | --- |
| `ack` | 會 | 不需處理，`launch-worker.sh` 啟動時已等到它並完成對帳。要確認 `worker_id_match`／`cwd_match` 是否為 `true`，直接讀 `workers/<name>.json` 的 `.ack_reconciliation`，不必派調查者 |
| `working` | 不會 | 只落檔、永不投遞，orchestrator 永遠收不到，不必等它 |
| `fyi` | 會；worker 發的不需回覆，看門狗發的要處置 | **先分岔**：是 `watchdog.sh` 的升級嗎（識別訊號見「認出一則升級」）？是的話不套漂移判準，讀 `references/watchdog-escalations.md` 依升級表處置。不是才讀前綴之後的摘要，判斷是不是漂移（判準一）：照 goal 原本的敘述做會失敗，或做出與所述不同的結果；「有更好的做法」不算。是則讀 `references/drift-handling.md` 走漂移處置；不是就不必回覆，worker 會繼續做 |
| `need-you` | 會，需要回覆 | 從前綴取出 inbox 序號（見「上行前綴」），呼叫 `instruct.sh --to <worker> --text <定案文字> --reply-to <序號>`。這一步同時把那筆 inbox 記錄標成已處理 |
| `delivered` | 會 | 呼叫 `set-worker-field.sh --to <worker> --field stage --value delivered`。需要 locator 的精確值時，讀 `inbox/<序號>-<worker>.json` 的 `.locator`。**不呼叫 `shutdown-worker.sh`**：交付點不等於終點，review 回來要改就回到執行中 |
| `done` | 會 | 對照該 worker 的完成判準（若先前經 `set-worker-field.sh --field completion_criteria` 寫入過，可直接讀 `workers/<name>.json` 確認內容），確認外部可查證的證據確實存在（通常是對應的 ticket 已關閉；產物本身存在只代表到了交付點，不算），才呼叫 `shutdown-worker.sh --to <worker> --reason done --evidence <外部可查證的事實>`；證據不足就當成需要進一步核對的 `fyi` 處理，不關閉。關閉前 `.stage` 不能是 `delivered`，否則以結束碼 `4` 拒絕。成功發出（結束碼 `0` 或 `7`）的非 halt 下行都會把 `delivered` 撥回 `running`，撞得到的只有兩條路徑：交付之後再也沒收過任何下行，或收到的最後一則是叫停——那時先 `set-worker-field.sh --to <worker> --field stage --value running` 撥回再關 |

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
  `press-approval.sh` 從不讀畫面，你叫它按哪顆它就按哪顆，守門的是你。`instruct.sh` 以結束碼 `7`
  結束（收件方卡在核准框、這一則進了待補送）時，一定要照這三種出口去處理那個框，否則補投永遠等不到
  （見 `references/script-reference.md`）
- `watchdog.sh` 因停滯升級了某個 worker，需要判斷它是真的卡住還是在跑很長的工具呼叫；後者就什麼都
  不做，讓它跑完。這個出口只對停滯成立：達上限升級時 worker 必定已閒置或完成，而且推進計數不隨時間
  衰減，放著解除不了。任何叫停（含真的卡住時）都帶 `--kind halt`（理由見 `references/drift-handling.md`
  第 3 步），改派或結束的做法見同檔第 5 步
- 需要讀 `peer-log/` 了解兩個 worker 之間談了什麼
- 需要核對外部權威是否真的吻合：一則 `done` 回報要核對完成判準的證據（例如 ticket 是否已關閉）；
  一則 `delivered` 回報要核對交付的產物是否確實存在（例如一個 PR 或本機檔案）。交付點原文讀
  `workers/<name>.json` 的 `.delivery_point`，委派時一併提供

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
- **啟動或重掛長駐的 `watchdog.sh` 一律背景／detach、不帶 `--once`**（`--once` 單輪巡檢不在此限；
  理由見 `references/team-launch.md` 第 6 步）。

### 認出一則升級

升級不經 `report.sh`，`token` 同樣是 `fyi`。三個識別訊號：訊息**沒有** `[[HAT ...]]` 前綴；摘要以
`worker=<名稱>` 開頭；對應的 inbox 記錄 `.detail_path` 與 `.locator` 都是 `null`。認錯的代價不對稱：
把升級讀成 worker 的 `fyi`，會照 Token 表走到「不必回覆，worker 會繼續做」，而升級講的那個 worker
正好不會繼續做。認出之後讀 `references/watchdog-escalations.md`，依摘要特徵對到五種升級條件之一處置。
其中摘要含 `briefings` 的（worker 身分消失），一律不對那個 pane 送指令或代按。
