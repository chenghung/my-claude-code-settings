#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/watchdog.sh
#
# 用法：watchdog.sh [--once]
#
# 職責（規格 §5、§8、§9、§13，Task 12）：事件層的長駐看門狗，一個迴圈
# 四個職責：自動推進、升級、停滯偵測、投遞重試與待補送補投。`--once`
# 只跑一輪就結束，供測試與人工巡檢；不帶參數則以 AGENT_TEAM_POLL_
# SECONDS 為間隔無限迴圈。
#
# ---- 一個迴圈、一個資料來源、兩個時間視野 ----
# 每輪只呼叫一次 `herdr agent list`，經 hat_whitelist_agents 投影後才
# 使用。自動推進看的是「這一輪」的即時狀態；停滯偵測看的是同一份輪詢
# 歷史累積出來的 state_change_seq 變化——兩者共用同一次呼叫，不是兩個
# 各自輪詢的機制。理由：自動推進不能等停滯門檻那麼久，worker 的 CLI 每
# 結束一個回合就閒置，要是等半小時才被推一把，整個團隊會慢到不能用；
# 但停滯偵測本來就需要跨輪比較，沒有第二個獨立輪詢的必要，用同一份歷
# 史算就好。
#
# ---- 為什麼只用 agent list，不用 agent get 或 api snapshot ----
# 三者都拿得到 agent_status 與 state_change_seq 這兩個判斷要用的欄
# 位，但 agent get 一次只回一個目標，team 有 N 個 worker 就要 N 次往
# 返；api snapshot 回的是整個 session 的快照，欄位一樣但量體大得多。
# agent list 一次呼叫拿到全部 agent，是三者裡唯一同時滿足「一次往
# 返」與「量體最小」的。
#
# ---- state_change_seq 是全域共用的遞增計數器，不是每個 agent 各自的
#      計數 ----
# 已實測連續取樣時多個 agent 的值落在同一區間、跨兩個 workspace 交
# 錯。判斷「這個 worker 動了沒」一律比對同一個 worker 前後兩次觀測到
# 的值有沒有改變，不得判斷數值有沒有增加——這個全域序號永遠在增加，
# 「有沒有增加」這個讀法會讓停滯偵測恆真式地失效。跟 wait-peer.sh 的
# 死鎖防護判準是同一個成因，這裡是它的多 worker 版本。
#
# ---- 五個門檻值都能覆寫，而且都沒有實測依據 ----
# AGENT_TEAM_POLL_SECONDS（預設 20）、AGENT_TEAM_STALL_SECONDS（預設
# 1800）、AGENT_TEAM_AUTO_PUSH_LIMIT（預設 10）、AGENT_TEAM_NEEDYOU_
# LIMIT_SECONDS（預設 AGENT_TEAM_STALL_SECONDS 的三倍，見下方「豁免的
# 時間上限」一節）、AGENT_TEAM_ESCALATION_REPEAT_SECONDS（預設同
# AGENT_TEAM_STALL_SECONDS，見下方「升級去重」一節）五者皆可用同名環境
# 變數覆寫；五個數字都是私用階段的起點，沒有任何實測依據（規格 §15 未
# 驗清單「摘要長度上限、自動推進上限、空轉判定秒數都是估的」；三倍這
# 個倍數是最終審查修正時拍的，同樣沒有實測依據；重提間隔沿用 AGENT_
# TEAM_STALL_SECONDS 當預設值是線上故障修正時的判斷，同樣沒有實測依
# 據）。
#
# ---- 停滯門檻的代價 ----
# worker 靜默停住，最壞情況要等滿一個 AGENT_TEAM_STALL_SECONDS 週期才
# 會被偵測到並升級——這個延遲是本設計的已知代價，不是遺漏；把門檻調
# 小會提早發現，但也會提高低保真 kind（agy、opencode，見下方「低保真
# kind」一節）誤判原地繞圈的機率。這件事也會寫進 SKILL.md（Task 14）。
#
# ---- 四個職責，逐一說明 ----
#
# 1. 自動推進：worker 狀態是 idle 或 done、`.stage` 是 running（見下方
#    「.stage 守衛」一節）、沒有未回覆的 need-you、持有旗標為 false、
#    自動推進計數未達上限 → 直接經 `hat_herdr agent prompt` 送出一則
#    「繼續」，計數加一，orchestrator 完全不知情。不走 instruct.sh：那
#    支腳本會設持有旗標，語意是「orchestrator 正在跟這個 worker 對
#    話」，自動推進正是給沒有人在對話的 worker 用的，走 instruct.sh 會
#    讓每一次自動推進都自己把自己擋掉下一輪。看門狗自己在 registry 根
#    目錄（跟 peer-log/ 同層，不是它裡面）落一行日誌記下推進了誰。
#
#    計數重置（線上故障修正重寫）：舊版看「worker 有沒有回報
#    delivered」，但這正是 livelock 的成因——worker 在 delivered 關卡
#    靜止是契約要求的正常狀態，卻被當成卡住而持續推進，推滿上限後
#    worker 只好再回報一次 delivered，這一報又把計數歸零、重新開始
#    推，形成自我維持的迴圈。正確的歸零時機只有一個：orchestrator 真
#    的送出了一則下行。實作上，instruct.sh 成功送出下行時寫
#    .last_delivered_at（它自己擁有的欄位）；本腳本的 hat_wd_apply_
#    delivery_reset 讀到這個欄位跟自己的水位線 .auto_push_reset_seen_
#    at 不同時，才歸零 .auto_push_count 並把水位線推到這個新值，避免
#    同一次下行在後續每一輪都被重複判定成「新的」而把計數重置到 0，讓
#    上限形同虛設（見 lib/common.sh 欄位白名單一節對這兩個欄位的說
#    明）。hat_wd_retry_pending_resend 補投待補送佇列成功時視同一次下
#    行送達，直接歸零 .auto_push_count（那是看門狗自己的程式碼，不透
#    過這兩個欄位間接觸發，見該函式檔頭說明）。
#
# 2. 升級：自動推進計數達上限 → 投遞一則摘要給 orchestrator，不再自
#    動推進。狀態是 blocked → 一律投遞給 orchestrator，不送任何文字下
#    行給那個 worker 本身（文字下行會被 herdr 以 agent_blocked 拒絕，
#    只有代按這條路，而代按需要調查者先讀畫面判讀那個框放行什麼），摘
#    要一併帶出 .pending_resend 目前的筆數，讓「有下行卡著」不是靜默
#    的。狀態是 unknown → 不得自動推進（它不證明工作已完成，可能打斷
#    正在做事的 worker），只有停滯門檻到了才升級。
#
#    「投遞一則摘要給 orchestrator」實作成：在 inbox/ 落一筆記錄
#    （token=fyi、worker=<被升級的那個 worker>），並嘗試呼叫
#    `hat_herdr agent prompt <orchestrator>` 通知 orchestrator——這是
#    best-effort，送不到只是記在 .delivery（同 report.sh「投遞失敗不
#    是本腳本的失敗」一節的既有處理方式），落檔本身已經是持久記錄，
#    不因為這次送不到就遺失。
#
#    ---- 升級去重（線上故障修正新增）----
#    上面這個動作原本沒有任何去重：只要觸發條件還成立，下一輪 poll 就
#    原封不動再發一次（線上實測單一句子最高重複 56 次，時間戳間隔穩定
#    在一個 poll 間隔）。五個升級呼叫點（豁免到期、停滯、blocked、達上
#    限、worker 身分消失）改經 hat_wd_escalate_once 統一去重：同一個條
#    件只在「從不成立變成成立」的那一輪送出，持續成立時最多每隔
#    AGENT_TEAM_ESCALATION_REPEAT_SECONDS 秒重提一次；五個呼叫點在控制
#    流程上互斥（同一輪至多命中一個就會 `return 0`），因此只需要記
#    「目前是哪個條件」（.escalation_active）與「上次真的送出的時間」
#    （.escalation_last_at）兩個欄位，不需要每個條件各自一組。條件不
#    再成立的那一輪（五個升級分支都沒有觸發）呼叫 hat_wd_escalation_
#    clear 把 .escalation_active 清成 null，讓下次重新成立時不必等重
#    提間隔、能立刻再發——這正是「從 blocked 變成達上限屬於不同條件，
#    必須立刻發出」這個要求的實作方式：條件名不同就等同「重新成立」。
#
# 3. 停滯偵測：`.stage` 是 running（見下方「.stage 守衛」一節）、且
#    worker 的 state_change_seq 連續超過 AGENT_TEAM_STALL_SECONDS 沒有
#    改變、且狀態落在 idle／done／unknown 三種之一 → 升級（跟第 2 點共
#    用同一個升級動作）。blocked 不在這個 case 清單裡：它已經被 2a 項
#    攔在前面並 `return 0`，狀態走到這裡時不可能是 blocked，見下方
#    「修正迴圈：blocked 升級搬到停滯偵測之前」一節。working 也不在這
#    個判斷範圍內：worker 持續做同一件事、狀態沒有轉換時，
#    state_change_seq 本來就可能長時間不動，那是正常的，不是停滯。低
#    保真 kind（agy、opencode）必須依賴這一項：它們的 idle 不帶正向證
#    據（herdr 規則檔對這兩種 kind 完全沒有正向 idle 規則，見
#    lib/common.sh hat_kind_fidelity 檔頭），「違約沒回報就停下」與
#    「原地繞圈」只能靠停滯偵測接住，本腳本不因為 kind 是 low 保真就
#    跳過這一項或降低門檻——目前沒有材料支持一個更精細的門檻，統一沿
#    用同一個 AGENT_TEAM_STALL_SECONDS。
#
# ---- 修正迴圈：blocked 升級搬到停滯偵測之前，不再共用同一組觸發狀態
#      ----
# 舊版控制流程先跑第 3 項（停滯偵測），`case` 命中狀態涵蓋
# idle／done／blocked／unknown 四種，跟第 2a 項（blocked 一律升級）各
# 自獨立判斷、互不知道對方——但兩者共用同一個「目前是哪個條件」的去重
# 閂鎖（.escalation_active 只記單一值，不是每個條件各自一組，見上方
# 「升級去重」一節）。後果：一個 `.stage` 是 running、連續卡在核准框超
# 過 AGENT_TEAM_STALL_SECONDS 的 worker，第 3 項先攔下、把條件切成
# stall 並 `return 0`，第 2a 項的程式碼那一輪起永遠執行不到——不是偶爾
# 搶答一次，是只要它繼續卡在 blocked，就永久由第 3 項接管。差別不只是
# 條件名：第 2a 項的摘要帶著「目前有 N 筆下行卡在待補送佇列」，第 3 項
# 的摘要完全沒有這個數字，只講「已停滯 Xs，狀態=blocked」——一個卡超過
# 門檻的 worker，正是積壓最可能已經很可觀的那一個，卻在這個時間點被換
# 成看不出積壓量的通用訊息，方向是反的：兩個條件同時成立時，該勝出的
# 是比較具體、比較能據以行動的那一個（「卡在核准框」指名了原因也指名
# 了處置；「已停滯」只說它沒動），不是先跑到的那一個。
#
# 修法：把第 2a 項移到第 3 項之前執行。第 2a 項本身不受 .stage 守衛與
# 豁免影響，跟原本一樣對任何 stage、任何時候的 blocked 狀態一律先攔
# 下、送出帶佇列筆數的訊息、`return 0`；第 3 項因此再也不會看到
# status=blocked，`case` 清單拿掉這個到不了的分支，只剩 idle／
# done／unknown 三種。
#
# ---- .stage 守衛（線上故障修正新增，修正迴圈第二輪擴大範圍）：只有
#      running 才自動推進、才判停滯、才發達上限升級；三項對三項——
#      blocked 升級、豁免到期升級、worker 身分消失升級不受影響 ----
# `.stage` 的生命週期是 running → delivered →（可回到 running）→
# closing → closed（見 set-worker-field.sh 檔頭「.stage 的值另有一層
# 驗證」一節）；`delivered`、`closing`、`closed` 三者是 worker 依照
# references/worker-contract.md 的要求靜止不動的正常狀態（只在新的指
# 示或 review 回饋進來時才動作），不是卡住。舊版第 1、3 兩項完全不看
# `.stage`，於是把這個正常的靜止判成需要推一把，推滿上限又改成每輪升
# 級，逼得 worker 只好再回報一次 delivered——而這一報在舊版計數重置邏
# 輯下又把計數歸零、重新開始推，兩個各自合理的機制疊成一個自我維持的
# livelock（時間戳完全吻合：worker 回報 delivered 後不到一分鐘，自動
# 推進計數就從 1 重新開始）。`.stage` 欄位不存在時視同 running——
# `launch-worker.sh` 啟動時不寫這個欄位，要等 orchestrator 呼叫
# set-worker-field.sh 才會出現，缺席代表剛啟動、正在跑，不是已經交付。
#
# 修正迴圈第一輪的版本只把第 1（自動推進）、第 3（停滯偵測）兩項納入
# 守衛，第 2b（達上限升級）當時被歸類成「既有計數已經到達門檻這個既成
# 事實的通知」而排除在外，理由是它跟第 1 項的推進動作分開處理。這個劃
# 分被線上實際發生的故障推翻：故障 registry 裡的 w4a-developer-1097-be
# 當時 `.stage` 是 `delivered`、`.auto_push_count` 是 10，而它送出的
# 「自動推進已達上限 10 次仍是 idle，改為升級」那句話在 inbox 裡重複了
# 56 次、是全部訊息裡重複最多的一句。「已達上限」這句話的語意是「我推
# 了 N 次它還是不動」，前提是還在推；`.stage` 一旦不是 running，這個前
# 提就不成立，訊息指向一件不再發生的事——對 orchestrator 而言讀起來像
# worker 卡住了，但它其實只是交付完在待命，這正是使用者原本回報的「鬼
# 打牆」的一部分，只是升級去重（見上方「升級去重」一節）把頻率從每個
# poll 一次降到每個重提間隔一次，沒有真正停下來。
#
# 修法：第 1、3、2b 三項只在 `.stage` 是 running 時進行；第 2a
# （blocked 升級）與豁免到期升級不受這個守衛影響，任何 stage 下都照常
# 發出——核准框卡住與定案請求沒回覆都是任何 stage 下都需要人介入的真
# 實阻塞（前者）或 orchestrator 自己欠的回覆（後者），跟 worker 該不該
# 被推無關。worker 身分消失升級同樣不受這個守衛影響（見下方「worker
# 身分消失」一節）：那個檢查排在讀 `.stage` 之前，任何 stage 下都照常
# 升級，理由是同一套——pane 佔用者已經換人是任何 stage 下都需要人重新
# 啟動的真實情況，跟 worker 原本該不該被推無關。第 2b 這個分支不成立
# 時（不論是計數真的還沒到，或是 `.stage`
# 不是 running）都會落到 hat_wd_process_worker 既有的升級閂鎖清空點
# （見上方「升級去重」一節），讓 worker 之後真的回到 running、又推到上
# 限時能立刻重新發出一次，不被重提間隔壓抑。
#
# 4. 投遞重試與待補送補投：兩種佇列，各自的「對象」不同。
#    a) inbox/ 裡 .delivery 是 blocked 或 orchestrator_lost 的記錄——
#       前者是 worker 上行時 orchestrator 剛好卡在核准框，後者是
#       orchestrator 的 agent 名稱當時已經從 herdr 消失（見 report.sh
#       檔頭「投遞失敗不是本腳本的失敗」一節）。這裡的「對象」都是
#       orchestrator 自己：只在這一輪觀測到 orchestrator 本人的名稱查
#       得到、且狀態不是 blocked 時才重投，逐筆呼叫 `hat_herdr agent
#       prompt <orchestrator> <summary>`，成功就把該筆 .delivery 改成
#       delivered。名稱查不到時另外拉警報，見下方 `hat_wd_retry_
#       blocked_inbox` 函式本體。
#    b) workers/*.json 的 .pending_resend 清單——這些是 orchestrator
#       下行時那個 worker 剛好卡在核准框（見 instruct.sh 檔頭
#       「blocked 是待補送」一節）。這裡的「對象」是那個 worker：只在
#       這一輪觀測到它的狀態不是 blocked 時才逐筆補投，每成功一筆就
#       呼叫 hat_remove_pending_resend 移除該筆，並視同一次下行送達直
#       接歸零 .auto_push_count（見上方「計數重置」一節；這是本腳本自
#       己的程式碼，不透過 .last_delivered_at 間接觸發）。持有旗標跟這
#       個佇列清不清空無關，本腳本完全不寫 .held（見 hat_wd_retry_
#       pending_resend 檔頭「最終審查 Critical」一節）。
#
# ---- 豁免：等待 need-you 回覆的 worker 一律豁免自動推進與停滯升級 ----
# 有未回覆 need-you 的 worker 停著是正常的——它在等 orchestrator 決
# 定，不是卡住。豁免範圍包含第 1、3 兩項（第 2 項的 blocked／達上限升
# 級不受影響：核准框與達上限本身就是需要人介入的訊號，跟等 need-you
# 回覆是兩件不同的事，兩者可能同時成立，此時仍要升級）。
#
# ---- 豁免的時間上限：最終審查 Important 修正 ----
# 上面這個豁免原本沒有上限，而它能不能結束完全繫於 orchestrator 有沒
# 有回覆——判準是 inbox 那筆定案請求有沒有被標成已處理，而這個標記只
# 有下行腳本帶 --reply-to 回覆時才會寫。orchestrator（一個 context 固
# 定、會被壓縮的 LLM）若回覆時漏帶這個參數、或根本忘了回，那筆記錄永
# 遠是未處理：該 worker 從此同時豁免自動推進與停滯升級，且
# shutdown-worker.sh 本身也會因為同一筆未回覆記錄拒絕關閉它——三條出
# 口同時關上，全程零訊息。停滯偵測是設計裡「worker 停住而沒人知道」的
# 唯一後盾，尤其對低保真 kind（見第 3 項），把它對「等定案」無上限地
# 關掉，等於假設 orchestrator 永遠不會忘記回覆。
#
# 修法：從這個 worker 名下最早一筆仍未回覆的定案請求算起（用它的
# .created_at），等待超過 AGENT_TEAM_NEEDYOU_LIMIT_SECONDS（預設是
# AGENT_TEAM_STALL_SECONDS 的三倍）就視為豁免到期，不論當下 agent_
# status 是什麼都直接升級，摘要明講「有一則你還沒回的定案請求」，讓
# orchestrator 一看就知道該做什麼。這個檢查獨立於第 3 項的停滯偵測
# （state_change_seq 比對）：等待中的 worker 完全可能持續轉換狀態、
# state_change_seq 一直在動，那套機制永遠不會判定它停滯，因此上限到期
# 這件事不能只靠放寬第 3 項的豁免條件，需要一條不看 state_change_seq
# 的獨立路徑。
#
# ---- 豁免到期升級的摘要要帶得出序號：獨立審查抓到的問題 ----
# 升級的處置是叫 orchestrator 補一則帶 --reply-to <序號> 的回覆，但上
# 面這則摘要原本只有等待秒數與上限，不含序號；這則升級本身也不經
# report.sh，沒有那個帶序號的上行前綴（見 lib/common.sh「上行前綴」一
# 節）可以切。instruct.sh 的 --reply-to 在本次修正之前只檢查同名檔案
# 存不存在，不驗證 token 或 processed_at，而升級自己那筆 inbox 記錄的
# 檔名形狀跟真正的 need-you 定案請求完全一樣——結果是拿升級的序號去回
# 覆會通過檢查、以結束碼 0 成功，被標成已處理的卻是升級記錄本身，真正
# 該回覆的 need-you 永遠停在未處理，三條出口（自動推進、停滯偵測、
# shutdown-worker.sh 的關閉檢查）繼續同時關上，而且全程零訊息。修法有
# 兩處：本函式已經為了算 needyou_wait_elapsed 找出最早一筆未回覆的定
# 案請求，順手把它的序號一併帶進摘要；instruct.sh 的 --reply-to 也補
# 上驗證，拒絕指向非 need-you 或已處理記錄的序號（見該檔同名一節），
# 兩處缺一不可——只修其中一處，另一處仍然會讓 orchestrator 拿錯序號或
# 拿到序號卻被靜默接受。
#
# ---- 白名單欄位：任何要投遞給 orchestrator 的內容只能是本腳本自己組
#      出來的摘要文字 ----
# hat_whitelist_agents 六個欄位裡沒有 terminal_title／terminal_title_
# stripped（帶的是模型與使用者原文），本腳本組摘要時也只用 worker 名
# 稱、agent_status、門檻數字這些已知安全的值，不會把任何 herdr 原始回
# 應轉發出去。
#
# ---- 單一 worker 的致命失敗不得帶走整個行程：保護放在逐筆的呼叫點 ----
# 競態：`shutdown-worker.sh` 從讀取記錄開始一路持有
# `${worker_file}.lock`，直到最後 `rm -f "$worker_file"` 才放手（見該腳
# 本「參與檔案鎖協定」一節）。`hat_wd_process_worker` 開頭的
# `[ -f "$worker_file" ]` 只證明「進入這一筆的當下」記錄還在；關閉序列
# 完全可以在那之後才跑完，於是本輪後續任何一次寫入——更新
# .last_seq_stamp／.last_seq_changed_at、推進計數、升級時寫 inbox 記
# 錄的 `hat_json_set`，以及補投佇列走的 `hat_remove_pending_resend`
# ——都會在等到鎖之後發現目標檔已經不在，以 `hat_die 5` 結束。那是真正
# 的 `exit`，不是 `return`。
#
# 舊版的後果：這個 `hat_die` 一路傳播出 `hat_wd_run_once`，把底下的
# `while :; do ... done` 整個帶走，自動推進、停滯偵測、投遞重試三項一
# 起停止；沒有重掛機制，也沒有人會發現看門狗已經不在了。這正是本設計
# 最想消滅的失效形狀，成因跟 `hat_wd_process_worker`「修正迴圈第一輪」
# 那一節同一類：原則寫在檔頭，沒有寫進控制流程——當時只有 workspace 那
# 一道守衛被包進子殼，寫入這條路徑完全沒有被涵蓋。
#
# 保護放在哪一層：放在 `hat_wd_run_once` 逐筆呼叫
# `hat_wd_process_worker` 的那一個點，整次呼叫包進子殼，而不是逐一包住
# 每個 `hat_json_set`。三個理由——一、要擋的不是某幾個特定呼叫，而是
# 「處理這一筆時發生致命失敗」這整個類別：逐一包只保護得到今天數得出
# 來的呼叫點（光 `hat_wd_escalate` 內部就有七次 `hat_json_set`，補投走
# 的又是另一個同樣會 `hat_die 5` 的函式），明天多一個寫入就漏一個，而
# 漏掉的代價是整個行程再次靜默消失。二、這一筆的記錄既然已經讀不到，
# 後面所有評估都建立在不存在的狀態上，本來就該整筆放棄，沒有「跳過這
# 一句、繼續往下做」這種中間語意。三、`hat_wd_process_worker` 全程只用
# local 變數、狀態一律落在檔案上，子殼不會吞掉任何該留下的變動：已經
# 寫出去的部分照樣留著，跟原本中止在同一個點的結果一致。
#
# 被跳過的那一筆在 registry 根目錄的 watchdog.log 留一行
# `skip worker=... reason=process_failed rc=... at=...`（欄位風格沿用
# 同一個檔案既有的 skip／auto-push 行）。子殼的 stderr 刻意不攔截，
# `hat_die` 印出的原始訊息照樣出得來：日誌行負責「哪一筆、什麼時候、
# 以什麼結束碼」這種事後追得到的骨架，原始訊息負責「是哪個函式、哪個
# 欄位、哪個檔案」這種細節，兩者缺一都追不完整。
#
# 跟 `hat_wd_process_worker` 入口那道 workspace 子殼的關係：兩道並存，
# 不是重複。內層那一道處理的是一個已知且良性的情況（座標對不上或缺
# 席），它吞掉 `hat_assert_workspace` 的 stderr、缺座標時另外落一行語
# 意明確的 `reason=missing_pane_id`；外層這一道是對「其餘任何致命失
# 敗」的兜底。拿掉內層不會讓行程掛掉，但會把一個已經分類好的情況降級
# 成不明失敗，日誌多噪音而少資訊。
#
# ---- `--once` 與長駐模式一律同樣處理，不分模式 ----
# `hat_wd_process_worker`「入口守衛」一節提到的「一次性腳本才維持中止
# 語意」，區分的是 instruct.sh／press-approval.sh 那種「呼叫端指定單一
# target」的腳本與本腳本這種「一輪掃過全部 worker」的腳本，不是同一支
# 腳本的兩種跑法：`--once` 就是這個長駐迴圈的一次迭代，它照樣要掃過每
# 一個 worker，一筆壞掉就讓其餘 worker 這一輪完全沒被看到，代價跟長駐
# 模式的單輪一模一樣。另一個決定性的理由是可測性：測試只能從 `--once`
# 進來（長駐模式要背景行程加 kill 才測得到），`--once` 若改回中止語
# 意，這道保護在唯一測得到的路徑上等於從來沒有被驗證過。
#
# 這使 `--once` 有一處明確改變的行為，在此寫明而不是無聲帶過：以前一
# 筆 worker 記錄在處理途中消失，會讓整個指令以 5 結束、其餘 worker 不
# 再被處理；現在改成以 0 結束、其餘照常處理。診斷不因此減少——`hat_
# die` 的原始訊息仍然印在 stderr，另外多一行持久的 watchdog.log 記錄。
# 受影響的是「用結束碼判斷這一輪有沒有出事」這個讀法，改判準為「看
# watchdog.log 這一輪有沒有多出 skip 行」。附帶一提，記錄在處理途中消
# 失多半根本不是故障，而是一次成功的 `shutdown-worker.sh` 剛好跟這一輪
# 重疊，用非 0 結束碼回報它本來就偏重。
#
# ---- 修正迴圈：hat_wd_retry_blocked_inbox 一樣要包子殼，鎖逾時給了
#      它一條容易觸發的新路徑 ----
# 上面這整套保護只包住了 `hat_wd_run_once` 逐一呼叫 `hat_wd_process_
# worker` 那個點；排在那個迴圈之前的 `hat_wd_retry_blocked_inbox`（見
# 下方同名函式與檔頭「投遞重試與待補送補投」a) 一節）完全在保護之外，
# 而它內部逐筆把 `.delivery` 改成 `delivered` 用的正是 `hat_json_set`
# ——一樣可能以 `hat_die 5` 結束。這條路徑在補鎖逾時之前就存在（
# `hat_json_set` 本來就會在 mktemp／jq／mv 任一步失敗時 `hat_die 5`），
# 只是那些成因都很罕見；這次新增的等鎖逾時給了它一條容易撞上的新路
# 徑：只要同一輪有另一個持鎖者卡著同一份 inbox 記錄的 `.lock`，
# `flock -x -w` 等到逾時就會觸發。而且這裡完全沒有 `hat_wd_process_
# worker` 那層 `( ... ) || rc=$?` 子殼保護接著，`hat_die` 的 `exit 5`
# 會直接終止整個看門狗行程——沒有 skip 記錄，watchdog.log 一行都不會
# 留下，比一次乾淨的失敗更糟。
#
# 保護粒度：這次選逐筆 inbox 記錄包子殼，比照 `hat_wd_process_worker`
# 對 worker 的粒度，不是整個 `hat_wd_retry_blocked_inbox` 呼叫包一次。
# 理由跟上面「單一 worker 的致命失敗不得帶走整個行程」一節的三個理由
# 同構：一、要擋的是「處理這一筆 inbox 記錄時發生致命失敗」整個類別，
# 不是只堵今天看得到的這一次 `hat_json_set`，逐一堵明天多一個寫入就漏
# 一個；二、這一筆一旦寫入失敗，後面沒有「跳過這一句、繼續判斷下一個
# 欄位」的中間語意，整筆放棄最乾淨，留給下一輪重試；三、迴圈裡的狀態
# 只有本地變數與檔案，子殼不會吞掉任何已經寫出去的部分。逐筆包還多一
# 個好處：同一輪可能有好幾個 worker 各自一筆待重投的 blocked 記錄，包
# 成單一大子殼會讓一筆撞上鎖逾時就連帶跳過同一輪其餘記錄；逐筆包則只
# 丟這一筆，其餘記錄這一輪照常重投。
#
# 例外（獨立審查 Critical 修正新增）：呼叫端 `hat_wd_run_once` 後來另
# 外把整個 `hat_wd_retry_blocked_inbox` 呼叫也包了一次子殼，這不是取
# 代上面逐筆包的設計，是互補——保護對象是函式主殼層兩處新增的
# `.orchestrator_alert_active` 寫入（不在上述逐筆迴圈的保護範圍內，見
# 該函式檔頭「狀態轉換才寫 log」一節），兩者互斥、同一次呼叫至多命中
# 其中一處，沒有「逐筆重試、一筆失敗不連累其餘」這個顧慮，見
# `hat_wd_run_once` 呼叫端同名一節。逐筆迴圈本身的保護粒度不變：一筆
# `.delivery` 寫入失敗仍然只丟那一筆，不會被外層子殼放大成整輪都跳過
# ——外層子殼只在「逐筆迴圈都還沒開始執行」（兩個早退分支之一）時才會
# 因為這裡討論的兩處寫入失敗而觸發。
#
# 被跳過的那一筆在 watchdog.log 留一行 `skip inbox=... reason=retry_
# blocked_failed rc=... at=...`，欄位風格沿用同一個檔案既有的 skip
# 行；用 `inbox=<檔名>` 取代 `worker=` 當識別欄位，因為檔名本身就是
# `<seq>-<worker>.json`，已經帶著 worker 名稱，不必為了印一次 worker
# 名稱而多冒一次讀取失敗的風險。
#
# ---- 線上故障修正新增之一：worker 身分消失時宣告死亡，不再自動推進
#      （規格「設計項目一」）----
# 依據：機器重開機後 herdr 用原本的 argv 把 pane 裡的 CLI 重新拉起，
# codex／agy／opencode 沒有 resume 概念，回來的是一個空白、沒讀過任何
# briefing 的陌生 CLI；把名字補回去等於把下行送進這個陌生 CLI，比送不
# 到更糟（worker 的名稱因此不比照 orchestrator 那樣自我續租，見規格
# 「設計項目一」）。
#
# 做法：`hat_wd_process_worker` 一開始（早於 4b 待補送補投、早於任何
# 自動推進／停滯偵測／升級評估）用這一輪已經拿到的 `$whitelisted`，以
# 這個 worker 記錄的 `pane_id` 為 key 查（`hat_wd_lookup_by_pane`，不
# 是下面才會用到、以 name 為 key 的 `hat_wd_lookup`）：查到的 name 若
# 不等於這個 worker 登記的名稱——含查無此 pane（該 pane 這一輪整個不
# 在清單裡）——一律視為不符；持續不符超過 `HAT_IDENTITY_MISMATCH_
# GRACE_SECONDS`（獨立審查修正新增的緩衝，見 `hat_wd_process_worker`
# 「worker 身分檢查」一節）才真的視為身分已經消失，經既有的升級去重機
# 制（`hat_wd_escalate_once`／`.escalation_active` 閂鎖）升級一次，條件
# 名 `identity_lost`，跟既有四個（needyou_expired／stall／
# blocked／auto_push_limit）互斥；不論是這一輪只記錄不符（緩衝中）還是
# 真的升級，都直接 `return 0`，這一輪對這個 worker 的其餘處理（自動推
# 進、停滯偵測、待補送補投）全部跳過。
#
# 緩衝期間會新增一個 registry 欄位 `.identity_mismatch_since`（獨立審
# 查修正）：記「這一連串不符第一次被觀察到的時間」，`return 0` 本身達
# 成「這一輪不再對它自動推進」，但單靠它不足以分辨「第一次觀察到不
# 符」與「已經持續不符一段時間」，緩衝需要這個時間戳才能判斷門檻是否
# 已過；名稱對上時清成 null，不留殘影，見 lib/common.sh 欄位白名單一節
# 該欄位的完整說明。
#
# 這裡不呼叫 `hat_renew_orchestrator_name`：那個函式的正當性建立在
# 「呼叫者就是那個 pane 的佔用者」，看門狗是外部行程，沒有立場幫任何
# worker（或 orchestrator）補名字，見 lib/common.sh 該函式檔頭「絕對不
# 可以被 watchdog.sh 呼叫」一節。
#
# ---- 線上故障修正新增之二：hat_wd_retry_blocked_inbox 查無
#      orchestrator 名稱時不再靜默（規格「設計項目三」看門狗側）----
# 舊版在 `.orchestrator_name` 讀不到時直接 `return 0`：不重試、不記
# 錄、不通知任何人。這是跟 worker 上行 report.sh 對稱的另一半：worker
# 那一側查無 orchestrator（`agent_not_found`）時會拉警報（見 lib/
# common.sh `hat_alert_orchestrator_tab`），看門狗這一側同樣的情況若
# 完全靜默，等於這個訊號只有 worker 剛好在同一時間點回報才會被人看
# 見。修法：查不到時改呼叫同一個共用的拉警報函式，並在 watchdog.log
# 留一行 `alert reason=orchestrator_name_missing at=...`，才返回。跟
# 下面第二個早退分支（orchestrator 這一輪觀測到的狀態是 blocked）是
# 兩件不同的事，不受這裡影響：那是「名稱還在、只是暫時卡在核准框」，
# 保守跳過、等它離開再重投才是正確行為，不該套用「名稱查不到」的處置
# ----
#
# ---- 線上故障修正新增之三：agent list 失敗只跳過該輪，不得把長駐迴
#      圈帶走（規格「設計項目五」）----
# `hat_wd_run_once` 呼叫 `hat_herdr agent list` 取得這一輪的觀測資
# 料，這一步原本是裸賦值——本檔掛 `set -euo pipefail`，herdr 只要拒絕
# 一次，errexit 就會在讀到結束碼之前把整個長駐輪詢行程帶走，而且完全
# 靜默（沒有任何 skip 記錄，因為連 `hat_wd_run_once` 都沒能跑完）。herdr
# server 重啟正好會同時觸發名稱被清空與 `agent list` 失敗兩件事，若不
# 修這一項，上面「設計項目一」的身分檢查根本不會執行。
#
# 修法：跟 `hat_wd_escalate`／`hat_json_set` 已有的先例一樣，用
# `agents_json="$(hat_herdr agent list)" || rc=$?` 接住結束碼；失敗只
# 在 watchdog.log 留一行 `skip reason=agent_list_failed rc=... at=...`
# 並 `return 0`（略過這一輪其餘所有處理，含 4a 補投與逐一處理
# worker），不呼叫 `hat_die`。`--once` 與長駐模式一律同樣處理（見上方
# 同名一節）：`--once` 這一輪等於什麼都沒做、以 0 結束；長駐模式的
# `while :; do hat_wd_run_once; sleep ...; done` 則會在 `sleep` 之後
# 自然進入下一輪，不會被這一次失敗帶走。
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

