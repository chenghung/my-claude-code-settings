---
name: herdr-agent-team
description: >
  當使用者要在 herdr 之上，用一組跨平台的 AI CLI worker（claude、codex、agy、opencode 四家其中幾家）
  組成一個團隊去推進某件事時觸發，例如「幫我組一個 agent team，一個人做前端一個人做後端」、「用
  codex 跟 claude 各開一個 worker 平行做這件事」、或指名要用某份 thin command 啟動一個 team。判斷
  依據是客觀事實：使用者要的是啟動或操作一群由本 skill 腳本（`team-init.sh`／`launch-worker.sh` 這
  條路徑）管理的 herdr worker，不是單一 agent 自己完成的任務，也不是已經拆成 GitHub parent issue 與
  sub-issue、要按 phase 推進的 epic（那走 `epic-orchestration`），也不是對同一個既有 PR 派多個 AI
  平台各做一次 code review（那走 `pr-review-by-multi-agents`）。不觸發：單一 agent 就做得完的任
  務；已經有 parent issue 與 sub-issue 結構的 epic；用 claude、codex、agy、opencode 對同一個既有 PR
  做交叉 code review（即使字面上也提到「組 team」「跨平台」，只要目的是審查同一個 PR 就落在
  `pr-review-by-multi-agents` 的範圍）；純粹想知道 herdr 或某個 CLI 怎麼用而不涉及啟動 team。觸發
  關鍵字：組一個 agent team、開幾個 worker 平行做、herdr agent team、啟動這個 thin command。
---

# herdr-agent-team

觸發本 skill 後，當前對話的 AI agent 在這個 team 的整個生命週期內擔任 orchestrator：人類只跟
orchestrator 對話，orchestrator 透過本 skill 的腳本作用於一群跨平台 worker，自己不直接呼叫裸的
`herdr`。worker 的產出量沒有上限，而 orchestrator 的 context 是固定的——本 skill 真正在管的是**流
向 orchestrator 的資訊量**，不是通訊本身：上行只有一行摘要會直接送達，無界的細節留在磁碟上等調查
者來取；下行不限長，但沒有任何一段回報契約全文會被載入這份 `SKILL.md`（見下方「Reference 與腳本」
`worker-contract.md` 那一列）。

## 前置條件

orchestrator 必須跑在 herdr 環境內：進入本流程任何動作之前，先確認環境變數 `HERDR_ENV` 的值恰為
`1`。不是就停下，向使用者說明本流程要透過 herdr 開 tab、啟動 worker 並接收回報，必須在 herdr 環境
內執行，不要往下收斂 goal 或詢問要啟動哪個 role。腳本自己也擋這一關（結束碼 `3`），但那時可能已經
問過使用者一輪 goal 的內容了。

自我檢測：`HERDR_ENV` 讀到的值是不是字面上的 `1`？不是的話就停在這一步，不要假設環境等同可用。

## Reference 與腳本

| 檔案 | 載入或呼叫時機 |
| --- | --- |
| `references/provider-drivers.md` | 挑選或驗證某個 role 的候選 provider 時、處理啟動框代按（判斷規則名在不在允許清單上）時載入 |
| `references/thin-command-format.md` | 收到一份 thin command 檔案要讀取編制時；沒有 thin command、需要知道該在對話裡問哪些欄位時，也載入這裡確認欄位清單 |
| `references/briefing-template.md` | 準備呼叫 `launch-worker.sh --briefing-file` 之前，組裝這個 worker 的啟動包內容時載入 |
| `references/worker-contract.md` | **本 `SKILL.md` 不載入其全文**——回報契約全文有幾百行，orchestrator 每次觸發都載入它用不到的內容，等於在載入那一刻先賠掉這個 skill 要省下的量（規格 §3）。orchestrator 只在組裝啟動包時，把這份檔案（或依它「同儕段落的組裝」一節規則實例化後的版本）放到 worker 讀得到的位置，取得的字串當成 `briefing-template.md` 「03 協定」裡的「回報契約 locator」填入；只有要修改契約本身的內容時才打開它 |
| `agents/herdr-agent-team-investigator.md` | 不是 reference，是委派對象。要看畫面、要看細節、要判讀核准框、要查橫向通訊紀錄時，用 Task 工具委派它，見「派調查者的時機」 |
| `scripts/` 底下的十四支腳本 | 依「腳本一覽」一節的時機呼叫。機制層的權威說明是各腳本自身的檔頭註解，確切的旗標名稱、預設逾時與門檻值一律以檔頭為準，不照記憶湊 |

## 啟動流程

順序是實質的，前一步的產出是後一步的前提：

