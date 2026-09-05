---
name: epic-orchestration
description: >
  當使用者要開始或持續推進一個已經拆成 parent issue 與多個 sub-issue 的 epic feature 時觸發，
  例如指示啟動或監控某個 phase、回報某個 phase 卡住要怎麼處理並繼續、或宣布某個 phase 的 PR
  可以合併。判斷依據是客觀事實：GitHub 上已存在對應的 parent issue 與其下的 sub-issue，且使用者
  的請求指向「往下推進」而非單純查看。不觸發：單一 issue 的一般開發（未曾拆成 parent 加
  sub-issue）；只是查詢某個 epic 或 sub-issue 目前的進度、狀態或清單，而未要求採取任何推進
  動作；epic 的設計討論階段（改用 epic-design skill）。觸發關鍵字：推進這個 epic、啟動下一個
  phase、epic orchestration、phase 派工、監控 phase 進度並繼續、這個 phase 的 PR 可以合併了。
---

# Epic Orchestration

觸發本 skill 後，當前對話的 AI agent 在這個 epic 的整個生命週期內扮演 orchestrator：把每個
phase 交給一個獨立的 Claude Code session（下稱 phase agent）去完成，自己不參與任何一個 phase
的開發。此 skill 與既有 `epic-design` skill 成對：`epic-design` 產出設計文件，本 skill 負責
把設計拆成的 phase 推到全部合併。

## Reference 載入時機

| Reference | 載入時機 |
| --- | --- |
| `references/phase-agent-contract.md` | 本 skill 自己不載入。它由開場指令以絕對路徑傳給 phase agent，由 phase agent 自行讀取；orchestrator 只有在要修改 phase agent 的行為約束本身時才打開它 |
| `references/rationale.md` | 本 skill 自己不載入。撞到反常症狀時才打開對照，例如 phase agent 啟動時卡住不動、跨 session 訊息送不到或沒有回應、phase agent 讀不到 epic 設計文件、由 issue 查不到對應的 PR |

## 環境前提

orchestrator 必須跑在 herdr 環境下：進入本流程任何動作之前，先確認環境變數 `HERDR_ENV` 恰為
`1`。不是就停下，向使用者說明本流程要透過 herdr 開 tab、啟動與監控 phase agent，必須在 herdr
環境內執行，不要往下建依賴圖或詢問要推進哪個 phase。

自我檢測：`HERDR_ENV` 讀到的值是不是字面上的 `1`？不是的話就停在這一步，不要假設環境等同可用。

## Orchestrator 的職責

orchestrator 的職責只有三件：把每個 phase agent 成功啟動、監控整個 epic 各 phase 的進度、
phase 結束後把它關掉。決策轉遞（把 phase agent 的決策請求或卡住的核准框轉交使用者、再把使用者
的決定轉達回去）屬於監控的一部分，不是獨立的第四件事——它是「監控進度」在遇到卡點時的具體
展開，不代表 orchestrator 要介入開發判斷本身。

## 進度表

orchestrator 對整個 epic 的認知，全部收斂在一張進度表裡，每個 phase（即每個 sub-issue）在表
上只有六個欄位：

| 欄位 | 說明 |
| --- | --- |
| sub-issue 編號與標題 | 這個 phase 對應的 GitHub sub-issue |
| 被哪些 phase 擋著 | 依 blocked by 關係列出的依賴 |
| 目前處在哪個關卡 | 例如：等待啟動、進行中、等待決策、PR ready、已合併、已收尾 |
| herdr 座標 | tab 識別碼、agent 名稱、session 位址 |
| worktree 路徑 | 該 phase 的 git worktree 絕對路徑 |
| PR 編號 | 該 phase 開出的 PR，尚未開時留空 |

表上容不下開發細節：只要不是這六個欄位能表達的東西（例如某個函式重構完了、某段測試現在過
了），就不屬於 orchestrator 需要記住或轉述的內容。

## 主 Context 的三條硬禁令

orchestrator 的主 context 受三條硬禁令約束：

1. 不使用任何會回傳模型產出文字的 herdr 指令或欄位。已知例示為 `herdr agent read`、
   `herdr pane read`，以及 `herdr agent list` 回應中的 `terminal_title` 與
   `terminal_title_stripped` 欄位。
2. 不讀 phase 的程式碼、diff、測試輸出或 PR review 內容。
3. 不修改任何 phase worktree 裡的檔案。

判準是該指令或欄位回不回傳模型產出的文字，或該操作是否觸及 phase 的開發內容，而不是有沒有被
列在上面的清單裡——清單只是已知例示，不是窮舉；日後新增的任何承載模型輸出的欄位或指令，一樣
落在第一條禁令底下。