readonly HAT_POLL_SECONDS_DEFAULT=20
readonly HAT_STALL_SECONDS_DEFAULT=1800
readonly HAT_AUTO_PUSH_LIMIT_DEFAULT=10

# ---- worker 身分消失緩衝門檻：固定值，不比照上面三個走環境變數覆寫
#      （獨立審查修正，見 hat_wd_process_worker「worker 身分檢查」一節
#      與 lib/common.sh `.identity_mismatch_since` 欄位說明）----
# 依據：launch-worker.sh 的 `agent start` 逾時上限是 30 秒
# （HAT_AGENT_START_TIMEOUT_MS），啟動失敗會內部重試一次，最壞情況兩次
# 嘗試都逼近逾時上限，連續觀察到「pane 存在但名稱對不上」的窗口理論上
# 可以逼近 60 秒；90 秒是在這個理論值上再留 30 秒餘裕（涵蓋兩次嘗試之
# 間 tab close／tab create／registry 寫入這些非零但通常很短的呼叫往返
# 時間，這段往返時間本身沒有實測依據，是讀原始碼推得的上界，不是量出
# 來的）。不做成環境變數：這是本檔內部的緩衝門檻，不是使用者要調整的
# 業務門檻，做成可覆寫會讓 SKILL.md「門檻值」一節那張表少列一項，修表
# 不在本次職責範圍內。
readonly HAT_IDENTITY_MISMATCH_GRACE_SECONDS=90

