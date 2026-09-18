#!/usr/bin/env bash
#
# skills/herdr-agent-team/scripts/instruct.sh
#
# 用法：
#   instruct.sh --to <worker> (--text <文字> | --text-file <路徑>) \
#     [--reply-to <序號>] [--kind instruct|decision|goal-update|halt]
#
# 職責（規格 §9「怎麼送」、§12）：orchestrator 下行唯一入口，一次只送
# 給一個 worker。
#
# ---- 送之前把收件 worker 標成持有中，送完（不論成功、blocked 或其他
#      拒絕）都要放掉 ----
# 已實測的失敗形狀：兩則下行被併進同一個回合一起執行——一則「繼續」黏
# 在一則 goal 更新後面送達時，worker 讀到的是混合意圖，而兩則訊息都沒
# 有掉、從外面看起來一切正常。持有旗標的語意是「orchestrator 正在跟這
# 個 worker 對話」：看門狗（Task 12）看到它為真就不會自動推進，那個空
# 窗期就不會有第三則訊息插進來。本腳本因此在送出之前把 .held 設成
# true，並在所有離開路徑（成功、blocked、其他 herdr 拒絕、語法錯誤）
# 都放掉，不留任何一條會讓旗標卡在 true 的路徑。
#
# ---- 獨立審查抓到的問題：上面那句宣稱曾經被這次任務新增的兩次寫入打
#      破，靠 EXIT trap 補回來 ----
# 那句宣稱在只有一次 hat_json_set（直接寫 .held）的舊版是對的：每條離
# 開路徑都是「寫 false、再 exit」兩個連續動作，中間沒有第三個會
# hat_die 的呼叫插得進來。這次在「設 true」與「寫 false」之間新增了兩
# 次獨立加鎖的 hat_json_set（寫 .last_delivered_at、視情況撥回
# .stage，見下面兩節），任一步都可能因為等鎖逾時或 mktemp／jq／mv 失
# 敗而 hat_die 5——那是真正的 exit，會跳過緊接在後面那一行「放掉旗
# 標」，讓旗標卡在 true；那個 worker 的自動推進會被看門狗靜默關閉，直
# 到下一次成功的 instruct 或 team-init.sh --recover 收回為止，而下行
# 其實已經送達了。上面那句宣稱因此變成假的。
#
# 修法：改用 hat_instruct_release_held（定義見下方）當 EXIT trap，在
# 「設 true」之後立刻掛上；四條離開路徑各自成功寫回 false 之後立刻用
# held_pending=0 拆線，讓正常路徑不會被 trap 白跑一次。任何中途的
# hat_die（不論是今天寫得出來的兩個呼叫點，還是明天新增的第三個）都會
# 讓 held_pending 停在 1，由 trap 在行程真正離開前再補一次「放掉」。包
# 一層子殼是必要的：trap 裡再呼叫的 hat_json_set 一樣可能因為同一種原
# 因失敗、一樣是 hat_die，若不包子殼，它的 exit 會直接蓋掉原本正在傳
# 播的結束碼，讓呼叫端看到的是「補救寫入本身失敗」這個次要訊息，卻遺
# 失了真正觸發這次離開的原因；`|| true` 把補救失敗這件事本身變成無
# 聲，原始結束碼原封不動往外傳。這個補救不是萬能：worker_file 若在這
# 個空窗期被 shutdown-worker.sh 整筆移除，trap 裡的補救寫入一樣會因為
# 目標檔不存在而失敗——但那個情境下已經沒有一筆記錄可以「卡在 true」，
# 不算殘留的洞。只掛 EXIT，不疊加 INT／TERM：這兩個信號沒有專屬處理常
# 式時，預設處置本來就是終止行程並照樣觸發 EXIT trap；若額外幫它們各
# 自掛上同一個處理函式，而處理函式本身不呼叫 exit，反而會讓
# Ctrl-C／SIGTERM 被這個函式默默吃掉、行程繼續跑下去，是這裡不需要也
# 不該引入的行為改變。
#
# ---- 這個 trap 一開始寫出來其實不會作用：連帶在 lib/common.sh 修了一
#      個既有的鎖檔描述符洩漏 ----
# 已實測重現：只用上面這個 trap，配上一支只讓 .last_delivered_at 那次
# hat_json_set 失敗的 jq 樁，得到的是 trap 裡的補救寫入以「等鎖逾時
# （30s）」自己失敗、.held 依舊卡在 true。成因不在 trap 本身，是
# hat_json_set／_hat_pending_resend_apply 拿到鎖之後的失敗分支（
# mktemp／jq／mv／目標檔消失）原本都沒有主動關閉鎖檔描述符，指望行程
# 反正要 `exit` 了、OS 會自動收掉——但 EXIT trap 正是在行程真正結束之
# 前執行的，這個沒關閉的描述符此時仍然持鎖，trap 裡再對同一個檔案開新
# 描述符去搶鎖，等於在同一個行程裡排隊等自己放手的鎖，只會等到逾時。
# 已在 lib/common.sh 補上：兩個函式拿到鎖之後的四個失敗分支都先關閉描
# 述符才 hat_die，細節與理由見那兩處的說明。
#
# ---- 線上故障修正：自動推進計數的歸零時機 ----
# 看門狗（watchdog.sh）的自動推進計數（.auto_push_count）原本在 worker
# 回報 delivered 時歸零，這正是一個 livelock 的成因（worker 在
# delivered 關卡靜止是契約要求的正常狀態，卻被推進、推滿上限又被逼著
# 再回報一次 delivered，這一報又把計數歸零、重新開始推，見 watchdog.sh
# 檔頭「計數重置」一節）。正確的歸零時機只有一個：orchestrator 真的送
# 出了一則下行。lib/common.sh 欄位白名單那一節的寫入端分邊約定是「計
# 數類欄位由 watchdog.sh 維護」，本腳本不能直接去動 .auto_push_count；
# 因此本腳本成功送出下行時只寫它自己擁有的新欄位 .last_delivered_at
# （時間戳，但 --kind halt 是例外，不寫這個欄位，見下方「叫停不是續
# 杯」一節），watchdog.sh 讀到這個欄位跟自己的水位線不同時才去動自己
# 擁有的計數（見該腳本 hat_wd_apply_delivery_reset 的說明），維持寫入
# 端欄位集合不重疊這個約定。
#
# ---- 交付關卡的復工：.stage 是 delivered 時，成功送出下行要撥回
#      running（線上故障修正新增）----
# watchdog.sh 的三項照看（自動推進、停滯偵測、達上限升級）只在 .stage
# 是 running 時進行（見該檔檔頭「.stage 守衛」一節）；worker 回報
# delivered 之後，.stage 被交付流程設成 delivered，讓這三項照看安靜下
# 來——這是設計要的，worker 在這個關卡靜止不動是契約要求的正常狀態，
# 不是卡住。但沒有任何腳本會在 review 回饋進來、orchestrator 要它復工
# 時把 .stage 撥回 running：唯一的寫入端是 set-worker-field.sh，撥回
# 這件事需要 orchestrator 自己記得多下一個指令，一旦忘記，這個因為
# review 回饋被叫回去做事的 worker 會永遠停在 delivered，三項照看全部
# 關閉、靜默停住不會有任何人知道——這正是 .stage 守衛本身要消滅的失效
# 形狀，被守衛自己重新製造了一次。
#
# 修法：本腳本認定要送一則下行給某個 worker、且該 worker 當下的
# .stage 剛好是 delivered 時，就撥回 running——判準是「發出」，不是
# 「送達」：成功送達（rc=0）與進了待補送佇列（結束碼 7，對象卡在核准
# 框）都算數，讓復工變成機制、不依賴 orchestrator 記得多呼叫一支腳
# 本；語意上「orchestrator 決定要給這個 worker 新指令」就等於它該重
# 新開始做事，這件事在訊息進佇列的那一刻就已經成立，不因為還沒送到
# 而不成立。.stage 是 closing／closed 時不動它——那兩個關卡各自有自
# 己的收尾流程，本腳本不介入；.stage 是 running 或欄位不存在時本來
# 就不必動，維持現狀即可。lib/common.sh 欄位白名單一節把 .stage 分
# 配給「orchestrator 端腳本」，本腳本正是其中之一，這裡的寫入不破壞
# 分邊約定。
#
# ---- 為什麼判準不是送達：漂移處置第 3 步會直接撞到這條路徑 ----
# 初版判準是送達（只在 rc=0 撥回），理由是結束碼 7 只代表訊息進了待
# 補送佇列，還沒有人真的收到，撥回關卡似乎言之過早。但這個判準漏接
# 一個明文預期會發生的情境：漂移處置第 3 步要求對每個受影響的 worker
# 逐一叫停，而收件方卡在核准框正是本腳本結束碼 7 設計要處理的狀況；
# 若只在送達時撥回，一個只被這種被擋下的訊息「叫回」、之後再也沒有
# 下一次直接送達的 worker，會在看門狗補投成功之後仍然被排除在三項照
# 看之外——原地重建了這一節開頭要修的那個洞，只是換了個更窄的觸發路
# 徑。改成「發出即撥回」之後，這個殘餘缺口不再存在，也不需要讓
# watchdog.sh 在補投成功時額外去撥動 .stage（那會替它新增一個原本只
# 分配給 orchestrator 端腳本的欄位，重演這整條故障鏈的成因）。
#
# 兩個路徑各自呼叫同一個判斷（見下方 hat_resume_stage_on_issue），不
# 是各自重寫一份：復工的判斷邏輯只有一份，兩個呼叫點各自決定「這一輪
# 算不算發出」即可。語法錯誤（rc=2）與其他真正的拒絕（rc=6）不呼叫
# ——那兩者根本沒有一則真的要送給這個 worker 的訊息在路上，.stage 維
# 持原狀。
#
# ---- 叫停不是復工：--kind halt 不撥回關卡（獨立審查抓到的問題）----
# 上面「發出即撥回」的判準原本沒有排除 --kind halt：叫停一個 .stage
# 是 delivered 的 worker 一樣會被撥回 running，重新進入看門狗三項照看
# 的範圍。後果是漂移處置第 3 步逐一送出叫停之後，那個 worker 停手回
# 報、轉成閒置，看門狗會在下一個輪詢間隔開始送「繼續」，推滿上限又升
# 級——系統一邊叫它停手、一邊叫它繼續，正是「發出即撥回」原本要消滅的
# 失效形狀，換了個觸發路徑重新出現。一個剛被叫停的 worker 停著不動是
# 正確狀態，跟交付後待命同一個性質：它欠的是 orchestrator 的下一個新
# 指令，不是一句「繼續」；之後 orchestrator 真的送出新任務或新目標，
# 那一則的 --kind 不是 halt，才會撥回。
#
# 識別「這一則是叫停」的唯一依據是呼叫端帶 --kind halt：本腳本不會從
# --text 的文字內容猜測意圖，那會是本腳本自己發明一種文件沒有要求、
# 呼叫端不保證會帶的識別方式。--kind 已經是白名單裡的合法值、也已經
# 在 .pending_resend 記錄裡被當成訊息種類標記使用，是腳本層現成、只
# 差沒被用來影響行為的欄位。這表示呼叫端（含 SKILL.md 漂移處置第 3 步
# 的範例指令）必須明確帶 --kind halt 才能讓這個修法生效，不帶就會沿用
# 預設值 instruct、被判定成一般下行、照舊撥回 running——這個相依性回
# 報在任務報告，不由本腳本自行放寬判準去嘗試涵蓋沒帶這個旗標的呼叫。
#
# ---- 叫停不是續杯：--kind halt 成功送達也不寫 .last_delivered_at
#      （獨立審查抓到的問題）----
# 上面「叫停不是復工」只處理了 .stage 不被撥回，但成功送達（rc=0）分
# 支原本無條件寫 .last_delivered_at，--kind halt 沒有被排除在外。這個
# 欄位是 watchdog.sh 判斷「要不要把 .auto_push_count 歸零」的唯一依據
# （見上方「線上故障修正：自動推進計數的歸零時機」一節）；叫停不是下
# 發新任務，寫了它會被看門狗下一輪誤判成「orchestrator 剛送出一則新
# 下行」，把已經逼近上限的推進預算重新續杯到滿。更糟的是這會跟達上限
# 升級疊成一個不會終止的迴圈：worker 被推到上限、看門狗發出達上限升
# 級、orchestrator 收到後送出叫停試圖讓它停手，叫停本身卻又把預算續
# 杯，達上限升級因此永遠不會真的觸發——orchestrator 每叫停一次，系統
# 反而多送一輪「繼續」的資格。
#
# 修法：成功送達分支比照上面「叫停不是復工」的判準，--kind halt 時不
# 寫 .last_delivered_at。
#
# ---- 這只修掉「續杯」這一半，不是「叫停真的讓推進停下來」----
# 這個修正消滅的是「預算被重複續杯」，不是「看門狗還是會把已經叫停的
# worker 當成 idle 繼續推」本身——後者的成因是資料模型維度不足：
# .stage 只分辨「送達關卡」（running／delivered／closing／closed），
# 不記錄「orchestrator 最近一次下行的種類是不是叫停」，看門狗因此仍然
# 看不出這個 worker 剛被叫停，一樣會把它判成該推。這個缺口需要新增欄
# 位（例如「最近一次下行是不是 halt」）才能真正關掉，不是這次「不寫
# 一個時間戳」能解決的範圍，故意留給後續任務，這裡不順手擴大。
#
# 但修掉續杯這一半仍然把後果的形狀改了：沒有續杯，推進計數不會被打回
# 0 重來，原本「無限迴圈」的後果收斂成「最多把計數推到上限、達上限升
# 級真的觸發一次」——升級去重（見 watchdog.sh 檔頭「升級去重」一節）之
# 後不會每輪重複，但至少會讓 orchestrator 收到一次「這個 worker 已經
# 到上限」的通知，不再是永遠推不到升級的死迴圈。
#
# ---- 一律不握手 ----
# 收件的 worker 多半還在做事，對做事中的對象沒有任何短握手可用：已實
# 測帶著等待選項對一個做事中的 agent 送出，會在十秒後逾時、結束碼 1，
# 但訊息其實送到了、該回合結束後就執行了；不帶等待選項則要等完整個回
# 合，實測十二秒，真實情境是幾小時。照握手做的後果是每一則各逾時一
# 次、各誤判成失敗一次、各白派一個調查者。本腳本的投遞呼叫因此絕對不
# 加 --wait／--until／--timeout。
#
# ---- blocked 是待補送，不是失敗；其餘拒絕才是真正的失敗 ----
# herdr 會直接拒絕送給一個卡在核准框的對象（error.code=agent_blocked）。
# 這一則沒有送到，而外部世界沒有任何地方查得到「有一則該送而還沒送到
# 的下行」——它不寫進狀態記錄就等於不存在，後果是靜默的：那個 worker 永
# 遠不知道目標改過，繼續照舊的建東西，一路正常，直到整合時才炸。因此
# agent_blocked 時把這一則加進該 worker 的 pending_resend 清單、放掉持
# 有旗標，以 7 結束（不是失敗，是待補送）。
#
# 其餘拒絕（例如目標名稱根本不存在）不進待補送清單：那個目標可能永遠
# 不會離開拒絕狀態，進了清單只會讓看門狗（Task 12）每一輪都白補投一次
# 注定失敗的對象。因此不透過 hat_herdr——它把 herdr 結束碼 1 一律映射
# 成 6，會把「agent_blocked（待補送）」跟「其他真正的拒絕（同樣是 6，
# 但語意不同）」混成同一碼，本腳本需要在兩者之間分岔；沿用
# launch-worker.sh 對同一類問題的既有手法，自己擷取 stderr 解析
# error.code，不假手 hat_herdr。
#
# ---- .pending_resend 有兩個寫入端，兩者共用 common.sh 的單一加鎖 jq
#      轉換實作 ----
# 這一則加入清單由本腳本做，補投成功後移除那一則由看門狗（Task 12）
# 做，兩者是同一個欄位的兩個獨立寫入端。common.sh「寫入端分邊，欄位集
# 合刻意不重疊」那份分配表原本沒有把 .pending_resend 分配給任何一邊
# （這是計畫的疏漏，已在修正迴圈第一輪的裁決記錄），所以不重疊的約定
# 在它身上不成立，必須換一個保證：對它的每一次變動都表達成「一次
# flock 加鎖區間內完成的單一 jq 轉換」——讀現有內容與算新內容都在同一
# 次 jq 呼叫裡對來源檔案求值，不能先用一次 jq 呼叫把陣列讀出到 shell
# 變數、算完新陣列、再用 hat_json_set 另開一次加鎖呼叫寫回去。後者是兩
# 次獨立的加鎖呼叫，中間那個沒有鎖保護的空窗，剛好就是另一個寫入端
#（看門狗的移除）會插進來的地方；兩個方向的結果都是靜默的資料遺失，正
# 是規格 §13 講的「該送而還沒送到的下行，外部世界沒有任何地方查得到」
# 那件事。Task 12 的前置整理已把這個共用實作（`_hat_pending_resend_
# apply`）與加入／移除兩個入口（`hat_append_pending_resend`／
# `hat_remove_pending_resend`）一併移進 lib/common.sh，本腳本改為直接
# 呼叫共用函式庫的 `hat_append_pending_resend`，不再自己定義。
#
# ---- --reply-to：回覆定案，順手標記已處理 ----
# 上層重啟之後 context 全沒了，它收到過的訊息也一起沒了，所以「哪些上
# 行還沒處理」必須落在磁碟上。設計刻意不要求上層多呼叫一支標記腳
# 本——那是它會忘記做的事，改成讓標記從它本來就會做的動作掉出來：回覆
# 某則定案時順手標掉那一則。
#
# 這一步（寫 replies/<worker>/<seq>.json、標記
# inbox/<seq>-<worker>.json 的 processed_at）是純檔案系統操作，跟後面
# 這一則下行是否送達無關，因此排在投遞之前執行、且不受投遞結果影響：
# 就算後面的投遞被 blocked 甚至被拒絕，這則決議本身已經定案且已經
# durable 落地，report.sh 阻塞中的輪詢（直接檢查檔案是否存在，不經過
# herdr）能立刻讀到，不需要等這次投遞的結果。
#
# replies/ 底下每個檔案只會被本腳本寫入恰好一次（seq 全域唯一且單
# 調），但它有一個 details/ 沒有的性質：worker 端的 report.sh 正在主動
# 輪詢這個檔案是否存在，若這裡用一般的 `>` 直接寫、寫到一半失敗，會被
# 輪詢中的 worker 讀到一個殘缺檔案並當成正常回覆吃下去——比完全沒寫更
# 糟。因此改用 mktemp → jq 產生內容 → mv 置換的三步，跟 hat_json_set／
# hat_allocate_seq 對「有並行讀者」的檔案的既有處理方式一致；details/
# 沒有這個並行讀者，才維持 report.sh 原本較簡單的 cp 寫法，兩者的落
# 差是刻意的，不是遺漏。
#
# ---- 一次只接受一個收件人 ----
# goal 傳播時，每個角色收到的是「這次改動對你這一份的影響」，不是整段
# 變更紀錄；收件端是 worker，它只看得到自己那個角色，判不出哪一段跟自
# 己有關。逐一送，由呼叫端（orchestrator）對每個受影響的角色各呼叫一
# 次，本腳本的 --to 因此只接受單一個名稱。
#
# ---- 入口守衛：hat_assert_workspace 用在既有 target 上 ----
# 本腳本接受呼叫端傳入的既有 target（worker 已註冊的座標），不像
# launch-worker.sh 自己建立新座標；套用方式沿用 skills/epic-
# orchestration/scripts/send-to-phase.sh 對同一類「既有 target」的既有
# 手法：從 registry 讀出這個 worker 的 pane_id，對它斷言屬於本
# workspace，早於任何 herdr 呼叫。三道 workspace 守衛裡唯一擋得住「誤
# 觸別的 team 的 worker」的一道。
#
# ---- --to 的名稱格式驗證（全域約束）----
# --to 會被直接用來組 `workers/<--to>.json`、`inbox/<--reply-to>-
# <--to>.json`、`replies/<--to>/` 這幾條 registry 路徑；含斜線或上層
# 目錄記號的值可以組出跳脫 registry 根目錄的路徑，因此必須先驗過
# herdr agent 名稱正規表示式（`^[a-z][a-z0-9_-]{0,31}$`）才能使用，不
# 合格式的以 2 結束（呼叫端用錯，不是守衛不通過）。沿用 press-
# approval.sh 已經在用的 hat_assert_agent_name，定義在 lib/common.sh。
#
# ---- --kind 是下行訊息的種類標記，跟 provider 的 agent kind 是完全不
#      同的命名空間 ----
# hat_assert_supported_kind／hat_kind_fidelity 判斷的是 claude／codex／
# agy／opencode 這四種 CLI provider；這裡的 --kind（instruct／
# decision／goal-update／halt）標記的是這一則下行訊息本身的種類，目前
# 影響四處：(a) 白名單外一律拒絕；(b) 進 pending_resend 清單時一併記
# 錄，供 Task 12 的看門狗補投時知道這是哪一種訊息；(c) 成功送出下行時
# 是否撥回 .stage；(d) 成功送達時是否寫 .last_delivered_at——(c)(d) 都
# 是 halt 的例外，理由分別見下方「叫停不是復工」與「叫停不是續杯」兩
# 節，這裡不重複。不影響送出的文字內容本身——文字內容一律是
# --text／--text-file 給的原文，本腳本不替四種 kind 分別組不同格式的
# 訊息（規格與可觸及的任務簡報都沒有規定 worker 端要怎麼從純文字辨識
# kind；這是本次實作的判斷，回報見任務報告）。

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