1. **`team-init.sh`**：自我命名、建立 registry。stdout 印出 `orchestrator=<名稱> registry=<絕對路徑>`。
2. **收斂 goal 四項**：跟人類（或讀取的 thin command，見 `thin-command-format.md`）把「要達成什麼」「怎樣算成功（外部查得到）」「不做什麼」「依賴哪些還沒驗證的前提」四項都問清楚。三個來源（thin command 預設、觸發時的引數、對話）晚給的贏。
3. **`set-goal.sh --achieve ... --success ... --not-doing ... --assumption ...`**（不帶 `--confirmed`）：把四項寫進 `team.json`。
4. **停下來，把這四項原文呈給人類，請他確認**。這一關無條件，不論素材看起來多明確——見下方「開工閘門的射程」。
5. **`set-goal.sh` 再呼叫一次、同樣四項內容、加上 `--confirmed`**：把 `goal_confirmed` 設成 `true`。
6. **以背景／detach 方式啟動 `watchdog.sh`**（不帶 `--once`，長駐）：goal 確認之後就該掛上，不必等第一個 worker 真的啟動——它自己會在沒有任何 worker 時安靜地跑，不產生任何動作。**這支腳本是一個無界的輪詢迴圈（`while :; do ...; sleep <間隔>; done`），絕不能用一般前景阻塞呼叫啟動**——跟下方「不使用任何 `wait-*` 動作」是同一個理由：前景呼叫本身就變成一次阻塞的等待，工具逾時會把整個行程收掉，而看門狗消失是靜默的，自動推進、升級、停滯偵測、投遞重試與待補送補投這四項職責自此全部停止，不會有任何錯誤訊息——待補送佇列從此也永遠排不空，因為移除佇列裡那一筆的唯一呼叫端就是它的補投。啟動後可檢查 registry 根目錄下的 `watchdog.log` 判斷它有沒有在動，但要知道這個判準有多鬆：**整支腳本只有四個寫入點**（見 `watchdog.sh`）——`auto-push worker=<名稱> count=<次數> at=<時間>` 是真的送出了一次自動推進；另外三個都是 `skip ... reason=<原因> at=<時間>`，代表某一筆記錄這一輪被跳過。`reason` 目前有三個值：`missing_pane_id` 是那筆記錄裡沒有 pane 座標，判不出它屬不屬於本 workspace，整筆不處理；`process_failed` 是處理這一筆時發生致命失敗（這一行另外帶 `rc=<結束碼>` 欄位，下面的 `retry_blocked_failed` 同樣帶，只有 `missing_pane_id` 不帶），最常見的成因是 `shutdown-worker.sh` 正在關閉同一個 worker——它從讀取記錄起一路持有該筆記錄的檔案鎖，直到把記錄刪除為止，看門狗同一輪若也處理到這個 worker，後續的寫入會在等到鎖之後發現目標檔已經不存在而致命失敗；這種失敗現在只讓那一筆被跳過並記一行，不再把整個看門狗行程帶走；`retry_blocked_failed` 是重投某一筆先前投遞失敗的上行記錄（`inbox/` 裡 `.delivery` 還是 `blocked` 的那些）時，處理這一筆發生致命失敗，最可能的成因是等鎖逾時。前兩個值的識別欄位是 `worker=<名稱>`，第三個換成 `inbox=<序號>-<worker 名稱>.json`——檔名本身就帶著 worker 名稱，不必再印一次。三種跳過行的處置一樣：偶發一次不必處理，同一筆反覆出現才值得追。升級、補投成功、停滯追蹤的欄位更新全都不寫這個檔案，所以一個正在對每個 worker 反覆升級、正在補投下行的看門狗，可以一行都不產生：沒有新記錄既不代表它已經停止，也不代表它目前沒事可做。要確認它還在動，更可靠的補充觀測是 inbox 有沒有新的升級記錄、或 `team-status.sh` 的欄位有沒有變化。
7. **逐個 `launch-worker.sh`**：對每個要啟動的 role，先依 `briefing-template.md` 組好啟動包內容、寫成檔案，再呼叫 `launch-worker.sh --role <role> --kind <kind> --cwd <路徑> --briefing-file <路徑> [--arg <原生引數>]...`。`hat_require_goal_confirmed` 會在腳本內部再確認一次 `goal_confirmed`，第 4 步沒做完這裡會被結束碼 `4` 擋下。

## 開工閘門的射程

第 4 步的人類確認只擋得住遺忘，擋不住撒謊：記下「人類確認過了」的是 orchestrator 自己——這一端沒
有任何機制驗證得了人類真的說過話，`set-goal.sh --confirmed` 只是把一個布林值寫進 `team.json`。所
以它是一道提醒，不是保證。**這件事必須讓使用者知道**，因為使用者會以為這一步在替自己把關；不要用
「反正有這道閘門」的語氣暗示它比實際上更可靠。

## 六個 Token 收到之後各做什麼

worker 只有一個回報動作（`report.sh`），六個 token 固定不開放給 thin command 定義。orchestrator 收
到（或該收到而沒收到）之後的處置：