poll_seconds="${AGENT_TEAM_POLL_SECONDS:-$HAT_POLL_SECONDS_DEFAULT}"
stall_seconds="${AGENT_TEAM_STALL_SECONDS:-$HAT_STALL_SECONDS_DEFAULT}"
auto_push_limit="${AGENT_TEAM_AUTO_PUSH_LIMIT:-$HAT_AUTO_PUSH_LIMIT_DEFAULT}"

case "$poll_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_POLL_SECONDS 必須是純數字秒數，收到：$poll_seconds" ;;
esac
case "$stall_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_STALL_SECONDS 必須是純數字秒數，收到：$stall_seconds" ;;
esac
case "$auto_push_limit" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_AUTO_PUSH_LIMIT 必須是純數字，收到：$auto_push_limit" ;;
esac

# 預設是 stall_seconds 的三倍（見檔頭「豁免的時間上限」一節）；算預設
# 值之前 stall_seconds 已經過上面的純數字檢查，這裡的算術是安全的。
needyou_limit_seconds="${AGENT_TEAM_NEEDYOU_LIMIT_SECONDS:-$((stall_seconds * 3))}"
case "$needyou_limit_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_NEEDYOU_LIMIT_SECONDS 必須是純數字秒數，收到：$needyou_limit_seconds" ;;
esac