hat_require_herdr_env

# hat_json_string <text>
# 把任意文字安全地轉成一個 JSON 字串字面並印出來。用法與理由同
# report.sh／set-goal.sh／launch-worker.sh 的同名局部函式：各腳本各自
# 獨立定義，不共用（理由見 set-goal.sh 檔頭）。
hat_json_string() {
  jq -Rn --arg v "$1" '$v'
}

# hat_resume_stage_on_issue <worker_file> <kind>
# 見檔頭「交付關卡的復工」與「叫停不是復工」兩節：<worker_file> 的
# .stage 剛好是 delivered 時撥回 running。兩個呼叫點共用同一份判斷
# （成功送達的 rc=0 分支、進待補送佇列的 agent_blocked 分支），判準都
# 是「這一輪認定要發出一則下行給這個 worker」，不是「送達」——但
# <kind> 是 halt 時例外，整段不動 .stage：叫停不是復工。
hat_resume_stage_on_issue() {
  local worker_file="$1" kind="$2" current_stage
  [ "$kind" = "halt" ] && return 0
  current_stage="$(jq -r '.stage // empty' "$worker_file")"
  if [ "$current_stage" = "delivered" ]; then
    hat_json_set "$worker_file" '.stage' "$(hat_json_string running)"
  fi
}