| Token | 進 orchestrator | 處置 |
| --- | --- | --- |
| `ack` | 會 | 這是 `launch-worker.sh` 第 8 步自己等的 token，orchestrator 不需要另外處理；它啟動時已經完成對帳並寫進該 worker `workers/<name>.json` 的 `.ack_reconciliation`。啟動成功之後若要確認 `worker_id_match`／`cwd_match` 是否為 `true`，直接讀這個檔案即可，不必派調查者——那是結構化的 registry 中繼資料，不是開發內容 |
| `working` | 不會 | `report.sh` 對這個 token 只落檔、絕不投遞（規格 §8）。orchestrator 永遠收不到這個 token 的即時通知，不必等它 |
| `fyi` | 會；worker 發的不需回覆，看門狗發的要處置 | **先分岔**：這一則是 `watchdog.sh` 的升級嗎（識別訊號見「看門狗的自動推進與升級」）？是的話不套漂移判準，依該節四種條件各自的處置走。不是（真的是 worker 發的）才讀摘要（見下方「上行前綴」，前綴之後才是 worker 原文），判斷是不是漂移（規格 §9 判準一：照 goal 原本的敘述做會失敗，或做出與所述不同的結果）。是則走下方「漂移處置」；不是（例如單純說一聲、或事後醒悟但不影響全局）就不必回覆，worker 會繼續做 |
| `need-you` | 會，需要回覆 | 從即時訊息的前綴直接取出這則的 inbox 序號（見下方「上行前綴」），呼叫 `instruct.sh --to <worker> --text <定案文字> --reply-to <序號>`。這一步同時會標記那筆 inbox 記錄為已處理 |
| `delivered` | 會 | 從即時訊息的前綴取出序號；worker 的摘要文字（前綴之後那一段）裡通常會提到交付了什麼，需要確認 locator 的精確值時，直接讀 `inbox/<序號>-<worker>.json` 的 `.locator`——`report.sh` 已把 `--locator` 存在這個欄位，序號已知之後這是唯一一筆、不必再猜。呼叫 `set-worker-field.sh --to <worker> --field stage --value delivered` 把該 worker 的關卡改成 `delivered`（腳本本身會驗證這個值必須是設計定義的生命週期關卡名稱之一）。**不呼叫 `shutdown-worker.sh`**：交付點不等於終點，review 回來要改就回到執行中 |
| `done` | 會 | 對照該 worker 的完成判準（若先前經 `set-worker-field.sh --field completion_criteria` 寫入過，可直接讀 `workers/<name>.json` 確認內容），確認外部可查證的證據確實存在（一個檔案、一個已合併的 PR、一次測試通過的紀錄），證據齊全才呼叫 `shutdown-worker.sh --to <worker> --reason done --evidence <外部可查證的事實>`。關閉前那個 worker 的 `.stage` 不能還是 `delivered`，否則 `shutdown-worker.sh` 以結束碼 `4` 拒絕——多數情況不必特別處理，因為 `instruct.sh` 發出任何一則下行時就會把 `delivered` 撥回 `running`（帶 `--kind halt` 的叫停除外，不撥回，理由見「漂移處置」第 3 步）；撞得到的是兩條路徑——交付之後再也沒收過任何下行就要直接關閉，或收到的最後一則是叫停——那時先 `set-worker-field.sh --field stage --value running` 撥回再關。證據不足就當成一則需要進一步核對的 `fyi` 處理，不直接關閉 |

### 上行前綴

`report.sh` 轉發給 orchestrator 的即時訊息（`working` 除外，那個 token 從不投遞）最前面都帶一段機
器可讀的固定前綴：`[[HAT seq=<序號> token=<token> worker=<worker>]] <worker 原本要說的摘要>`。
`seq`／`token`／`worker` 三者依規則都不含空白字元，`]] `（兩個右中括號加一個空白）是固定分界，直
接切開就能拿到這三項與原文摘要，**不需要另外去掃描或猜測 registry**。這個前綴只影響 orchestrator
看到的文字與 inbox 記錄的 `.summary` 欄位（兩者是同一份內容），不影響 worker 呼叫
`report.sh --summary` 時應該填的內容——`worker-contract.md`、`briefing-template.md` 對 worker 的
指示不受這件事影響，worker 完全不用知道這個前綴的存在。

## 派調查者的時機

orchestrator 自己不讀畫面、不打開回報的細節檔、不讀 `peer-log/` 內容——那些都是最容易「看起來永遠
很合理」但會直接把量體或開發內容灌進 context 的動作。要知道這些位置有什麼，用 Task 工具委派
`herdr-agent-team-investigator`，只收回它重新組織過的結論。委派時機：

- 某則 `fyi`／`need-you`／`done` 的摘要不足以判斷該怎麼處置，需要讀 `fetch-detail.sh` 已經解析出來
  的細節檔內容
- 某個 worker 的 herdr 狀態是 `blocked`，需要知道那是哪一種核准框、該按哪一顆鍵、那一顆放行什麼。
  **判讀回來有三種出口，不是一種**：可以代按的就呼叫 `press-approval.sh`；**工作區信任框**（它問的
  是使用者信不信任這個目錄，只有使用者本人答得了）與**放行範圍大於當次那個具體動作的「總是允許」那
  一類**，一律不代按，停下來把決定權交給人類。這兩條界線沒有任何程式碼在守——`press-approval.sh` 從
  不讀畫面，分辨不出眼前是哪一類框，你叫它按哪顆它就按哪顆，守門的是你
- `watchdog.sh` 因為**停滯**超過 `AGENT_TEAM_STALL_SECONDS` 升級了某個 worker，需要判斷它是真的卡住
  還是在跑一個很長的工具呼叫——若是後者就什麼都不必做，讓它跑完，狀態一動停滯計時就重新起算。這個出
  口只對停滯這一種成立：達上限那一種觸發的當下 worker 必定已經是閒置或完成（那個判斷排在「狀態不是
  閒置或完成就早退」之後），不可能正在跑長工具呼叫，而且推進計數不隨時間衰減，什麼都不做解除不了條
  件，只會每個重提間隔再被提醒一次。達上限與豁免到期兩種的處置一律以「看門狗的自動推進與升級」的升
  級表為準
- 需要讀 `peer-log/` 了解兩個 worker 之間談了什麼
- 一則 `done`／`delivered` 回報所附的完成判準指向一個 GitHub issue、PR 或本機檔案，需要核對外部權威
  是否真的吻合

`fetch-detail.sh --seq <序號>` 本身只回傳一個路徑字串，不含任何回報內容，orchestrator 自己呼叫這
一步是安全的；真正打開那個路徑讀內容的是調查者。

委派牽涉讀某個 worker 畫面或判讀核准框時，先呼叫一次 `team-status.sh`，把這次輸出（或至少其中列
出的 worker 名稱清單）連同目標 worker 的 agent 名稱一起交給調查者——調查者本身沒有 workspace 邊
界守衛，靠這份輸出核對目標仍屬於本 team 之後才會去讀畫面，見
`agents/herdr-agent-team-investigator.md` 的 `Out of Scope`「只能讀出現在 team-status.sh 輸出裡
的 pane」一節。