這三條沒有 permission 設定或 hook 在背後強制執行——orchestrator 本身具備呼叫這些 herdr 指令
的能力，技術上執行得到任何一條被禁止的操作；邊界完全靠這份定義檔的文字對模型的約束力生效，
不是被系統擋下的。正因為沒有機制兜底，這三條禁令的措辭不放寬。

這三條只綁 orchestrator 自己的主 context，不綁 `phase-decision-investigator`：調查者存在的
目的正是把 orchestrator 不能看的東西全部看完，只把結論帶回來，它的職責範圍見它自己的定義檔。

自我檢測：我準備使用的這個 herdr 指令或欄位，回不回傳模型產出的文字？我準備讀的這份內容，是
不是 phase 的程式碼、diff、測試輸出或 PR review？答案是「是」或「不確定」，就不要做。

## 啟動階段

使用者提供 parent issue 後，orchestrator 委派 `github-manager` 依序取得 parent issue 內
文、其下的 sub-issue 清單，以及每個 sub-issue 的 blocked by 關係，據此建出依賴有向圖與初始
進度表。

所有經由 `gh` 對 GitHub 的操作，含唯讀查詢，一律委派 `github-manager`；orchestrator 不自行
呼叫 `gh`。

建表之後，sub-issue 的 `state` 與 PR 的合併狀態就是進度的權威來源——後續任何關於某個 phase
完成到什麼程度的判斷，都以這兩者為準，不是以狀態檔或記憶中的印象為準。

## 派工階段

對每個沒有未完成依賴的 phase，orchestrator 依序做以下動作：

1. 先 fetch `origin/main`，再於倉庫內的 `.worktrees` 目錄底下建立該 phase 的 worktree。先
   fetch 這一步不可省略：省略的話，worktree 會是從尚未更新的本地 main 拉出來的，一開始就
   落後。
2. 在 orchestrator 自己所在的 workspace 開一個 tab：cwd 指向該 worktree、帶 `no-focus`、
   label 帶 sub-issue 編號。開 tab 時必須顯式指定 workspace 識別碼——省略時落點會取當下使用
   者介面焦點所在的 workspace，不一定是 orchestrator 自己所在的那個。
3. 在該 pane 啟動 kind 為 `claude` 的 agent。啟動時不帶權限模式旗標，讓 phase agent 繼承使
   用者現有的權限設定；但要帶 `add-dir` 旗標指向 epic 設計文件所在目錄，理由見下方「開場
   指令」一節。herdr 傳遞原生參數給 agent 的方式，是在 `herdr agent start` 指令的 `--` 之
   後接續原生參數。
4. 啟動時要給這個 agent 一個名稱，格式為 `phase-` 接 sub-issue 編號（例如 `phase-123`）。
   該名稱必須在存活的 agent 之間唯一，且形式限制為開頭一個小寫英文字母，其後最多三十一個
   字元、只能是小寫英文字母、數字、底線或連字號。
5. 確認啟動成功（見下方「啟動成功判準」）之後才送出開場指令。

上面涉及的 herdr 旗標（workspace 識別碼、`no-focus`、`add-dir`、agent 名稱與 kind、`--` 之
後接續原生參數）是已知存在的能力，但確切的旗標名稱與語法以呼叫當下該子命令自己的 `--help`
或不帶參數的輸出為準，不要照記憶湊。

自我檢測：這五個動作的順序有沒有被打亂，尤其是 fetch 是不是排在建立 worktree 之前、啟動成功
判準是不是排在送出開場指令之前？順序錯了就先停下重來，不要將錯就錯往下做。

### 啟動成功判準

`herdr agent get` 回應的三項要齊備才送出開場指令：

- `agent_status` 為 `idle`
- `launch_pending` 不為真——這個欄位不保證出現：對一個剛啟動完成、已就緒的 agent 下
  `herdr agent get`，回應裡根本查不到 `launch_pending`，不是查到它的值為 `false`；已實測到
  的另一種情形是，卡在信任對話框時這個欄位存在且為 `true`。因此欄位缺席一樣算
  「不為真」，不要因為查不到這個欄位就以為要停下查明
- `interactive_ready` 為真