# hat_instruct_release_held
# EXIT trap，見檔頭「獨立審查抓到的問題：上面那句宣稱曾經被這次任務新
# 增的兩次寫入打破，靠 EXIT trap 補回來」一節。<held_pending> 是本腳
# 本的全域旗標：成功把 .held 設成 true 之後為 1，四條離開路徑各自成功
# 寫回 .held=false 之後改回 0。trap 只在還是 1（代表還沒確認放掉）時
# 動作，其餘情況是安全的無動作，不會在正常路徑上多做一次無謂的寫入。
hat_instruct_release_held() {
  [ "$held_pending" -eq 1 ] || return 0
  # 包子殼＋忽略結束碼：這一步本身失敗也不得覆寫原本正在傳播的結束
  # 碼，理由見檔頭同名一節。
  ( hat_json_set "$worker_file" '.held' 'false' ) || true
}

to="" text="" text_file="" reply_to="" kind="instruct"
have_to=0 have_text=0 have_text_file=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --to)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --to 缺值"
      to="$2"; have_to=1; shift 2 ;;
    --text)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --text 缺值"
      text="$2"; have_text=1; shift 2 ;;
    --text-file)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --text-file 缺值"
      text_file="$2"; have_text_file=1; shift 2 ;;
    --reply-to)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --reply-to 缺值"
      reply_to="$2"; shift 2 ;;
    --kind)
      [ "$#" -ge 2 ] || hat_die 2 "instruct.sh: --kind 缺值"
      kind="$2"; shift 2 ;;
    *)
      hat_die 2 "instruct.sh: 未知參數 '$1'" ;;
  esac