## 不使用任何 `wait-*` 動作

`wait-peer.sh` 是 worker 端專用的腳本（規格 §12：`wait-* | orch 不可`）——即使技術上可以帶
`--state-dir` 越過它原本吃 `AGENT_TEAM_STATE_DIR` 的限制去呼叫，orchestrator 也不該這樣用。理由不
只是「這支腳本不是給你用的」：一 block 就全盤停擺，連人類的訊息都進不來。這條原則也涵蓋
orchestrator 自己：不要寫一個輪詢迴圈去等某個 worker 回應——那樣做會讓整個 orchestrator session 在
等待期間吃不到任何新訊息，等同於自己造了一個 `wait-*`。orchestrator 靠 worker 的回報、以及
`watchdog.sh` 的升級喚醒，不主動等。

## 看門狗的自動推進與升級

`watchdog.sh` 只推還在跑的 worker，而且同一件事只跟你講一次——它的沉默與它的發言都有明確條件，讀
懂條件才不會把該處理的那一則當成雜訊：

- **一則升級是稀有的，不是可以略過的雜訊。** 同一個升級條件只在剛成立的那一輪送出一次，之後最多
  每隔 `AGENT_TEAM_ESCALATION_REPEAT_SECONDS` 重提一次；條件解除時閂鎖被清掉，下次重新成立能立刻
  再發；條件換成另一種（例如從卡在核准框變成自動推進達上限）不受重提間隔壓抑，也是立刻發出。這道
  去重是線上故障的修正——在它之前，只要條件還成立，每一輪輪詢就原封不動再發一次同一句話，實測單一
  句子重複 56 次、143 筆 inbox 記錄裡有 125 筆是這種重複，於是整批升級訊息變成背景雜訊，真正該看
  的那一則跟著被一起略過。現在收到一則，代表狀態真的變了。
- **已經交付的 worker 不會再被推。** 自動推進、停滯偵測、以及自動推進達上限的升級這三項，只在該
  worker 的 `.stage` 是 `running` 時才做（欄位不存在時視同 `running`——`launch-worker.sh` 啟動時
  不寫它，要等你呼叫 `set-worker-field.sh` 才會出現）；`delivered`、`closing`、`closed` 三種關卡
  下一律不做。理由是 worker 在這些關卡靜止不動，本來就是回報契約要求它做的事，不是卡住；把它判成
  卡住去推，推滿上限又改成持續升級，逼得 worker 只好再回報一次交付——線上故障就是這個形狀，兩個都
  已經在 `delivered` 關卡的 worker 被每 20 秒（預設輪詢間隔）推一次「繼續」，然後被持續升級。要讓
  一個 `delivered` 的 worker 重新回到照看範圍，不必特地去改欄位——`instruct.sh` 送出下一則下行時就
  會把 `.stage` 撥回 `running`，唯一的例外是帶 `--kind halt` 的叫停，它不撥回（理由見「漂移處置」
  第 3 步）。另外兩種升級不受這道守衛影響，任何關卡下都照常發出：worker 卡在核准
  框（`blocked`），以及你自己欠一則 `need-you` 的定案回覆超過時限。這兩件事在哪個關卡都需要人介
  入，跟該不該推無關。
- **自動推進計數只由你的下行歸零，叫停除外。** 舊版是 worker 回報 `delivered` 就歸零，這是倒因為
  果：worker 回報交付代表它該休息，不是該獲得一輪新的推進預算；而這條規則正好讓上面那個迴圈成環
  ——被推到再回報一次交付，那次回報又把計數歸零，於是重新開始推。現在只有一則真的送達的下行才歸零
  （看門狗補投成功一筆待補送也算，那同樣是你的下行終於送達），而帶 `--kind halt` 的叫停即使送達
  也不歸零。這個例外不是潔癖：叫停原本也歸零時，一個被推到上限的 worker 會讓你收到達上限升級、你
  送一則叫停要它停手、那則叫停又把推進預算續滿，於是達上限升級永遠不會再真的觸發——你每叫停一次，
  系統反而多給它一輪「繼續」的資格，迴圈自己養活自己。拿掉續杯之後，後果的形狀從「無限迴圈」收斂
  成「最多推到上限、然後升級一次」。收斂不等於關掉：看門狗仍然看不出一個 worker 剛被叫停
  （`.stage` 只記送達關卡，不記最近一則下行的種類），照樣會把閒下來的它推一把，只是推得完、也叫得
  住了。
- **卡在核准框的那則升級會告訴你後面積了多少。** 它的摘要一併帶出該 worker 目前有幾筆下行卡在待補
  送佇列，讓「有下行卡著」不是靜默的——筆數就是這個框後面塞了多少東西，也是該多快派調查者去判讀它
  的依據。但那是發訊當下的快照，不是持續更新的積壓計量：這則升級同樣受上面那條去重限制，條件持續
  成立時最多每個重提間隔重提一次，兩次之間新進佇列的下行不會產生任何新訊息，所以你手上那個數字最
  舊可能是一個重提間隔以前（預設半小時）的。要即時值就讀 `team-status.sh` 輸出的 `pending_resend=`
  欄位。

### 認出一則升級，以及四種條件各自該做什麼