# 預設同 stall_seconds（見檔頭「升級去重」一節），一樣要求 stall_
# seconds 已經通過上面的純數字檢查。
escalation_repeat_seconds="${AGENT_TEAM_ESCALATION_REPEAT_SECONDS:-$stall_seconds}"
case "$escalation_repeat_seconds" in
  '' | *[!0-9]*) hat_die 2 "watchdog.sh: AGENT_TEAM_ESCALATION_REPEAT_SECONDS 必須是純數字秒數，收到：$escalation_repeat_seconds" ;;
esac

once=0
if [ "$#" -eq 1 ] && [ "$1" = "--once" ]; then
  once=1
elif [ "$#" -gt 0 ]; then
  hat_die 2 "watchdog.sh: 用法：watchdog.sh [--once]"
fi

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／instruct.sh／set-goal.sh／launch-worker.sh 的同名局部函
# 式：各腳本各自獨立定義，不共用。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

# hat_watchdog_allocate_seq <registry_root>
# 在 <registry_root>/team.json.lock 的鎖保護下，從 team.json 的
# next_seq 取號並遞增，印出取到的號碼。手法與鎖檔路徑沿用 report.sh
# 的 hat_allocate_seq（理由見該函式檔頭「序號配發」一節：取號是
# fetch-and-increment，不透過 hat_json_set；鎖檔路徑必須跟
# hat_json_set 用的同一條，否則各自序列化、彼此不排隊，等於沒鎖）。
hat_watchdog_allocate_seq() {
  local registry_root="$1" team_json lock_file lock_fd lock_timeout tmp seq new_seq

  team_json="$registry_root/team.json"
  lock_file="${team_json}.lock"

  lock_fd=""
  exec {lock_fd}>"$lock_file"
  # ---- 線上故障修正：等鎖要有逾時上限 ----
  # 這是 hat_wd_escalate 配號的唯一入口，五個升級呼叫點全部經過它；審
  # 查發現本函式沒有套用 lib/common.sh 新增的逾時機制，而它掛住的後果
  # 比一次乾淨的失敗更糟——掛住不是 exit，hat_wd_process_worker 外面
  # 那層 `( ... ) || rc=$?` 子殼保護完全接不到（子殼根本不會返回），
  # 整個長駐迴圈會凍結在這一個 worker 上，沒有 skip 記錄、沒有任何訊
  # 息。做法與 hat_json_set 一致：見 lib/common.sh 的
  # hat_lock_timeout_seconds，同樣要接住它在指令替換子殼裡的結束碼
  # （見該函式呼叫端的說明），否則驗證失敗只會讓 lock_timeout 變空字
  # 串，被 flock 誤判成別的錯誤。
  lock_timeout="$(hat_lock_timeout_seconds)" || exit "$?"
  if ! flock -x -w "$lock_timeout" "$lock_fd"; then
    hat_die 5 "watchdog.sh: 等鎖逾時（${lock_timeout}s），取號失敗：$lock_file"
  fi

  seq="$(jq -r '.next_seq // 1' "$team_json" 2>/dev/null)" || seq=""
  case "$seq" in
    '' | *[!0-9]*)
      hat_die 5 "watchdog.sh: team.json 的 next_seq 不是合法的十進位整數：'$seq'" ;;
  esac
  new_seq=$((seq + 1))

  tmp="$(mktemp "${team_json}.XXXXXX")" || hat_die 5 "watchdog.sh: 無法建立暫存檔，取號失敗：$team_json"
  if ! { jq --argjson v "$new_seq" '.next_seq = $v' "$team_json" > "$tmp" && mv "$tmp" "$team_json"; }; then
    rm -f "$tmp"
    hat_die 5 "watchdog.sh: 寫入失敗（jq 解析或置換未成功），next_seq 未遞增：$team_json"
  fi

  exec {lock_fd}>&-
  printf '%s\n' "$seq"
}

# hat_wd_lookup <whitelisted_tsv> <name>
# 從 hat_whitelist_agents 的六欄 TSV 輸出裡篩出 name 欄等於 <name> 的
# 那一行；找不到印空字串。
hat_wd_lookup() {
  local whitelisted="$1" name="$2"
  printf '%s\n' "$whitelisted" | awk -F'\t' -v n="$name" '$1 == n'
}

# hat_wd_lookup_by_pane <whitelisted_tsv> <pane_id>
# 從六欄 TSV 裡篩出 pane_id 欄（第五欄）等於 <pane_id> 的那一行；找不到
# 印空字串。跟 hat_wd_lookup（以 name 為 key）互補：後者若 pane 的佔用
# 者已經換人，會直接查無此名，分不出「pane 還在、名字換了」跟「pane
# 這一輪剛好沒出現在清單裡」的差別——身分檢查（見檔頭「worker 身分消
# 失」一節）要問的正是前者，必須以 pane_id 為 key 才問得出來。
hat_wd_lookup_by_pane() {
  local whitelisted="$1" pane_id="$2"
  printf '%s\n' "$whitelisted" | awk -F'\t' -v p="$pane_id" '$5 == p'
}

# hat_wd_needyou_pending <registry_root> <worker>
# <worker> 在 inbox/ 裡有沒有屬於自己、token 是 need-you、且
# processed_at 仍是 JSON null 的紀錄（見檔頭「豁免」一節）。找到印
# "1"，否則印 "0"。手法沿用 shutdown-worker.sh 的 hat_need_you_
# pending（各腳本各自獨立定義，不共用，理由同本腳本其餘小型輔助函
# 式）。
hat_wd_needyou_pending() {
  local registry_root="$1" worker="$2" f token who processed

  while IFS= read -r -d '' f; do
    token="$(jq -r '.token // empty' "$f")"
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "need-you" ] && [ "$who" = "$worker" ] && [ "$processed" = "null" ]; then
      printf '1\n'
      return 0
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '0\n'
}