done

if [ "$have_to" -ne 1 ]; then
  hat_die 2 "instruct.sh: --to 為必填"
fi
# --to 的名稱格式驗證，見檔頭「--to 的名稱格式驗證」一節。早於任何
# registry 路徑組裝。
hat_assert_agent_name "$to"

if [ "$have_text" -eq 1 ] && [ "$have_text_file" -eq 1 ]; then
  hat_die 2 "instruct.sh: --text／--text-file 只能擇一"
fi
if [ "$have_text" -ne 1 ] && [ "$have_text_file" -ne 1 ]; then
  hat_die 2 "instruct.sh: --text／--text-file 必須擇一"
fi

if [ -n "$reply_to" ]; then
  case "$reply_to" in
    '' | *[!0-9]*)
      hat_die 2 "instruct.sh: --reply-to 必須是純數字序號，收到：$reply_to" ;;
  esac
fi

# ---- --kind 白名單：見檔頭「--kind 是下行訊息的種類標記」一節 ----
case "$kind" in
  instruct | decision | goal-update | halt) : ;;
  *) hat_die 2 "instruct.sh: 不支援的 --kind '$kind'：只接受 instruct、decision、goal-update、halt 四個" ;;
esac

if [ "$have_text_file" -eq 1 ]; then
  [ -f "$text_file" ] || hat_die 2 "instruct.sh: --text-file 指向的檔案不存在：$text_file"
  text="$(cat "$text_file")"