升級不經 `report.sh`：看門狗自己落一筆 inbox 記錄（`token` 也是 `fyi`）再直接送給你，所以它跟
worker 自己發的 `fyi` 擠在同一個 token 底下。三個可機械判斷的識別訊號：訊息**沒有** `[[HAT ...]]`
前綴（那是 `report.sh` 才加的，見「上行前綴」）；摘要以 `worker=<名稱>` 開頭；對應的 inbox 記錄
`.detail_path` 與 `.locator` 都是 `null`。認錯的代價不對稱——把升級讀成 worker 的 `fyi`，會照 Token
表走到「不是漂移就不必回覆，worker 會繼續做」，而升級講的那個 worker 正好就是不會繼續做的那個。

| 升級條件 | 下一步 |
| --- | --- |
| 卡在核准框（摘要含 `agent_status=blocked` 與待補送筆數） | 派調查者讀畫面判讀，再依「派調查者的時機」列出的三種出口處置；在你處理那個框之前它不會自己脫身 |
| 已停滯（摘要含「已停滯 Xs」） | 派調查者判斷是真的卡住還是在跑一個很長的工具呼叫；真的卡住就依判讀結果叫停（叫停一律帶 `--kind halt`，理由見「漂移處置」第 3 步）、改派或結束 |
| 自動推進已達上限（摘要含「已達上限」） | 同樣派調查者判斷；推了這麼多次仍不動，代表繼續推沒有用，出口是改派或結束，不是再等 |
| 豁免到期（摘要含「有一則你還沒回的定案請求」） | 不必派人：補一則 `instruct.sh --to <worker> --text <定案> --reply-to <序號>`。序號就寫在那則摘要結尾（「回覆時請對 instruct.sh 帶 `--reply-to <序號>`」），照抄即可，不必自己去翻 inbox。填錯也不會靜默過關——`--reply-to` 會驗證那筆記錄確實是一筆還沒被回覆的 `need-you`，不是就以結束碼 `5` 失敗；最容易填錯的正是升級自己那筆記錄的序號，它跟定案請求的檔名形狀一模一樣。在你回覆之前，那個 worker 的自動推進與停滯偵測都不會恢復 |

## 漂移處置

`fyi` 的摘要被判定成漂移之後（規格 §9），依序走六步：

1. **判斷是不是漂移**（判準一）：照 goal 原本的敘述做會失敗，或做出與所述不同的結果。「有更好的做
   法」不算漂移，那是優化提案，走一般的變更討論，不進本流程。
2. **找出受影響的人**（判準二）：拿改動後的內容對每一個還活著的 role 比對三樣——它的完成判準、它
   的職責範圍（負責與不負責兩邊都算）、它與其他 role 之間的介面（含 grant 對象）——任一樣因此不再
   成立就是命中。**判不出來算命中**：多送一則的代價是一次可控的打擾，漏送一則的代價是一個靜默地建
   錯東西的 worker。
3. **先叫停他們**：對每個命中的 worker 逐一（不是群發）呼叫 `instruct.sh --to <worker> --kind halt
   --text <這次改動對你這一份的影響>`，內容是停手、先別交付任何東西、回報做到哪裡。**`--kind halt`
   在這一步不是裝飾**：一般下行會把停在 `delivered` 的 worker 撥回 `running`、重新納入看門狗的照
   看，帶了 `halt` 的這一則不撥回。不帶的後果是系統自相矛盾——叫停送到、worker 停手回報完轉成閒
   置，看門狗接著每個輪詢間隔送一次「繼續」，一邊叫它停手一邊叫它繼續。被叫停的 worker 停著不動是
   正確狀態，它欠的是你的下一個指令，不是一句「繼續」；之後真的派新任務或新目標時，那一則的
   `--kind` 不是 `halt`，關卡自然會撥回。收件方卡在 `blocked` 時
   那一則會被 `instruct.sh` 自動記進 `.pending_resend`（結束碼 `7`），不必自己重試，`watchdog.sh`
   會在它離開 `blocked` 後補投——但沒有任何機制會讓它自己離開：那個核准框要等你派調查者讀畫面判
   讀，可以代按的才呼叫 `press-approval.sh` 按掉，屬於不該代按的那兩類就停下交給人類（見「派調查者
   的時機」），補投才等得到解除。這一步不能就這樣放著，叫停正是最不該靜默送不到的一則：收不到的人
   會照舊繼續建東西。
4. **定下新目標**：呼叫 `set-goal.sh` 寫入新的四項內容（不帶 `--confirmed`——第一版之後的每一次變
   更由 orchestrator 自決，不需要人類再次確認）。若這次變更動到「怎樣算成功」，`set-goal.sh` 會印
   出 `GOAL-SUCCESS-CHANGED version=<N>`，要往事件流轉述給使用者。
5. **逐一處置成對齊、改派或結束三者之一**：對齊——任務還成立，用 `instruct.sh` 送出新目標的內容，
   照新的繼續做；改派——任務作廢但人還有用，用 `instruct.sh` 換一個新任務接著做；結束——這個角色不
   再需要，呼叫 `shutdown-worker.sh`（`--reason abandon` 或 `superseded`，並附交接檔；見「腳本一
   覽」的 `shutdown-worker.sh` 那一列——`abandon` 是這支腳本 `--reason` 的其中一個值，不是六個
   token 之一）。**走「結束」之前先看關卡**：第 3 步的叫停帶了 `--kind halt`、刻意不撥回關卡，所以
   一個在漂移發生時正停在 `delivered` 的 worker，到這一步仍然是 `delivered`，`shutdown-worker.sh`
   會以結束碼 `4` 拒絕；出口同 `done` 那一列——先 `set-worker-field.sh --to <worker> --field stage
   --value running` 撥回再關。**已交付的產物要逐一過目**：要問的不
   是這個產物要不要改，而是它跟新目標的落差要不要變成新的工作；出口是往前迭代，不是回頭改既成事實。