# hat_wd_needyou_oldest_created_at <registry_root> <worker>
# <worker> 名下最早一筆仍未回覆（token=need-you、processed_at 仍是
# JSON null）的定案請求，印出「<序號>\t<.created_at>」（TAB 分隔，呼叫
# 端用 cut -f 切欄位，同 hat_wd_lookup 的既有慣例）；.created_at 沿用
# report.sh／本腳本一律寫成的 `date -u +%Y-%m-%dT%H:%M:%SZ` 固定格
# 式。沒有這種記錄則兩個欄位都印空字串。用途見檔頭「豁免的時間上限」
# 一節，以及下方呼叫端「豁免到期升級的摘要要帶得出這筆記錄的序號」的
# 說明（獨立審查抓到的問題）。ISO 8601 UTC 字串照字典序排序就是時間
# 序，直接用 `[[ < ]]` 比大小取最早一筆，不需要先各自轉成 epoch。
#
# 序號從檔名 `<序號>-<worker>.json` 取，不是從記錄內容取——inbox 記錄
# 本身不含 .seq 欄位（seq 只在檔名與 report.sh 組的上行前綴裡出現，見
# lib/common.sh「上行前綴」一節；但升級記錄不經 report.sh，沒有那個前
# 綴可切，檔名才是唯一可靠的來源）。切法是取檔名裡第一個 `-` 之前的部
# 分：seq 由 hat_allocate_seq／hat_watchdog_allocate_seq 配發，只會是
# 十進位整數、不含連字號，即使 worker 名稱本身含連字號（如
# w3n-backend）也不影響切法的正確性。
hat_wd_needyou_oldest_created_at() {
  local registry_root="$1" worker="$2" f token who processed created oldest oldest_seq base

  oldest=""
  oldest_seq=""
  while IFS= read -r -d '' f; do
    token="$(jq -r '.token // empty' "$f")"
    who="$(jq -r '.worker // empty' "$f")"
    processed="$(jq -r '.processed_at' "$f")"
    if [ "$token" = "need-you" ] && [ "$who" = "$worker" ] && [ "$processed" = "null" ]; then
      created="$(jq -r '.created_at // empty' "$f")"
      [ -n "$created" ] || continue
      if [ -z "$oldest" ] || [[ "$created" < "$oldest" ]]; then
        oldest="$created"
        base="$(basename "$f")"
        oldest_seq="${base%%-*}"
      fi
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)

  printf '%s\t%s\n' "$oldest_seq" "$oldest"
}

# hat_wd_escalate <registry_root> <orchestrator_name> <worker> <summary>
# 見檔頭「升級」一節：落一筆 inbox 記錄（token=fyi，worker=<worker>），
# 並 best-effort 呼叫 hat_herdr agent prompt 通知 orchestrator。
#
# ---- 投遞失敗依 error.code 分類，不是一律 blocked（獨立審查修正）----
# 本函式是所有看門狗自發升級（含豁免到期、停滯、blocked、達上限、
# identity_lost 五個呼叫點）共用的唯一投遞點，跟 report.sh「投遞失敗
# 不是本腳本的失敗，但依 error.code 分三種處理，不能完全靜默」一節同
# 一套分類：`agent_not_found`（orchestrator 的 agent 名稱已經從 herdr
# 消失）時 `.delivery` 記 "orchestrator_lost"、並呼叫
# `hat_alert_orchestrator_tab` 拉警報；其餘（含 `agent_blocked`）維持
# 原本的 "blocked"。讀 `AGENT_TEAM_HERDR_ERROR_CODE` 必須在
# `orchestrator_name` 非空、真的呼叫過 `hat_herdr` 之後才讀；
# `orchestrator_name` 本身為空（team 從未初始化過名稱）這條路徑完全沒
# 呼叫 `hat_herdr`，`herdr_error_code` 留空字串，落到下面的 `blocked`
# 分支，不誤讀上一次呼叫殘留的全域值（見 lib/common.sh `hat_herdr`
# 檔頭「呼叫端如何拿到 error.code」一節）。
#
# ---- 補逾時機制時發現的既有缺陷（下面 `|| exit "$?"` 已修正，這段
#      描述的是修正前、已被推翻的行為，不是現狀）----
# 本函式一路都在 `( hat_wd_process_worker ... ) || rc=$?` 這個子殼裡執
# 行，但 errexit 對「子殼裡再包一層命令替換」這件事本身已經失效（見
# lib/common.sh「registry 寫入的失敗必須由寫入端自己接住」一節同一個
# 成因）：若 `seq="$(hat_watchdog_allocate_seq ...)"` 這一步不自己檢查
# 結束碼，hat_watchdog_allocate_seq 內部的 hat_die 5（含這次新增的鎖逾
# 時）只會終止那個指令替換子殼，本函式會帶著空字串 seq 繼續往下跑、用
# 一個缺號的檔名（`inbox/-<worker>.json`）建出殘缺記錄，而不是乾淨地
# 讓整筆處理失敗、留下 skip 記錄。已用鎖逾時實測重現這個「不接結束
# 碼」的版本：套用逾時但不接結束碼時，team.json 鎖逾時不再無界掛住，
# 但也不會產生 rc=5 的 skip 記錄，watchdog.log 裡什麼都沒有——這是修正
# 前的行為。下面這一行的 `|| exit "$?"` 接住結束碼、把它變成本函式自
# 己的 exit，讓外層 `( hat_wd_process_worker ... ) || rc=$?` 接得到；
# 現狀是等鎖逾時一樣會產生 rc=5 的 skip 記錄，不是本節開頭描述的那個
# 未修正版本。
hat_wd_escalate() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" summary="$4"
  local seq inbox_file created_at rc herdr_error_code

  seq="$(hat_watchdog_allocate_seq "$registry_root")" || exit "$?"
  inbox_file="$registry_root/inbox/${seq}-${worker}.json"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  printf '{}' > "$inbox_file"
  hat_json_set "$inbox_file" '.token' '"fyi"'
  hat_json_set "$inbox_file" '.worker' "$(hat_json_string "$worker")"
  hat_json_set "$inbox_file" '.summary' "$(hat_json_string "$summary")"
  hat_json_set "$inbox_file" '.detail_path' 'null'
  hat_json_set "$inbox_file" '.locator' 'null'
  hat_json_set "$inbox_file" '.created_at' "$(hat_json_string "$created_at")"

  rc=0
  herdr_error_code=""
  if [ -n "$orchestrator_name" ]; then
    hat_herdr agent prompt "$orchestrator_name" "$summary" >/dev/null || rc=$?
    herdr_error_code="$AGENT_TEAM_HERDR_ERROR_CODE"
  else
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    hat_json_set "$inbox_file" '.delivery' '"delivered"'
  elif [ "$herdr_error_code" = "agent_not_found" ]; then
    hat_json_set "$inbox_file" '.delivery' '"orchestrator_lost"'
    hat_alert_orchestrator_tab "$registry_root"
  else
    hat_json_set "$inbox_file" '.delivery' '"blocked"'
  fi
}

# hat_wd_escalate_once <registry_root> <orchestrator_name> <worker> \
#   <worker_file> <condition> <repeat_seconds> <summary>
# 見檔頭「升級去重」一節：<condition> 是五個升級呼叫點互斥的其中一個
# 條件名（needyou_expired／stall／blocked／auto_push_limit／
# identity_lost）。跟
# <worker_file> 的 .escalation_active 不同（含缺席，即從不成立變成成
# 立，或换成別的條件）就視為新的一次；相同就檢查距離 .escalation_
# last_at 是否已經超過 <repeat_seconds>，超過才重提一次，沒超過就整段
# 跳過、不呼叫 hat_wd_escalate。條件不再成立時的清空由呼叫端另外呼叫
# hat_wd_escalation_clear 負責，本函式不處理「沒有任何條件成立」這個
# 情況——它只在「呼叫端已經判定 <condition> 這一輪成立」時才會被呼叫
# 到。
#
# ---- 獨立審查 High：閂鎖只在升級真的落地之後才記錄 ----
# 舊版先寫 .escalation_active／.escalation_last_at，才呼叫 hat_wd_
# escalate；hat_wd_escalate 內部的配號與六次 hat_json_set 任一步失敗
# 都是 hat_die 5，那時閂鎖已經先落地——後果是「升級其實沒發出去，系統
# 卻以為發了」，下一輪會被自己的重提間隔壓抑到一個重提間隔之後。修法
# 把呼叫順序反過來：先呼叫 hat_wd_escalate，只有它沒有中途 hat_die（也
# 就是升級真的落地：inbox 記錄確實建立，至於 herdr 通知本身是否送達是
# 另一回事，見 hat_wd_escalate 檔頭「best-effort」一節）才寫入這兩個閂
# 鎖欄位。這樣失敗時（不論是新條件還是重提）閂鎖維持失敗前的原狀，下
# 一輪能立刻重試，不會被誤記成「剛發過」。
hat_wd_escalate_once() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" worker_file="$4"
  local condition="$5" repeat_seconds="$6" summary="$7"
  local active now last_at elapsed

  active="$(jq -r '.escalation_active // empty' "$worker_file")"
  now="$(date +%s)"

  if [ "$active" = "$condition" ]; then
    last_at="$(jq -r '.escalation_last_at // empty' "$worker_file")"
    if [ -n "$last_at" ]; then
      elapsed=$((now - last_at))
      if [ "$elapsed" -lt "$repeat_seconds" ]; then
        return 0
      fi
    fi
  fi

  hat_wd_escalate "$registry_root" "$orchestrator_name" "$worker" "$summary"

  if [ "$active" != "$condition" ]; then
    hat_json_set "$worker_file" '.escalation_active' "$(hat_json_string "$condition")"
  fi
  hat_json_set "$worker_file" '.escalation_last_at' "$now"
}

# hat_wd_escalation_clear <worker_file>
# 見檔頭「升級去重」一節：這一輪五個升級條件都沒有成立時由呼叫端呼
# 叫，把 .escalation_active 清成 null，讓下次重新成立時不必等
# AGENT_TEAM_ESCALATION_REPEAT_SECONDS、能立刻再發一次。.escalation_
# active 本來就缺席（從未升級過，或上一輪已經清過）時是安全的無動
# 作，不多寫一次。
hat_wd_escalation_clear() {
  local worker_file="$1" active

  active="$(jq -r '.escalation_active // empty' "$worker_file")"
  [ -n "$active" ] || return 0

  hat_json_set "$worker_file" '.escalation_active' 'null'
}

# hat_wd_apply_delivery_reset <worker_file>
# 見檔頭「計數重置」一節：<worker_file> 的 .last_delivered_at（
# instruct.sh 成功送出下行時寫）跟本函式自己的水位線 .auto_push_
# reset_seen_at 不同（含水位線缺席）時，才把 .auto_push_count 歸零並
# 把水位線推到這個新值；.last_delivered_at 缺席（從未送過下行）時是
# 安全的無動作。水位線的必要性同已移除的 .auto_push_reset_seq：沒有
# 它，同一次下行會在每一輪都被重複判定成「新的」而把計數重置到 0，讓
# 上限形同虛設。
#
# ---- 獨立審查 Medium：兩個寫入的順序，讓中途失敗落在安全的方向
#      ----
# 舊版先推進水位線、才歸零計數：中途死掉會讓水位線已經追上這次下行，
# 但計數卡在舊值——下一輪的「.last_delivered_at 跟水位線不同」判斷不
# 再成立，這次下行永遠不會再觸發歸零，計數可能已經在上限之上，回到
# running 時還會多發一次本可避免的升級。修法把順序反過來：先歸零計
# 數、才推進水位線。中途死掉時計數已經是安全值（0），水位線還沒追
# 上，下一輪會再重做一次——頂多多一次無害的重複歸零，不會永遠錯過。
hat_wd_apply_delivery_reset() {
  local worker_file="$1"
  local last_delivered seen

  last_delivered="$(jq -r '.last_delivered_at // empty' "$worker_file")"
  [ -n "$last_delivered" ] || return 0

  seen="$(jq -r '.auto_push_reset_seen_at // empty' "$worker_file")"
  if [ "$last_delivered" != "$seen" ]; then
    hat_json_set "$worker_file" '.auto_push_count' '0'
    hat_json_set "$worker_file" '.auto_push_reset_seen_at' "$(hat_json_string "$last_delivered")"
  fi
}