fi

registry_root="$(hat_registry_root)"
worker_file="$registry_root/workers/$to.json"

# ---- 入口守衛：對這個既有 target 的座標斷言屬於本 workspace，早於任
#      何 herdr 呼叫（見檔頭「入口守衛」一節）----
pane_id="$(hat_json_get "$worker_file" '.pane_id')"
hat_assert_workspace "$pane_id"

# ---- --reply-to：回覆定案並順手標記已處理，早於投遞、不受投遞結果影
#      響（見檔頭「--reply-to」一節）----
if [ -n "$reply_to" ]; then
  inbox_file="$registry_root/inbox/${reply_to}-${to}.json"
  if [ ! -f "$inbox_file" ]; then
    hat_die 5 "instruct.sh: --reply-to 指名的 inbox 記錄不存在：$inbox_file"
  fi

  # ---- 獨立審查抓到的問題：--reply-to 必須指向一筆還沒被回覆的定案請
  #      求，不是隨便一筆同名檔案 ----
  # 看門狗升級落的 inbox 記錄（token=fyi）跟真正的 need-you 定案請求
  # 檔名形狀完全一樣（都是 <序號>-<worker>.json），單靠檔案存不存在擋
  # 不住把升級的序號當成 --reply-to 送進來——那一筆一樣會通過檢查、以
  # 結束碼 0 成功，但被標成已處理的是升級記錄本身，真正該回覆的
  # need-you 永遠停在未處理，watchdog.sh 的豁免與 shutdown-worker.sh
  # 的關閉檢查都繼續卡住，而且全程沒有任何錯誤訊息。已經被回覆過的
  # need-you（.processed_at 不再是 null）同理排除，避免序號打錯打到舊
  # 的一筆、或同一筆被回覆兩次。結束碼沿用上面幾行同一個 5（registry
  # 缺漏或內容不合法）：目標記錄存在，但內容不符合這次操作要求的形
  # 狀，跟「檔案根本不存在」是同一類問題，不是呼叫端的參數格式錯誤
  # （2）也不是 herdr 拒絕（6）。
  #
  # ---- 這兩次 jq -r 明確接住失敗，不依賴它的結束碼、也要有診斷訊息
  #      ----
  # inbox_file 內容若不是合法 JSON，jq 求值失敗；改成 `if ! var=...`
  # 明確接住，理由有二：一、jq 的結束碼不是這個專案跟外部工具之間的契
  # 約，換版本、換實作都可能改變它的值，不能讓 --reply-to 這條路徑的
  # 結束碼語意繫在一個不受本專案控制的行為上；二、原本的裸賦值就算真
  # 的因為 errexit 中止，也不會印出任何指名是哪個檔案壞掉的訊息，排查
  # 時只看得到一個結束碼。這裡沿用本腳本其餘位置（hat_json_get／
  # hat_json_set）遇到 registry 內容不合法一律用的 5。
  if ! reply_target_token="$(jq -r '.token // empty' "$inbox_file" 2>/dev/null)"; then
    hat_die 5 "instruct.sh: --reply-to 指名的 inbox 記錄無法解析（可能不是合法 JSON）：$inbox_file"
  fi
  if ! reply_target_processed="$(jq -r '.processed_at' "$inbox_file" 2>/dev/null)"; then
    hat_die 5 "instruct.sh: --reply-to 指名的 inbox 記錄無法解析（可能不是合法 JSON）：$inbox_file"
  fi
  if [ "$reply_target_token" != "need-you" ] || [ "$reply_target_processed" != "null" ]; then
    hat_die 5 "instruct.sh: --reply-to 指名的記錄不是一筆還沒被回覆的定案請求（token=$reply_target_token processed_at=$reply_target_processed）：$inbox_file"
  fi

  reply_dir="$registry_root/replies/$to"
  mkdir -p "$reply_dir"
  reply_file="$reply_dir/$reply_to.json"
  tmp_reply="$(mktemp "${reply_file}.XXXXXX")" || hat_die 5 "instruct.sh: 無法建立暫存檔，回覆未寫入：$reply_file"
  if ! { jq -n --arg d "$text" '{decision: $d}' > "$tmp_reply" && mv "$tmp_reply" "$reply_file"; }; then
    rm -f "$tmp_reply"
    hat_die 5 "instruct.sh: 回覆檔寫入失敗：$reply_file"
  fi

  processed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  hat_json_set "$inbox_file" '.processed_at' "$(hat_json_string "$processed_at")"