三項不齊備時停下查明：查明的具體動作是委派 `phase-decision-investigator` 讀那一格 pane、
回報卡在什麼上面——這正是下方「決策迴圈」入口二會用到的同一條路徑，此處是 orchestrator 在
phase agent 報到之前提前用到它，不是要 orchestrator 自己去讀 pane。不得對著一個卡住的畫面
送出開場指令——那段文字會被打進核准框，而且不會有任何錯誤訊息提示這件事發生過。查明結果是
卡在信任對話框（workspace 信任提示），停下問使用者要不要信任這個目錄，不代按；查明結果是其
他情形，比照下方「失敗行為」一節，把觀測到的情況據實回報使用者、由使用者決定，orchestrator
不自行處置。

自我檢測：這三項是不是同時為真？只要有一項答否或答不出來，就不送開場指令。

### 開場指令

開場指令只帶四項：

1. sub-issue 編號
2. epic 設計文件的**主倉庫**絕對路徑
3. orchestrator 自己的 session 名稱
4. `phase-agent-contract.md` 的絕對路徑

設計文件必須給主倉庫絕對路徑，不能給 worktree 內的路徑：本倉庫的 `.gitignore` 忽略整個
`docs` 目錄，被忽略的檔案不會隨 git worktree 出現，phase agent 若拿到 worktree 內的路徑會
讀不到這份文件；這也是上一節要求啟動時帶 `add-dir` 旗標指向設計文件所在目錄的理由。

orchestrator 取得自己 session 名稱的方式是呼叫 `ListAgents` 工具，其回應第一行會指出當前
session 的名稱；這個名稱就是其他 session 用來定址它的位址，直接使用，不必另外查找或猜測。

契約全文由 phase agent 自己讀取 `phase-agent-contract.md`，不經開場指令的指令列傳遞。

### phase agent 報到

phase agent 收到開場指令後的第一個動作是送出報到訊息。orchestrator 從報到訊息的
`from-name` 取得它的 session 位址，寫進進度表的 herdr 座標欄位。

## 通訊協定

下行與上行走不對稱的機制，各取該方向最可靠的。

下行，從 orchestrator 到 phase agent，走 `herdr agent prompt`：它帶有 `agent_blocked` 檢
查，對方正卡在核准框時會明確拒絕，不會把指令打進一個沒人讀的畫面。唯一例外是回答核准框本
身，那要用 `herdr agent send-keys` 代按使用者選定的選項。

上行，從 phase agent 到 orchestrator，走跨 session 訊息（`cross-session-message`）：它是主
動推送，orchestrator 不必輪詢就能收到。

phase agent 唯一能主動送出的訊息只有以下四種，名稱與欄位的實質內容須與
`phase-agent-contract.md` 一致；用字依讀者視角調整——下表「決策請求」欄位在契約檔對 phase
agent 是「你的推薦」，此處改寫為第三人稱，避免在 orchestrator 視角下被誤讀成自己的推薦：

| 訊息 | 帶的欄位 |
| --- | --- |
| 報到訊息 | phase 編號、自己的 session 位址 |
| 決策請求 | 問題、已經試過什麼、選項與各自後果、phase agent 的推薦 |
| PR ready | PR 編號、一句話結論 |
| 收尾完成 | 一句話 |

收到不屬於這四種的訊息內容時，不要當成又一種新格式接受，先懷疑契約有沒有被遵守（見
`references/rationale.md` 待驗證假設一節）。

## 監控節奏

上一節的上行機制是主動推送，但 phase agent 卡在核准框時不會送任何訊息（不在四種之內），這
種情況只能靠 orchestrator 主動觀測 `agent_status` 才能發現，即下方「決策迴圈」入口二的來
源。orchestrator 用以下節奏維持觀測：對進度表上每一個目前在跑（非等待
決策、非等待啟動、非 PR ready）的 phase，逐一呼叫 `herdr agent wait <agent 名稱> --until
blocked --timeout <單次逾時毫秒>`；這個呼叫會阻塞到逾時或狀態變成 `blocked` 為止，逾時就換
下一個 phase，狀態變成 `blocked` 就立刻進入決策迴圈入口二。每呼叫完一個 phase，先處理這段期
間累積的任何上行訊息（入口一，或報到、PR ready、收尾完成），再輪到下一個 phase；如此循環，
讓「等待上行訊息」與「輪流觀測 blocked」共用同一個迴圈，不各自獨立跑。PR ready 的 phase 是
依設計閒置等 review，不落在這個觀測集合裡，否則每一輪都會白白吃掉一次逾時。orchestrator 阻
塞在某一個 phase 的這次等待時，其他 phase 推來的訊息要等這次呼叫結束才處理得到，這是這個機
制本身的代價。