# hat_wd_retry_blocked_inbox <registry_root> <orchestrator_name> <whitelisted>
# 見檔頭「投遞重試與待補送補投」a) 一節：inbox/ 裡 .delivery 是
# blocked 或 orchestrator_lost 的記錄，orchestrator 目前不是 blocked
# 時逐筆重投一次。orchestrator 這一輪查無觀測值（名稱已經從 herdr 消
# 失，即 orch_status 為空）時拉警報、記一行 log 之後保守跳過這一輪的
# 重投，不猜測，見檔頭「線上故障修正新增之二」一節；<orchestrator_
# name> 本身缺席（team.json 從未寫入這個欄位，team 從未初始化過）則單
# 純跳過、不拉警報——這種情況下通常也還沒有 .orchestrator_tab／
# .orchestrator_tab_label 可用。
#
# ---- 狀態轉換才寫 log：不是每一輪都無條件追加一行（獨立審查修正）----
# 上面「查無觀測值」這個分支原本只要 orch_status 持續是空，每一輪
# （預設 20 秒一次）都會無條件在 watchdog.log 新增一行、也多打一次
# `hat_alert_orchestrator_tab` 內部的 `tab get` 往返——這正是本檔檔頭與
# `hat_wd_escalate_once` 要根除的那種「同一個條件每輪重發一次」問題，
# 只是在這條路徑上重新出現。`hat_alert_orchestrator_tab` 本身仍然每輪
# 都呼叫（它內部對 `tab rename` 已經冪等，多打的只有一次唯讀的
# `tab get`，成本遠低於重複寫 log），但 log 行只在「上一輪是否已經處
# 於這個警報狀態」真的改變時才寫：team.json 的 `.orchestrator_alert_
# active`（本次修正新增，見 lib/common.sh 欄位白名單一節）記這個布林
# 狀態，從 false／缺席變成 true 的那一輪才寫 log，之後持續是 true 不再
# 重寫；名稱下一輪恢復可查時清回 false，再消失一次就又是新的一次轉
# 換，可以再寫一次。這是「不成立→成立」半邊的轉換去重，不是時間節
# 流——沒有依賴任何固定重提間隔。
hat_wd_retry_blocked_inbox() {
  local registry_root="$1" orchestrator_name="$2" whitelisted="$3"
  local orch_line orch_status f delivery worker summary rc
  local team_json alert_active

  [ -n "$orchestrator_name" ] || return 0

  team_json="$registry_root/team.json"
  orch_line="$(hat_wd_lookup "$whitelisted" "$orchestrator_name")"
  orch_status=""
  if [ -n "$orch_line" ]; then
    orch_status="$(printf '%s' "$orch_line" | cut -f3)"
  fi
  if [ -z "$orch_status" ]; then
    hat_alert_orchestrator_tab "$registry_root"
    alert_active="$(jq -r '.orchestrator_alert_active // empty' "$team_json" 2>/dev/null || true)"
    if [ "$alert_active" != "true" ]; then
      printf 'alert reason=orchestrator_name_missing at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$registry_root/watchdog.log"
      hat_json_set "$team_json" '.orchestrator_alert_active' 'true'
    fi
    return 0
  fi

  # ---- 名稱這一輪恢復可查：清掉警報狀態，讓下一次消失算新的一次轉換
  #      ----
  alert_active="$(jq -r '.orchestrator_alert_active // empty' "$team_json" 2>/dev/null || true)"
  if [ "$alert_active" = "true" ]; then
    hat_json_set "$team_json" '.orchestrator_alert_active' 'false'
  fi

  if [ "$orch_status" = "blocked" ]; then
    return 0
  fi

  while IFS= read -r -d '' f; do
    # 整筆包進子殼：跟 hat_wd_process_worker 對 worker 的保護同一個理
    # 由（見檔頭「修正迴圈：hat_wd_retry_blocked_inbox 一樣要包子殼」
    # 一節），這裡是它的 inbox 記錄版本。`hat_json_set` 一樣可能因為
    # 鎖逾時以 hat_die 5 結束；用 exit 0 取代原本的 continue，是因為
    # continue 在子殼裡不會作用在外層這個 while，改成讓子殼自己乾淨結
    # 束、外層讀到 rc=0 即可。
    rc=0
    (
      delivery="$(jq -r '.delivery // empty' "$f")"
      case "$delivery" in
        blocked | orchestrator_lost) ;;
        *) exit 0 ;;
      esac

      worker="$(jq -r '.worker // empty' "$f")"
      summary="$(jq -r '.summary // empty' "$f")"
      [ -n "$worker" ] || exit 0

      hat_herdr agent prompt "$orchestrator_name" "$summary" >/dev/null || exit 0
      hat_json_set "$f" '.delivery' '"delivered"'
    ) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'skip inbox=%s reason=retry_blocked_failed rc=%s at=%s\n' \
        "$(basename "$f")" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$registry_root/watchdog.log"
    fi
  done < <(find "$registry_root/inbox" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null)
}

# hat_wd_retry_pending_resend <worker> <worker_file> <whitelisted>
# 見檔頭「投遞重試與待補送補投」b) 一節：<worker> 目前不是 blocked
# 時，逐筆嘗試補投 .pending_resend 佇列，每成功一筆就移除該筆並直接
# 把 .auto_push_count 歸零（見檔頭「計數重置」一節：補投成功視同一次
# 下行送達，本函式是看門狗自己的程式碼，不需要透過 .last_delivered_
# at／.auto_push_reset_seen_at 這兩個欄位間接觸發，直接動自己擁有的
# 欄位即可）；一旦有一筆失敗（例如又卡進 blocked），停止處理這個
# worker 剩下的佇列，留給下一輪。
#
# ---- 最終審查 Critical：本函式不寫 .held，佇列清空跟持有旗標無關 ----
# 舊版在佇列清空後無條件把 .held 寫回 false，理由是「沒清空代表還有
# 訊息沒補投出去，orchestrator 仍在跟它對話中」——但這個推論反過來不成
# 立：佇列為空是 instruct.sh 送出下行期間的正常狀態（它只有在收到
# agent_blocked 才會入列，而那條路徑本身就會把 .held 設回 false，見該
# 腳本「blocked 是待補送」一節）。持有旗標的語意是「orchestrator 正在
# 跟這個 worker 對話，這個空窗期不要有第三則訊息插進來」，設不設、收
# 不收全由下行腳本自己決定，不是「待補送佇列還沒清空」的衍生欄位。舊
# 版把兩者混為一談的後果：審查者用樁重現過——旗標為真、佇列為空、狀態
# 閒置這個組合下跑一輪，旗標被清成 false、自動推進計數加一、且真的送
# 出了一則「繼續」，直接踩爛下行腳本剛設下的持有窗口。修法是本函式完
# 全不寫 .held，讓這個欄位回到單一語意：orchestrator 端腳本設它，中斷
# 恢復由 team-init.sh --recover 收回殘留（規格 §13 第 3 步），看門狗
# 不再是第三個寫入端（連帶更新 lib/common.sh 欄位白名單一節的分配表註
# 解）。
hat_wd_retry_pending_resend() {
  local worker="$1" worker_file="$2" whitelisted="$3"
  local line status entry text rc

  [ -f "$worker_file" ] || return 0

  line="$(hat_wd_lookup "$whitelisted" "$worker")"
  status=""
  if [ -n "$line" ]; then
    status="$(printf '%s' "$line" | cut -f3)"
  fi
  if [ "$status" = "blocked" ]; then
    return 0
  fi

  while :; do
    entry="$(jq -c '(.pending_resend // [])[0] // empty' "$worker_file")"
    [ -n "$entry" ] || break

    text="$(printf '%s' "$entry" | jq -r '.text')"

    rc=0
    hat_herdr agent prompt "$worker" "$text" >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
      break
    fi

    hat_remove_pending_resend "$worker_file"
    hat_json_set "$worker_file" '.auto_push_count' '0'
  done
}