fi

# ---- 送之前設持有旗標，並掛一個 EXIT trap 保底（見檔頭「送之前把收
#      件 worker 標成持有中」與「獨立審查抓到的問題」兩節、以及上方
#      hat_instruct_release_held 的說明）----
held_pending=0
trap hat_instruct_release_held EXIT
hat_json_set "$worker_file" '.held' 'true'
held_pending=1

# ---- 投遞：不透過 hat_herdr，理由見檔頭「blocked 是待補送」一節 ----
rc=0
if err_output="$(herdr agent prompt "$to" "$text" 2>&1 >/dev/null)"; then
  :
else
  rc=$?
fi

if [ "$rc" -eq 0 ]; then
  # ---- 成功送出下行：寫 .last_delivered_at，但 --kind halt 例外，不
  #      寫這個欄位（見檔頭「線上故障修正：自動推進計數的歸零時機」與
  #      「叫停不是續杯」兩節）----
  if [ "$kind" != "halt" ]; then
    hat_json_set "$worker_file" '.last_delivered_at' "$(hat_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  fi

  # ---- 交付關卡的復工：見檔頭「交付關卡的復工」與「叫停不是復工」
  #      兩節 ----
  hat_resume_stage_on_issue "$worker_file" "$kind"

  hat_json_set "$worker_file" '.held' 'false'
  held_pending=0
  exit 0