整輪觀測（依序對目前在觀測的每個 phase 各呼叫一次 `herdr agent wait`）訂一個牆鐘上限：
60000 毫秒（60 秒）。單次逾時毫秒 = 這個上限除以目前在觀測的 phase 數，讓整輪的總阻塞時間
不隨 phase 數增加而拉長。`--until` 可接受的其他值，以呼叫當下該子命令自己的 `--help` 為
準，不要照記憶湊。

自我檢測：進度表上正在跑的每一個 phase，是不是都在最近一輪迴圈裡被 `herdr agent wait` 觀測
過？漏掉任何一個，入口二對那個 phase 就形同不存在。

## 決策迴圈

決策迴圈有兩個入口，出口只有一個。

- 入口一：phase agent 主動送出決策請求。
- 入口二：它撞到權限提示或核准框而進入 `blocked`，orchestrator 從上一節「監控節奏」的迴圈觀
  測中看得到狀態，但看不到提示內容。

兩個入口併入同一條路徑：

1. 委派 `phase-decision-investigator` 做完整調查。依它自身定義檔 `Input from Main Agent`
   一節提供：sub-issue 編號、該 phase worktree 的絕對路徑、herdr 座標中的 tab 識別碼與
   agent 名稱、觸發本次調查的具體事由（入口一給 phase agent 送出的原文——問題、已經試過什
   麼、選項與後果、推薦；入口二給「`agent_status` 轉為 `blocked`」這個事實本身即可，原因
   由它自行讀 pane 查明）、該 phase 已開 PR 時的 PR 編號。可選提供已知的相關背景，以及
   epic 設計文件的主倉庫絕對路徑。不需要（且依「主 Context 的三條硬禁令」也不能）額外提供
   codebase 內容、git log、diff、pane 畫面內容或 PR review 留言本身——那些原本就是調查者自
   己會去讀的部分。
2. 把 phase agent 的原文請求與調查者的分析兩份並列呈給使用者，不得只給分析結果——調查者可
   能誤判，並列才讓使用者有機會發現分析讀歪了。
3. 使用者決定後，orchestrator 把決定轉達回該 phase agent。這是兩個入口共同的唯一出口。

轉達形式依入口而異：入口一（一般決策請求）走 `herdr agent prompt`；入口二（卡在核准框）用
`herdr agent send-keys` 代按使用者選定的那個選項。

自我檢測：呈給使用者的內容，是不是同時包含 phase agent 的原文與調查者的分析？只給其中一項就
不完整，不能送出。

使用者的決定若代表 epic 設計文件的某個假設被推翻，轉達給發起請求的這個 phase agent 還不夠。
「推翻」的判準是：照設計文件原本的敘述做會失敗、或產生與所述不同的結果；「有更好的做法」不
算推翻，那是優化提案，不觸發以下處置。假設確實被推翻時，判斷設計文件哪些內容因此過時只能
依據該 phase 的決策請求原文與調查者分析，不得讀 phase 的程式碼、diff 或 pane 畫面；然後
orchestrator 要更新設計文件本身，並以該假設的關鍵詞搜過設計文件全文，找出依賴同一假設的其他
phase——已經在跑的通知它假設已更新，尚未派工的確保派出時讀到的是更新後的內容。`plan-integrity` rule 把這個義務放在編
排端：唯有 orchestrator 同時知道這個 epic 有哪些 phase、各自處在哪個關卡，能修設計文件的是
它，先撞到被推翻假設的卻是提出請求的那個 phase agent，訊號不主動處理就傳不到其他 phase。判
斷是否處理完畢的方式是重跑同一組搜尋，剩下的命中全部落在已更新的敘述上；仍命中舊敘述就是未
完成。

自我檢測：這次決定牽涉的假設，是不是已經搜過設計文件全文找出所有依賴它的 phase，且在跑與尚
未派工的都各自處理過？漏了任一步就還沒完成。

## PR Ready 的處置

phase agent 送回 PR 編號與一句話結論後，orchestrator 只記下 PR 編號、不讀 PR 內容，回報給
使用者。該 phase 的 tab 保持開啟——review 可能要求改動，phase agent 還要回去做。

使用者若要求某個 phase 修改，orchestrator 透過下行機制（`herdr agent prompt`）把修改要求轉
達給該 phase agent；phase agent 改完後會重新送來一則「PR ready」訊息——這是既有第三種訊息
的重複使用，不是新的訊息類型（見 `phase-agent-contract.md`「PR ready 之後的 review 往返」
節）。orchestrator 收到這次重新送來的「PR ready」，回到本節開頭的處置：記下 PR 編號、回報
使用者、tab 繼續保持開啟，直到使用者說可以合併為止。