# hat_wd_process_worker <registry_root> <orchestrator_name> <worker> \
#   <whitelisted> <stall_seconds> <auto_push_limit> <needyou_limit_seconds> \
#   <escalation_repeat_seconds>
# 對單一 worker 依序執行：0) worker 身分檢查（線上故障修正新增，見檔頭
# 「worker 身分消失」一節；pane 上的名稱換了，持續不符超過緩衝門檻才
# 升級一次，緩衝中或已升級這一輪其餘處理都全部跳過，早於 4b） → 4b)
# 待補送補投 → 讀取這一輪觀測值 → 更新
# stamp 追蹤 → 豁免的時間上限到期就直接升級（檔頭同名一節，不看
# status，不受 .stage 守衛影響） → 2a) blocked 升級（不受豁免與 .stage
# 守衛影響；排在 3) 之前，見上方「修正迴圈：blocked 升級搬到停滯偵測
# 之前」一節） → 3) 停滯偵測（內建豁免、受 .stage 守衛影響，見檔頭
# 「.stage 守衛」一節；status 這裡不可能是 blocked，已經被 2a 攔截並
# return） → unknown 直接跳過（順便清升級閂鎖） → held 直接跳過（順便
# 清升級閂鎖） → 2b) 達上限升級（不受豁免影響，但受 .stage 守衛影響，
# 見檔頭「.stage 守衛」一節） → 豁免檢查（只擋第 1 項） → 清升級閂鎖
# → 1) 自動推進（受 .stage 守衛影響）。先做補投，把上一輪卡住、這一輪
# 解除的下行儘快送出；持有旗標由下行腳本自己收放，本函式的執行順序不
# 會改變它的值（見 hat_wd_retry_pending_resend 檔頭「最終審查
# Critical」一節），因此這個順序跟後面的自動推進評估互不影響，純粹是
# 「先把積壓的事做完」。
#
# ---- 升級閂鎖清空的位置：只在確定五個條件這一輪都沒有成立時 ----
# 五個升級呼叫點都經 hat_wd_escalate_once 去重（見檔頭「升級去重」一
# 節），呼叫端只需要在「這一輪確定沒有任何條件成立」的三個退出點呼叫
# hat_wd_escalation_clear：unknown 直接跳過、held 直接跳過、以及 2b
# （達上限）判定為假之後——這一點同時涵蓋後面「豁免跳過」與「送出自動
# 推進」兩條路徑，因為兩者都已經確定 2b 不成立，不需要各自再清一次。
#
# ---- 修正迴圈第一輪：豁免檢查不得排在 2) 之前 ----
# 檔頭「豁免」一節承諾「豁免範圍包含第 1、3 兩項，第 2 項的 blocked／
# 達上限升級不受影響，兩者可能同時成立，此時仍要升級」；上一版把豁免
# 檢查寫成一句涵蓋全部後續分支的無條件 `return`，擋在 2) 之前，等於把
# 這句承諾寫在檔頭、卻沒有寫進控制流程。後果：一個有未回覆 need-you
# 的 worker，若之後又撞上一個完全不相干的核准框（agent_status 變成
# blocked），會被豁免直接放行、blocked 升級整段不會執行——這正是設計
# 最想消滅的失效形狀（卡住、沒人知道、沒有任何訊息），已用審查回合的
# mutation 實測重現並修正，見任務報告。修法：blocked 與達上限這兩個
# 「2) 升級」的分支都挪到豁免檢查之前，豁免檢查本身只留在「1) 自動推
# 進」的實際送出動作前面，不再是一句擋住後面所有分支的早退。
hat_wd_process_worker() {
  local registry_root="$1" orchestrator_name="$2" worker="$3" whitelisted="$4"
  local stall_seconds="$5" auto_push_limit="$6" needyou_limit_seconds="$7"
  local escalation_repeat_seconds="$8"
  local worker_file pane_id line status stage stamp held needyou_pending
  local last_stamp last_changed_at now elapsed auto_push_count new_count rc
  local needyou_expired needyou_oldest needyou_seq needyou_created_at
  local needyou_created_epoch needyou_wait_elapsed
  local pending_resend_count
  local pane_line pane_name identity_mismatch_since

  worker_file="$registry_root/workers/$worker.json"
  [ -f "$worker_file" ] || return 0

  # ---- 入口守衛：跟 team-status.sh 同一個理由——一次要處理本 team 全
  #      部 worker，一筆記錄的座標對不上就不該讓 hat_assert_workspace
  #      的 hat_die 4 把整個看門狗行程帶走（`--once` 之外的長駐模式下
  #      那等於整個團隊都停止被照看），因此包在子殼裡捕捉失敗、只跳
  #      過這一筆，`hat_assert_workspace` 本身仍然被呼叫到；座標缺席
  #      時也視同守衛沒通過（見 team-status.sh 同名一節「最終審查修
  #      正」——缺座標比座標對不上更可疑，不當成通過），跳過該筆並記一
  #      行日誌到 watchdog.log ----
  pane_id="$(jq -r '.pane_id // empty' "$worker_file")"
  if [ -z "$pane_id" ]; then
    printf 'skip worker=%s reason=missing_pane_id at=%s\n' "$worker" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$registry_root/watchdog.log"
    return 0
  fi
  if ! ( hat_assert_workspace "$pane_id" ) 2>/dev/null; then
    return 0
  fi

  # ---- worker 身分檢查（線上故障修正新增，見檔頭「worker 身分消失」
  #      一節）：這個 pane 上目前掛的名稱是否還是這個 worker 登記的名
  #      稱，早於待補送補投與其餘任何評估，讓身分消失時「這一輪對它其
  #      餘處理全部跳過」是真的全部，不只是自動推進 ----
  # 用這一輪已經拿到的 $whitelisted 以 pane_id 為 key 查（hat_wd_lookup_
  # by_pane），不是下面幾行才會用到、以 name 為 key 的 hat_wd_lookup：
  # 後者若 pane 佔用者已經換人，會直接查無此名，分不出「pane 還在、名
  # 字換了」跟「pane 這一輪剛好沒出現在清單裡」；本節要問的正是前者，
  # 而兩者（名字換了、或整個不在清單裡）依規格「設計項目一」都一律視
  # 為不符。
  #
  # ---- 不符不等於立刻升級：先緩衝，持續不符超過門檻才真的升級（獨立
  #      審查修正）----
  # 這裡原本一偵測到不符就立刻升級，但兩個正常的過渡期看起來跟真正的
  # 身分消失一模一樣：一、launch-worker.sh 第 3 步把 `.pane_id` 寫進
  # workers/<name>.json 早於第 4 步 `agent start`，而 `agent start` 有
  # 30 秒逾時、失敗還會內部重試一次——這段期間 pane 已經存在但 herdr 還
  # 沒把任何名稱綁上去，`agent list` 對它的名稱欄位是空的，最壞情況兩
  # 次嘗試都逼近逾時上限，連續不符窗口可以長達 60 秒上下；二、
  # shutdown-worker.sh 在 `tab close` 之後還要做交接檔複製與三步記錄歸
  # 檔才 `rm -f "$worker_file"`，這段純檔案 I/O 的窗口通常遠短於一個輪
  # 詢間隔。對這兩種正常過渡期立刻升級，是比舊版（用名稱查、查無此名
  # 時靜默跳過）更糟的退步——舊版這裡不會有任何動作，這裡卻會主動叫人
  # 去做一件錯的事（放棄這個 worker、另外啟動一個新的）。
  #
  # 緩衝用 `.identity_mismatch_since`（epoch 秒，本次修正新增，見
  # lib/common.sh 欄位白名單一節）記「這一連串不符第一次被觀察到的時
  # 間」：第一輪只記錄、不升級；之後每一輪重算經過的秒數，超過
  # HAT_IDENTITY_MISMATCH_GRACE_SECONDS 才真的呼叫 hat_wd_escalate_once
  # 升級。用經過的時間而不是輪數：輪數會隨 AGENT_TEAM_POLL_SECONDS 的
  # 設定而失真（poll 間隔設得很短時，固定輪數的緩衝可能遠遠不夠蓋住上
  # 面 60 秒的啟動窗口；設得很長時又會不必要地拖長真正故障的偵測延
  # 遲），時間戳比對不受這個影響，手法比照停滯偵測的 last_seq_changed_
  # at。門檻本身不做成環境變數可覆寫，理由見 lib/common.sh 該欄位說明。
  # 這個緩衝只延遲偵測一段固定時間，不會豁免真正的身分消失：reboot 之
  # 後長期掛著別人的 pane 會持續不符，超過門檻後照樣升級。
  #
  # 名稱對上時（不符已恢復）清掉這個欄位，不留殘影；worker 正常結束、
  # workers/<name>.json 被移除時也不需要額外清理——本函式最上面已經會
  # 因為 worker_file 不存在而直接 return。
  pane_line="$(hat_wd_lookup_by_pane "$whitelisted" "$pane_id")"
  pane_name=""
  if [ -n "$pane_line" ]; then
    pane_name="$(printf '%s' "$pane_line" | cut -f1)"
  fi
  if [ "$pane_name" != "$worker" ]; then
    identity_mismatch_since="$(jq -r '.identity_mismatch_since // empty' "$worker_file")"
    if [ -z "$identity_mismatch_since" ]; then
      # 第一輪觀察到不符：只記錄，不採信、不升級。
      now="$(date +%s)"
      hat_json_set "$worker_file" '.identity_mismatch_since' "$now"
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - identity_mismatch_since))
    if [ "$elapsed" -lt "$HAT_IDENTITY_MISMATCH_GRACE_SECONDS" ]; then
      return 0
    fi
    hat_wd_escalate_once "$registry_root" "$orchestrator_name" "$worker" "$worker_file" \
      "identity_lost" "$escalation_repeat_seconds" \
      "worker=$worker 的 pane（$pane_id）目前的佔用者已經更換，那個 CLI 沒有讀過這個 team 的任何 briefing；啟動包全文仍在 registry 的 briefings 目錄下 $worker.md 這個檔案裡；需要重新啟動一個 worker，不要嘗試對現有 pane 繼續下指令"
    return 0
  fi
  identity_mismatch_since="$(jq -r '.identity_mismatch_since // empty' "$worker_file")"
  if [ -n "$identity_mismatch_since" ]; then
    hat_json_set "$worker_file" '.identity_mismatch_since' 'null'
  fi

  hat_wd_retry_pending_resend "$worker" "$worker_file" "$whitelisted"

  # ---- hat_wd_lookup 在這裡保證找得到，不再需要「查無觀測值」的分支
  #      （線上故障修正新增：worker 身分檢查加入之後，這裡原本的死碼被
  #      推翻）----
  # 舊版這裡原本有一個「$line 為空就靜默 return 0」的分支，理由寫的是
  # 「名稱可能被清空，或暫時性的列表落差，沒有觀測值可用」。但走到這一
  # 行之前，上面的身分檢查已經用 hat_wd_lookup_by_pane 以 pane_id 為
  # key、從同一份 $whitelisted 查過一次，並且已經確認查到的名稱等於
  # $worker（不等於的那個情況已經在身分檢查那裡升級並 return 0，執行
  # 不會落到這裡）。也就是說 $whitelisted 裡必然存在一列 name=$worker
  # ——就是身分檢查剛剛查到的那一列，而 herdr 保證名稱在存活 agent 之間
  # 唯一，這裡改用 hat_wd_lookup 以 name 為 key 查同一份 $whitelisted，
  # 必然命中同一列，不可能落空。「名稱被清空」這個情境本身沒有消失，只
  # 是現在會在身分檢查那一步就被攔截並升級，不會再讓執行流程走到這裡
  # 才發現查無觀測值，因此這個分支已經是死碼，拿掉。
  line="$(hat_wd_lookup "$whitelisted" "$worker")"

  status="$(printf '%s' "$line" | cut -f3)"
  stamp="$(printf '%s' "$line" | cut -f4)"
  held="$(jq -r '.held // false' "$worker_file")"
  # ---- .stage 守衛（檔頭同名一節）：缺席視同 running，launch-
  #      worker.sh 啟動時不寫這個欄位，要等 orchestrator 呼叫
  #      set-worker-field.sh 才會出現 ----
  stage="$(jq -r '.stage // "running"' "$worker_file")"
  needyou_pending="$(hat_wd_needyou_pending "$registry_root" "$worker")"

  now="$(date +%s)"
  last_stamp="$(jq -r '.last_seq_stamp // empty' "$worker_file")"
  last_changed_at="$(jq -r '.last_seq_changed_at // empty' "$worker_file")"

  if [ -z "$last_stamp" ] || [ "$stamp" != "$last_stamp" ]; then
    hat_json_set "$worker_file" '.last_seq_stamp' "$(hat_json_string "$stamp")"
    hat_json_set "$worker_file" '.last_seq_changed_at' "$now"
    last_changed_at="$now"
  fi

  # ---- 豁免的時間上限（檔頭同名一節）：不看 status，從最早一筆仍未回
  #      覆的定案請求算起，超過 needyou_limit_seconds 就直接升級，不透
  #      過第 3 項的 state_change_seq 比對——等待中的 worker 可能持續轉
  #      換狀態，那套機制永遠不會判定它停滯 ----
  needyou_expired=0
  needyou_seq=""
  if [ "$needyou_pending" = "1" ]; then
    needyou_oldest="$(hat_wd_needyou_oldest_created_at "$registry_root" "$worker")"
    needyou_seq="$(printf '%s' "$needyou_oldest" | cut -f1)"
    needyou_created_at="$(printf '%s' "$needyou_oldest" | cut -f2)"
    if [ -n "$needyou_created_at" ]; then
      needyou_created_epoch="$(date -d "$needyou_created_at" +%s 2>/dev/null)" || needyou_created_epoch=""
      if [ -n "$needyou_created_epoch" ]; then
        needyou_wait_elapsed=$((now - needyou_created_epoch))
        if [ "$needyou_wait_elapsed" -ge "$needyou_limit_seconds" ]; then
          needyou_expired=1
        fi
      fi
    fi
  fi
  if [ "$needyou_expired" -eq 1 ]; then
    # ---- 獨立審查抓到的問題：升級的處置是叫 orchestrator 補一則帶
    #      --reply-to <序號> 的回覆，但這個序號原本拿不到——這則升級不
    #      經 report.sh，沒有那個帶序號的上行前綴可以切，摘要也只有等
    #      待秒數與上限；而 instruct.sh 的 --reply-to 在本次修正之前
    #      只檢查同名檔案存不存在，拿升級自己這筆記錄的序號去回覆會通
    #      過檢查、以 0 結束，被標成已處理的卻是升級記錄本身，真正的
    #      need-you 永遠停在未處理。上面已經為了算 needyou_wait_elapsed
    #      找出這筆最早未回覆的定案請求，順手把它的序號（needyou_seq）
    #      一併帶進摘要，讓 orchestrator 讀訊息就能直接照抄 --reply-to
    #      的值，不必自己去猜 ----
    hat_wd_escalate_once "$registry_root" "$orchestrator_name" "$worker" "$worker_file" \
      "needyou_expired" "$escalation_repeat_seconds" \
      "worker=$worker 有一則你還沒回的定案請求（need-you）已經等了 ${needyou_wait_elapsed}s（上限 ${needyou_limit_seconds}s），豁免到期，改為升級；回覆時請對 instruct.sh 帶 --reply-to $needyou_seq"
    return 0
  fi

  # ---- 2a：blocked 一律升級，不受 need-you 豁免與 .stage 守衛影響
  #      （見上方「修正迴圈第一輪」與檔頭「.stage 守衛」兩節）；不送文
  #      字下行給這個 worker；摘要一併帶出 .pending_resend 目前筆數，
  #      讓「有下行卡著」不是靜默的（見檔頭「升級」一節）。排在 3) 停滯
  #      偵測之前執行：兩者共用同一個去重閂鎖，先跑到的那個會讓另一個
  #      永久執行不到，該贏的是比較具體、帶著積壓筆數的這一則，不是先
  #      跑到的那一則（見上方「修正迴圈：blocked 升級搬到停滯偵測之
  #      前」一節）----
  if [ "$status" = "blocked" ]; then
    pending_resend_count="$(jq -r '(.pending_resend // []) | length' "$worker_file")"
    hat_wd_escalate_once "$registry_root" "$orchestrator_name" "$worker" "$worker_file" \
      "blocked" "$escalation_repeat_seconds" \
      "worker=$worker 卡在核准框（agent_status=blocked），文字下行會被拒絕，需要調查者讀畫面代按；目前有 ${pending_resend_count} 筆下行卡在待補送佇列"
    return 0
  fi

  # ---- 3：停滯偵測（見檔頭同名一節；豁免見「豁免」一節；受 .stage 守
  #      衛影響，見檔頭「.stage 守衛」一節，delivered／closing／closed
  #      時整段跳過不判斷）。status 不會是 blocked：上面的 2a 已經攔截
  #      並 return，case 因此不列 blocked（見上方「修正迴圈」一節）----
  if [ "$stage" = "running" ]; then
    case "$status" in
      idle | done | unknown)
        if [ -n "$last_changed_at" ]; then
          elapsed=$((now - last_changed_at))
          if [ "$elapsed" -ge "$stall_seconds" ] && [ "$needyou_pending" != "1" ]; then
            hat_wd_escalate_once "$registry_root" "$orchestrator_name" "$worker" "$worker_file" \
              "stall" "$escalation_repeat_seconds" \
              "worker=$worker 已停滯 ${elapsed}s（門檻 ${stall_seconds}s），狀態=$status，state_change_seq 沒有改變"
            return 0
          fi
        fi
        ;;
    esac
  fi

  # ---- unknown：不得自動推進，停滯門檻由上面的停滯偵測負責；這一輪
  #      確定沒有任何升級條件成立，清掉升級閂鎖（見檔頭「升級閂鎖清空
  #      的位置」一節）----
  if [ "$status" != "idle" ] && [ "$status" != "done" ]; then
    hat_wd_escalation_clear "$worker_file"
    return 0
  fi

  if [ "$held" = "true" ]; then
    hat_wd_escalation_clear "$worker_file"
    return 0
  fi

  # ---- 2b：達上限升級，同樣不受 need-you 豁免影響，因此先套用計數重
  #      置、算出目前計數，再判斷是否已達上限——這一步排在豁免檢查之
  #      前（見上方「修正迴圈第一輪」一節）；受 .stage 守衛影響（見檔
  #      頭「.stage 守衛」一節：worker 已經不會被推進時，「已達上限」
  #      這句話語意失效，指向一件不再發生的事）----
  hat_wd_apply_delivery_reset "$worker_file"
  auto_push_count="$(jq -r '.auto_push_count // 0' "$worker_file")"

  if [ "$stage" = "running" ] && [ "$auto_push_count" -ge "$auto_push_limit" ]; then
    hat_wd_escalate_once "$registry_root" "$orchestrator_name" "$worker" "$worker_file" \
      "auto_push_limit" "$escalation_repeat_seconds" \
      "worker=$worker 自動推進已達上限 ${auto_push_limit} 次仍是 $status，改為升級"
    return 0
  fi

  # 到這裡表示這一輪五個升級條件都沒有成立，清掉升級閂鎖（見檔頭「升
  # 級閂鎖清空的位置」一節）；後面的豁免跳過與自動推進兩條路徑都已經
  # 涵蓋在內，不必各自再清一次。
  hat_wd_escalation_clear "$worker_file"

  # ---- 豁免：等 need-you 回覆的 worker 不自動推進（只擋這一項，見上
  #      方「修正迴圈第一輪」一節）----
  if [ "$needyou_pending" = "1" ]; then
    return 0
  fi

  # ---- 1：自動推進（受 .stage 守衛影響，見檔頭同名一節：delivered／
  #      closing／closed 時 worker 依契約靜止是正常狀態，不推）----
  if [ "$stage" = "running" ]; then
    rc=0
    hat_herdr agent prompt "$worker" "繼續" >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      new_count=$((auto_push_count + 1))
      hat_json_set "$worker_file" '.auto_push_count' "$new_count"
      printf 'auto-push worker=%s count=%s at=%s\n' "$worker" "$new_count" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$registry_root/watchdog.log"
    fi
  fi
}