fi

error_code="$(printf '%s' "$err_output" | jq -r '.error.code // empty' 2>/dev/null || true)"
error_message="$(printf '%s' "$err_output" | jq -r '.error.message // empty' 2>/dev/null || true)"
[ -n "$error_code" ] || error_code="unknown_error"
[ -n "$error_message" ] || error_message="(herdr 未提供可解析的錯誤訊息)"

if [ "$rc" -eq 2 ]; then
  hat_json_set "$worker_file" '.held' 'false'
  held_pending=0
  hat_die 2 "instruct.sh: herdr 以結束碼 2 拒絕 agent prompt，疑似腳本呼叫語法錯誤（worker=$to）：code=$error_code message=$error_message"
fi

if [ "$error_code" = "agent_blocked" ]; then
  # ---- agent_blocked：進待補送清單，不是失敗（見檔頭「blocked 是待補
  #      送」與「.pending_resend 有兩個寫入端」兩節）----
  hat_append_pending_resend "$worker_file" "$text" "$kind"

  # ---- 交付關卡的復工：見檔頭「交付關卡的復工」「為什麼判準不是送
  #      達」與「叫停不是復工」三節——進待補送佇列也算「發出」，一併撥
  #      回，但 --kind halt 例外 ----
  hat_resume_stage_on_issue "$worker_file" "$kind"

  hat_json_set "$worker_file" '.held' 'false'
  held_pending=0
  printf '已記錄、待補送：worker %s 目前卡在核准框，看門狗會在它離開 blocked 後自動補投，但沒有任何機制會讓它自己離開，需要你去處理那個框（讀畫面判讀後呼叫 press-approval.sh）\n' "$to"
  exit 7
fi

# ---- agent_blocked 以外的拒絕：真正的失敗，不進待補送清單（見檔頭
#      「blocked 是待補送」一節）----
hat_json_set "$worker_file" '.held' 'false'
held_pending=0
hat_die 6 "instruct.sh: herdr 拒絕 agent prompt（worker=$to）：code=$error_code message=$error_message"