6. **收斂測試**：重跑第 2 步同一組判準二比對，剩下的命中全部落在已通知的 role 上才算完成；還有人沒
   有處置就是沒處理完，不是「大致上都通知到了」。

## 中斷恢復

orchestrator session 重啟之後，依序走六步。第 1 步與第 3 步由同一次 `team-init.sh --recover` 呼叫
一起完成（夾在中間的第 2 步是你自己讀檔重建，腳本不碰），其餘各是獨立的動作：

1. **重新自我命名**（`team-init.sh --recover` 的一部分）：herdr 眼中人類直接啟動的 session 沒有
   名字，且名稱會在被取代時清空，所以每次恢復都要重做，不是只做一次。
2. **讀 registry 重建進度**：讀 `team.json` 與各 `workers/<name>.json`，重建目前有哪些 worker、各自
   的關卡（`.stage`）。
3. **收回中斷時留下的持有旗標與升級閂鎖**（同一次 `team-init.sh --recover` 呼叫的另一半）：把所有
   worker 記錄裡殘留在 `true` 的 `.held` 收回成 `false`，並把升級閂鎖清空——重啟正好是 context 被清
   空的那一刻，閂鎖記著的「剛發過」已經沒有保護對象了；不清，一個重啟前就卡著、條件仍然成立的
   worker 最長要再等一個重提間隔（預設 1800 秒）才會重新提醒新的你。同時 stdout 逐行印出還有待補送
   清單的 worker：`pending-resend worker=<名稱> count=<筆數>`。**這幾行只是告知積壓量，沒有下游動
   作**：排空由看門狗負責，它補投成功一筆就移除一筆，你不要自己呼叫 `instruct.sh` 補送——那支腳本對
   `.pending_resend` 只追加、從不移除，手動補送會讓收件方收到重複下行；收件方若還卡在 `blocked`，
   還會再追加一筆，積壓反而更多。排空的前提仍然是收件方先離開 `blocked`，而那件事只有你去處理那個
   核准框才會發生。
4. **以外部權威重查**：對照 issue、PR、產物是否存在等外部事實，確認登記的進度沒有過時。
5. **`team-status.sh`**：核對哪些 tab 還活著（一筆記錄若座標對不上本 workspace 會被自動跳過，不影
   響其餘行的輸出）。
6. **最後才重掛 `watchdog.sh`**：掛起當下會補發事件，那時進度表必須已經在手上。

**這個順序不是任意的偏好，兩端各有理由**：`watchdog.sh` 排最後，是因為掛起當下會補發事件，而那時
進度表必須已經在手上。重新命名排最前，理由已經不是「後面幾步要靠它聯絡 worker」（手動補送那一步已
經拿掉了），而是看門狗要有一個登記好的名字才送得到升級——`team.json` 的 `.orchestrator_name` 是空
的時候，升級照樣落成一筆 inbox 記錄，但投遞標成失敗，你不會收到任何通知。

## 腳本一覽