# hat_wd_run_once
# 跑一輪：一次 agent list、4a) inbox 上行重投（hat_wd_retry_blocked_
# inbox 內部逐筆記錄包子殼）、逐一處理每個已知 worker（本函式這裡逐筆
# worker 包子殼）。兩處都是失敗只跳過那一筆並記一行日誌，理由與
# `--once` 的語意見檔頭「單一 worker 的致命失敗不得帶走整個行程」、
# 「修正迴圈：hat_wd_retry_blocked_inbox 一樣要包子殼」與「`--once`
# 與長駐模式一律同樣處理」三節。`agent list` 本身失敗（線上故障修正新
# 增，見檔頭「線上故障修正新增之三」一節）不接住結束碼就會被 errexit
# 帶走整個長駐行程，因此改成失敗只記一行日誌並跳過這一輪其餘所有處理
# （含 4a 補投與逐一處理 worker），不呼叫 `hat_die`。
hat_wd_run_once() {
  local registry_root team_json orchestrator_name agents_json whitelisted worker rc

  registry_root="$(hat_registry_root)"
  team_json="$registry_root/team.json"
  orchestrator_name="$(jq -r '.orchestrator_name // empty' "$team_json" 2>/dev/null || true)"

  rc=0
  agents_json="$(hat_herdr agent list)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'skip reason=agent_list_failed rc=%s at=%s\n' "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$registry_root/watchdog.log"
    return 0
  fi
  whitelisted="$(hat_whitelist_agents "$agents_json")"

  # ---- 獨立審查 Critical：本呼叫內部兩處 .orchestrator_alert_active
  #      寫入落在函式主殼層，鎖逾時要包子殼接住 ----
  # `hat_wd_retry_blocked_inbox` 內「orchestrator 名稱查無」與「名稱恢
  # 復可查」兩個分支各有一次 `hat_json_set "$team_json" '.orchestrator_
  # alert_active' ...`，兩者都落在函式主殼層、不在該函式逐筆 inbox 記
  # 錄那層子殼保護範圍內（那層只包每一筆 `.delivery` 的寫入，見該函式
  # 檔頭「狀態轉換才寫 log」與「修正迴圈：hat_wd_retry_blocked_inbox 一
  # 樣要包子殼」兩節——這兩處是本次修正新增，那兩節寫成的當下還不存
  # 在）。裸呼叫底下，鎖逾時會讓 `hat_json_set` 以 `hat_die 5` 直接
  # `exit`，沒有任何子殼可接，會把整支 watchdog.sh 一併終止，比一次乾
  # 淨的失敗更糟。手法比照下面 `hat_wd_process_worker` 呼叫端既有先
  # 例：整次呼叫包進子殼接住結束碼，失敗只記一行 skip、不中止長駐迴
  # 圈；這裡選擇包整個呼叫，不是逐一堵這兩處 `hat_json_set`，因為兩者
  # 是同一次呼叫裡彼此互斥的分支（成立其中之一就會 `return`），失敗後
  # 沒有「跳過這一句、繼續走完整個函式」的中間語意，整次放棄最乾淨，留
  # 給下一輪重試。
  rc=0
  ( hat_wd_retry_blocked_inbox "$registry_root" "$orchestrator_name" "$whitelisted" ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'skip reason=retry_blocked_inbox_failed rc=%s at=%s\n' \
      "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$registry_root/watchdog.log"
  fi

  while IFS= read -r worker; do
    [ -n "$worker" ] || continue
    # 整次呼叫包進子殼：`hat_wd_process_worker` 底下任何一個 hat_die
    # （最常見的是 worker 記錄被 shutdown-worker.sh 移除後，寫入函式撞
    # 上目標檔已不存在而以 5 結束）只結束這個子殼，不會把長駐迴圈帶
    # 走。`|| rc=$?` 而不是裸呼叫：errexit 之下裸呼叫失敗會直接終止本
    # 行程，結束碼根本讀不到。stderr 不攔截，hat_die 的原始訊息照樣外
    # 流（見檔頭同名一節）。
    rc=0
    ( hat_wd_process_worker "$registry_root" "$orchestrator_name" "$worker" "$whitelisted" \
        "$stall_seconds" "$auto_push_limit" "$needyou_limit_seconds" \
        "$escalation_repeat_seconds" ) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'skip worker=%s reason=process_failed rc=%s at=%s\n' \
        "$worker" "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >> "$registry_root/watchdog.log"
    fi
  done < <(hat_worker_list)
}

if [ "$once" -eq 1 ]; then
  hat_wd_run_once
  exit 0
fi

while :; do
  hat_wd_run_once
  sleep "$poll_seconds"
done