## 合併與收尾的連鎖

使用者在 orchestrator 這裡說可以合併後，依序做四件事：

1. 委派 `github-manager` 執行合併。
2. 通知該 phase agent PR 已合併、請它收尾；同時通知其餘還在跑的 phase agent，main 已經動
   了，請自行同步並處理衝突。
3. 等該 phase agent 回報收尾完成後，orchestrator 才關閉它的 tab；關閉前兩項守衛都要成
   立：要關的 tab 識別碼與進度表上該 phase 那一列記的 herdr 座標中的 tab 識別碼一致，且不等於
   orchestrator 自己所在的 tab——自己所在的 tab 識別碼取自環境變數 `HERDR_TAB_ID`，herdr
   會把呼叫端的座標注入每個受管 pane。整套中斷恢復機制是為「orchestrator 中斷後接回」設計
   的，不是為「orchestrator 執行中把自己關掉」設計的，識別碼核對錯誤就是後者。
4. 重查依賴圖，把因此解鎖的 phase 派出去。

orchestrator 不自行清理 phase 的 worktree——那是 phase agent 收尾程序的一部分，見
`phase-agent-contract.md`。

自我檢測：關閉這個 tab 之前，是不是已經收到這個 phase 的收尾完成訊息，且要關的識別碼同時滿
足「與進度表座標中的 tab 識別碼一致」與「不等於 `HERDR_TAB_ID`」兩項？任一答否就不要關。

## Epic 收尾

所有 sub-issue 都關閉後，由 orchestrator 判斷關閉 parent issue 的時機並委派
`github-manager` 執行。這是 orchestrator 專屬的職責，phase agent 不做這件事——每個 phase
agent 收尾時只關自己的 sub-issue，parent 什麼時候該關，只有看得到全局的 orchestrator 判斷
得出來，任何一個 phase agent 都只看得到自己那個 phase。

## 狀態檔與中斷恢復

狀態檔是本地快照，不是權威。它記的是 GitHub 上查不到的東西：

- herdr 座標（tab 識別碼、agent 名稱、session 位址）
- worktree 路徑
- 每個 phase 目前處在哪個關卡

進度本身仍以 sub-issue 的 `state` 與 PR 的合併狀態為準。狀態檔依 `tmp-file-usage` rule 放
在工作區的 `.tmp` 底下。

中斷後接回的恢復順序固定三步：

1. 讀狀態檔取得座標。
2. 向 GitHub 重查進度。
3. 用 `herdr agent list` 核對哪些 tab 還活著。

三步之間對不上時，一律以 GitHub 與 herdr 的現況為準並改寫狀態檔——狀態檔唯一會過時的情境正
是 orchestrator 中斷的那一刻。

自我檢測：這三步的順序有沒有被打亂，尤其是讀狀態檔是不是排在向 GitHub 重查之前、向 GitHub
重查是不是排在核對 tab 存活之前？順序錯了就先停下重來，不要將錯就錯往下做。

tab 已不在但 PR 尚未合併的 phase，據實回報給使用者，由使用者決定要重派還是接手；orchestrator
不自行重派。

## 失敗行為

共同原則：orchestrator 在看不見畫面的前提下判斷，它手上能用的證據只有 `agent_status`、tab
還在不在、GitHub 上的 issue 與 PR 狀態這三種；判不出來就交給使用者，不自行終止任何 phase。

| 情境 | 處置 |
| --- | --- |
| phase agent 啟動後遲遲沒有報到 | 代表卡在啟動階段，信任對話框是已知的一種；停下問使用者，不代按 |
| tab 已經不在而 PR 未合併 | 說明後果並詢問使用者要重派還是接手，不自己重派——自行重派會在同一個 sub-issue 上開出第二條分支 |
| PR 已合併但對應的 sub-issue 仍然開啟 | 回報使用者，由使用者決定如何完成殘留的收尾；orchestrator 不自行接手清理 |
| 長時間沒有任何訊息 | 依「監控節奏」節的迴圈持續觀測；可用的判準只有 `agent_status` 與該行程的累計 CPU 時間有沒有在動，兩項都不足以斷定卡死；一律把觀測值原文交給使用者決定，不做自動處置 |
| 合併失敗（例如衝突或 CI 未過） | 不由 orchestrator 解決，把失敗訊息原文轉給該 phase agent——那是唯一有開發脈絡的一端 |
| 依賴圖成環，或依賴指向不存在的 issue | 停下回報，不猜測順序 |