`HERDR_ENV` 不等於 `1` 時，以下所有腳本一律以結束碼 `3` 結束。九個結束碼所有腳本共用同一組語意：

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
| `team-init.sh [--recover]` | 見「啟動流程」第 1 步；帶 `--recover` 時在主流程之外多做三件事——收回殘留的持有旗標、清空升級閂鎖、印出待補送清單——對應「中斷恢復」第 1、3 步 | 印出 `orchestrator=<名稱> registry=<路徑>`；帶 `--recover` 時額外逐行印出 `pending-resend worker=<名稱> count=<筆數>`，這幾行純粹告知積壓量，沒有要你做的下游動作——排空交給看門狗，不要自己補送 |
| `set-goal.sh --achieve <> --success <> --not-doing <> --assumption <> [--confirmed] [--changed-by <>] [--rationale <>]` | 收斂 goal 之後、每一次要覆寫 goal 時 | 四項有缺以 `2` 結束；印出 `GOAL-SUCCESS-CHANGED version=<N>` 代表這次動到「怎樣算成功」，要轉述給使用者，沒印代表沒動到那一項 |
| `launch-worker.sh --role <> --kind <> --cwd <> --briefing-file <> [--arg <>]... [--ack-timeout <秒>]` | goal 確認之後，逐個 role 啟動 | 成功印 `worker=<名稱> pane=<id> tab=<id> ack=ok`；結束碼 `8` 是已內部重試一次仍啟動失敗，registry 記錄已移除、`--briefing-file` 的副本仍留在 `briefings/<worker>.md`；結束碼 `6` 是識別碼取不到或 herdr 拒絕（例如建 tab 那次呼叫本身被拒），沒有寫入 registry；結束碼 `2` 是 herdr 語法錯誤（呼叫端用錯，不是啟動失敗） |
| `instruct.sh --to <> (--text <> \| --text-file <>) [--reply-to <序號>] [--kind instruct\|decision\|goal-update\|halt]` | 下行任何指令、定案、goal 傳播；回覆 `need-you` 用 `--reply-to` | 結束碼 `0` 送達；結束碼 `7` 是對方卡在核准框、這一則進了 `.pending_resend` 待補送——重送沒有意義（問題不在這則訊息），但 `watchdog.sh` 只在那個 worker 離開 `blocked` 之後才補投，而沒有任何機制會讓它自己離開：那個框要有人處理，途徑是派調查者讀畫面判讀，可以代按的才呼叫 `press-approval.sh`，屬於不該代按的那兩類就交給人類（見「派調查者的時機」）。不去處理那個框，待補送佇列就永遠排不空，而且全程靜默；結束碼 `6` 是其他真正的拒絕（目標可能已不存在）。`0` 與 `7` 都算「發出」，兩者都會把該 worker 停在 `delivered` 的 `.stage` 撥回 `running`，看門狗的照看因此自己恢復，不必再呼叫一次 `set-worker-field.sh`。撥回有兩個例外：`.stage` 是 `closing`／`closed` 時不動，以及帶 `--kind halt` 的叫停一律不撥回（叫停不是復工，理由見「漂移處置」第 3 步）——要關一個被叫停後仍停在 `delivered` 的 worker，得自己先撥回。`--kind halt` 另有一個與關卡無關的效果，別跟上面那條混在一起看：叫停即使送達也不寫 `.last_delivered_at`，因此不會把自動推進計數歸零（見「看門狗的自動推進與升級」）。兩件事各管一邊——關卡撥回決定這個 worker 在不在照看範圍，時間戳決定它的推進預算要不要重算 |
| `press-approval.sh --to <> --key <> --allows <> [--rule <>] [--startup]` | worker 卡在 `blocked`、已經知道要按哪一顆鍵與放行什麼（多半來自調查者的判讀），**且那個框不屬於不該代按的兩類**（見「派調查者的時機」） | 印出 `to=<> key=<> post_press_status=<>`；結束碼 `4` 有兩種來源，讀訊息分辨：代按前重查發現已經不是 `blocked`（畫面已變，不必按了），或帶 `--startup` 時規則不在允許清單上、分不出是哪條規則——後者那個框還在，要升級給人確認，不是不必按了，兩者收手的理由完全不同；結束碼 `2` 除了一般的參數問題，還包括 `--key` 與允許清單對該規則載明的按鍵不一致，此時腳本拒絕代按而不靜默改按清單上那顆，呼叫端與清單要先對齊；結束碼 `7` 是按了但仍是 `blocked`（可能按錯鍵，或疊了另一個框，需要重新讀畫面） |
| `shutdown-worker.sh --to <> --reason <done\|abandon\|superseded> [--evidence <>] [--handoff-file <>]` | `done` 已核對外部證據；或需要放棄／被取代（`abandon`／`superseded`，必須附交接檔） | 成功印 `to=<> reason=<> tab=<> closed`；結束碼 `4` 是四個拒絕點之一命中——它自己還有未回覆的 `need-you`、其他 worker 的 `.grants` 仍指向它（這兩個都是「有人正在等它」）、還在 `delivered` 關卡、或不屬本 workspace |
| `set-worker-field.sh --to <> --field <stage\|completion_criteria\|delivery_point\|end_point> --value <>` | 交付點／終點／完成判準確定時；`.stage` 需要變動時（例如收到 `delivered`） | 成功印 `to=<> field=<> set`；結束碼 `2` 是欄位不在這支腳本自己那層更窄的白名單內、或 `--field stage` 的值不是 `running`／`delivered`／`closing`／`closed` 四個生命週期關卡之一；結束碼 `4` 是不屬本 workspace。座標類、計數類欄位不透過本腳本寫，各有專責寫入端（見 `lib/common.sh` 欄位白名單一節） |
| `grant-peer.sh --from <> --to <> [--revoke]` | thin command 的 `grant` 落地時；漂移處置改變了介面時 | 成功印 `from=<> to=<> granted`（或 `revoked`）；下行通知是 best-effort，送不到只印一句提示，不影響授權本身已經生效 |
| `team-status.sh` | 中斷恢復核對哪些 tab 還活著；想看全隊概況時 | 逐行 `worker=<> stage=<> status=<> seq=<> held=<> pending_resend=<> unprocessed=<>`；某一筆座標對不上本 workspace 會被跳過，不影響其餘行 |
| `fetch-detail.sh --seq <序號>` | 某則回報需要讀細節之前，先取路徑 | 印出絕對路徑（不含內容）；結束碼 `5` 是該序號沒有細節檔 |
| `watchdog.sh [--once]` | goal 確認之後即掛上長駐（不帶 `--once`，不必等第一個 worker 啟動）；中斷恢復時排在最後一步才重掛 | **長駐模式必須以背景／detach 方式啟動，不得前景阻塞呼叫**——它是無界輪詢迴圈，前景呼叫逾時會被工具收掉，看門狗從此消失且不會有任何錯誤訊息，四項職責（自動推進、升級、停滯偵測、投遞重試與待補送補投）一起停止；長駐時不會自己結束。`--once` 供人工巡檢一輪。存活判準只有單向效力：`watchdog.log` 新增了 `auto-push`（真的送出一次自動推進）或任一種 `skip` 行，就證明它還活著。`skip` 的 `reason` 有三個值：`missing_pane_id`（那筆 worker 記錄沒有 pane 座標）與 `process_failed`（處理那個 worker 途中致命失敗）以 `worker=<名稱>` 為識別欄位；`retry_blocked_failed`（重投某一筆先前投遞失敗的上行記錄時致命失敗，最可能是等鎖逾時）改以 `inbox=<序號>-<worker 名稱>.json` 為識別欄位。三種都是偶發一次不必理會、同一筆反覆出現才值得追。反過來不成立——整支腳本只有這四個寫入點，升級、補投成功、停滯追蹤都不寫，所以沒有新記錄既不代表它停了、也不代表沒事可做。要補強觀測就看 inbox 有沒有新的升級記錄、或 `team-status.sh` 的欄位有沒有變化 |

### worker 端腳本

以下三支由 worker（不是 orchestrator）呼叫，收錄在此是因為 orchestrator 需要知道它們存在，才看得
懂 worker 的行為與回報契約在講什麼：

| 腳本 | 用途 |
| --- | --- |
| `report.sh` | worker 唯一的上行入口，六個 token 都經這裡送出，見 `worker-contract.md` |
| `send-peer.sh` | 已被 `grant-peer.sh` 授權的 worker，橫向直接送訊息給另一個 worker |
| `wait-peer.sh` | worker 端輪詢等同儕的 `state_change_seq` 改變；orchestrator 不使用，見「不使用任何 `wait-*` 動作」 |

## 門檻值

六個門檻值都能覆寫，而且都沒有實測依據（規格 §15；`AGENT_TEAM_NEEDYOU_LIMIT_SECONDS` 的三倍是最終
審查修正時拍的，最後兩個是線上故障修正時新增的，同樣都是當下拍的數字）——私用階段的起點，公開後要
能讓陌生使用者覆寫並知道它們沒有依據：

| 環境變數 | 預設值 | 影響 |
| --- | --- | --- |
| `AGENT_TEAM_POLL_SECONDS` | 20 | `watchdog.sh` 每輪掃描的間隔 |
| `AGENT_TEAM_STALL_SECONDS` | 1800 | 同一個 worker 的 `state_change_seq` 連續多久沒變就判定停滯並升級；射程只涵蓋 `.stage` 是 `running` 的 worker（見「看門狗的自動推進與升級」），對這些 worker 的代價是靜默停住最壞要等滿一個週期才被發現，其餘關卡的 worker 則完全不在這道偵測底下 |
| `AGENT_TEAM_AUTO_PUSH_LIMIT` | 10 | `watchdog.sh` 對同一個 worker 累計自動推進「繼續」的次數上限，達上限改為升級而不是繼續推 |
| `AGENT_TEAM_NEEDYOU_LIMIT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS` 的三倍 | 一則 `need-you` 定案請求從它的 `.created_at` 起算、等 orchestrator 回覆超過這麼久就視為豁免到期：看門狗開始持續提醒你回覆，不看當下 `agent_status`。到期改變的只有這一件事——自動推進與停滯偵測不會因此恢復，只要那筆記錄還沒被帶 `--reply-to` 的回覆標成已處理，每一輪都在發完升級的那個點就返回，兩者永遠走不到 |
| `AGENT_TEAM_ESCALATION_REPEAT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS`（該變數自身預設 1800） | 同一個升級條件持續成立時，兩次升級之間至少要隔這麼久（見「看門狗的自動推進與升級」） |
| `AGENT_TEAM_LOCK_TIMEOUT_SECONDS` | 30 | registry 檔案鎖的等待上限；等不到鎖的腳本以結束碼 `5` 明確失敗，而不是無限期掛住 |

前五個是 `watchdog.sh` 自己的門檻，它的檔頭也是這樣數的；`AGENT_TEAM_LOCK_TIMEOUT_SECONDS` 定義在
`lib/common.sh`，凡是要寫 registry 的腳本都吃它（看門狗只是其中之一），所以這張表比那份檔頭多一
個——兩邊數字不同不是誰過時了。

另有一個 worker 端門檻 `AGENT_TEAM_SUMMARY_MAX`（`report.sh` 讀取，預設 500 字元，`ack` token 豁
免）：目前沒有任何注入機制會把它寫進 worker 的環境（`launch-worker.sh` 只注入五個 `AGENT_TEAM_*`
身分變數，不含這一個），所以除非有人手動在 worker 的 shell 環境裡另外設定，實際一律沿用預設值。

## 已知上限

以下五項是本設計刻意接受、不是遺漏，發現對應症狀時不要當成 bug 去修：

- **叫停壓不到零**：漂移處置第 3 步的叫停指令，worker 要到手上這一輪跑完才會讀到，這段空窗裡燒的
  token 與可能交付的過時產物是已知代價，白工壓得低、壓不到零。
- **沒有任何機制會自動按掉核准框**：看門狗偵測得到 `blocked`、也會升級給你，但代按這個動作需要知
  道按哪一顆鍵、那一顆放行什麼，這個判斷只能由調查者讀畫面得出，不能讓看門狗盲按。後果是一個
  `blocked` 的 worker 會一直停在那裡直到 orchestrator 去處理，期間所有要送給它的下行都積在待補送
  佇列裡。這是安全邊界換來的代價，不是遺漏。
- **落差回報完全靠散文**：worker 判斷「文件說的跟實際不一樣」該不該回報，完全依賴 `worker-contract.md`
  的措辭，沒有任何機制強制執行；若它自己繞過去解決了，它會判成不必回報。
- **低保真 kind 失去兩種偵測**：`agy`、`opencode`（見 `provider-drivers.md`）沒有正向 `idle` 規則，
  只能靠 `AGENT_TEAM_STALL_SECONDS` 停滯偵測接住「違約沒回報就停下」與「原地繞圈」；而這道偵測本身
  只涵蓋 `.stage` 是 `running` 的 worker，關卡一旦是 `delivered`／`closing`／`closed`，這兩種失效就
  再也沒有東西接得住。啟動這兩家的 worker 時要在事件流裡明確告知使用者這個落差。
- **要整合產物的 orchestrator，context 隔離不完全成立**：如果這個 team 的目標是由 orchestrator 親
  自把多個 worker 的產物整合起來（而不只是分頭產出各自獨立的東西），調查者代讀壓得低但壓不掉——最
  後整合那一次，內容一定得進 orchestrator 的 context。這條張力沒有機制可以迴避。
