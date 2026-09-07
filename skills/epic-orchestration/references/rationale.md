# 實測依據與設計理由

本檔是 `epic-orchestration` 的理由層。`SKILL.md` 只寫怎麼做，各項判斷背後的實測結果、尚未驗證的假設，以及一項設計取捨，都記在這裡。

執行流程時不需要載入本檔，撞到反常症狀時才打開對照。會讓人想打開本檔的症狀，至少涵蓋以下六種：

- phase agent 啟動時卡住不動
- 跨 session 訊息送不到或沒有回應
- phase agent 讀不到 epic 設計文件
- 由 issue 查不到對應的 PR
- 監控迴圈永久阻塞，或漏掉卡住的 phase
- phase agent 啟動時因權限模式旗標而卡在確認框

## 依症狀查找

| 症狀 | 對照結論 | 詳見章節 |
| --- | --- | --- |
| phase agent 啟動時卡住不動 | 常見成因是工作區信任對話框擋住了啟動，而 `herdr agent start` 在這種情況下回傳的錯誤具有誤導性，容易讓人誤以為 agent 沒建立成功 | 信任對話框會擋住啟動，但 git worktree 不受影響 |
| 跨 session 訊息送不到或沒有回應 | 上行與下行通道本身都已實測成立，閒置中的 session 也會被喚醒；真的送不到訊息時，該懷疑的是契約有沒有被遵守，不是通道本身 | 上行通道成立、下行通道會喚醒閒置 session、phase agent 會遵守只送四種訊息的契約嗎 |
| phase agent 讀不到 epic 設計文件 | 已知成因是設計文件放在 `docs` 目錄底下、被 `.gitignore` 忽略，worktree 內看不到；啟動時是否已補上 `add-dir` 旗標是第一個查核點，該旗標能否真正解決此症狀本身尚未實測 | 不帶 add-dir 旗標時的讀取後果未經驗證 |
| 由 issue 查不到對應的 PR | 這是預期行為，不是異常：由 issue 反查 PR 的 GraphQL 欄位依賴 PR 內文的 closing 關鍵字，本倉庫的撰寫慣例用不到它，設計因此本來就不採用反查 | 由 issue 反查 PR 不可靠 |
| 依賴關係或 sub-issue 清單查不到，懷疑是 GitHub API 不支援 | 兩個端點都已實測可用，查不到時該查的是呼叫路徑或參數，不是端點本身不存在 | issue dependencies 端點可用、sub-issue 清單端點可用 |
| 監控迴圈永久阻塞，或漏掉卡住的 phase | `herdr agent wait` 不帶 `--timeout` 就無限等待，不帶 `--until` 的預設集合又含語意未實測的 `done`；這兩點都已從該子命令自己的 `--help` 查證，所以該查的是這次呼叫實際帶了哪些值，不是機制本身有問題 | `herdr agent wait` 的 `--until` 可接受值與逾時語意 |
| phase agent 啟動時因權限模式旗標而卡在確認框 | 四個權限模式候選逐一實測過：兩個 bypass 類的檔位會在啟動時跳責任確認對話框而擋住啟動，`dontAsk` 是自動拒絕，只有 `auto` 同時通得過啟動與放行 | 權限模式旗標的四個候選只有 auto 通得過 |

## 通訊、啟動與監控的實測依據

### 上行通道成立

在 herdr 開的 tab 中啟動一個 Claude Code session，透過 `herdr agent prompt` 指示它用 SendMessage 送訊息給 orchestrator 這個 session，訊息即時送達，且送達時 orchestrator 正在執行其他工作。訊息以 `cross-session-message` 包裹，wrapper 上帶有 `from-name` 屬性，值是送訊端的 session 名稱。orchestrator 藉此能直接從報到訊息取得 phase agent 的位址，不需要另外猜測或比對。

### 下行通道會喚醒閒置 session

orchestrator 對一個正停在等待輸入狀態的 phase agent 送出 SendMessage，該 agent 的 herdr `agent_status` 由閒置轉為 `working`，並回訊自陳正停在等待輸入、這則訊息喚醒了它。這推翻了依工具說明字面推斷的疑慮，即閒置 session 沒有下一個工具回合、訊息可能卡住。

### 下行對 blocked 的對象會被明確拒絕

對一個 `agent_status` 為 `blocked` 的 agent 送出 `herdr agent prompt`，指令回傳 `agent_blocked` 錯誤並拒絕執行；事後讀那格 pane，送出的字串完全沒有出現在畫面上。所以這個下行機制對處於 `blocked` 的對象確實擋得住，而且會明確報錯，不是靜默吞掉。

這一項推翻了設計早期的一句敘述——「對著卡住的畫面送出開場指令，那段文字會被打進核准框而且不會有任何錯誤訊息」——該敘述已從 `SKILL.md` 移除。

兩個界線要一併記下。其一，這道保護只涵蓋 `herdr agent prompt`，`herdr agent send-keys` 是直接送按鍵、沒有這道檢查（未實測），代按有可能落在一張已經換掉的畫面上而不報錯。其二，實測對象是狀態確實為 `blocked` 的 agent；卡在工作區信任對話框時的狀態不必另外推測——下一節「信任對話框會擋住啟動，但 git worktree 不受影響」記下的那筆實測，正是該對話框出現時 agent 已存在於該 pane 且 `agent_status` 為 `blocked`、`launch_pending` 為真，所以這道保護涵蓋得到那一格。

### 信任對話框會擋住啟動，但 git worktree 不受影響

在一個新建立的、非 git 倉庫的目錄啟動 Claude Code 時會出現工作區信任對話框，此時 `herdr agent start` 回傳 `agent_not_ready` 錯誤，但 agent 實際已存在於該 pane 且狀態為 `blocked`、`launch_pending` 為真。對一個已經就緒的 agent 下 `herdr agent get`，`agent_status` 為 `idle`、`interactive_ready` 為 `true`，而 `launch_pending` 這個欄位根本不存在於回應中，不是查到它的值為 `false`——這與卡在信任對話框時 `launch_pending` 存在且為真，是同一組事實的兩面。在既有的 git worktree 目錄（其主倉庫路徑已被信任）啟動時直接就緒，未出現信任對話框。

信任記錄的形式是使用者家目錄下 `.claude.json` 的 `projects` 欄位，以絕對路徑為鍵、每筆帶 `hasTrustDialogAccepted` 布林值；已信任的父目錄不會讓子目錄自動通過，但 git worktree 會繼承主倉庫的信任。worktree 繼承這一點只實測過一次，樣本數與涵蓋範圍的限制見下方「git worktree 信任繼承的樣本數有限」。

### 權限模式旗標的四個候選只有 auto 通得過

`SKILL.md`「派工階段」只留下結論（帶 `--permission-mode auto`、字串照原文），比較過程記在這裡。四個候選在 herdr 環境下各以一個真實的 Claude Code agent 逐一實測：

1. `--permission-mode bypassPermissions`：啟動失敗。`herdr agent start` 回傳 `agent_not_ready` 錯誤，agent 實際存在但 `agent_status` 為 `blocked`、`launch_pending` 為真。讀畫面確認原因是啟動時跳出一個責任確認對話框，標題為 `WARNING: Claude Code running in Bypass Permissions mode`，選項是 `No, exit` 與 `Yes, I accept`。「啟動成功判準」三項不成立。
2. `--dangerously-skip-permissions`：啟動失敗，症狀與上一項完全相同，跳出的是同一個責任確認對話框。
3. `--permission-mode dontAsk`：啟動成功，三項齊備（`agent_status` 為 `idle`、`interactive_ready` 為真、`launch_pending` 未出現在回應中）。但語意實測的結果是自動拒絕而不是自動放行：對它送出一個要求，以 Bash 工具在工作目錄以外的路徑建立檔案，該檔案並未被建立，agent 回報的原文是「失敗（Bash 在 don't ask 模式下被拒絕執行）」，畫面底部的模式標示是 `don't ask on`。因此這個檔位不可採用，它比不帶旗標的現狀更糟。
4. `--permission-mode auto`：啟動成功、三項齊備，且語意實測為自動放行——送出同一個要求時檔案確實被建立、agent 回報成功、過程中沒有出現任何核准框，畫面底部的模式標示是 `auto mode on`。選定這一個。

另外兩項查證。`--allow-dangerously-skip-permissions` 依其 `--help` 說明只是讓 bypass 成為可選項、本身不預設啟用也不放寬任何權限，因此不是候選。使用者家目錄下的 `.claude.json` 裡沒有任何記錄 bypass 責任確認框已被接受的頂層欄位，只有 `projects` 欄位底下每個專案各自的 `hasTrustDialogAccepted`，那是工作區信任對話框的記錄、與 bypass 責任框無關——所以人工接受一次並不會被記住，下次啟動仍會再跳。

auto 的射程界線要誠實記下。auto 只實測過「以 Bash 工具對工作目錄以外的路徑建立檔案」這一類操作被自動放行，其他類型的操作在 auto 之下是不是仍會跳出核准框並未實測。另外，作用中的使用者層設定檔含有一個 `autoMode` 環境區塊，裡面記載了若干信任邊界（名稱帶 `prod` 或 `production` 的遠端目標，IAM、RBAC、networking 這類受保護的 IaC 範圍，敏感資料位置等），這代表 auto 是風險感知模式而不是無條件放行；但「這些邊界在 auto 之下是不是真的會跳出核准框」同樣未經實測。還有一點要寫明：那個 `autoMode` 區塊自述的信任倉庫是另一個倉庫（一個 Obsidian vault），不是本 epic 所在的倉庫，因此區塊內列舉的倉庫內敏感路徑對本流程沒有射程。

### 啟動與開場指令不併成一步

有一個提案是把啟動與開場指令併成一步：啟動 phase agent 時直接以命令列帶入第一則使用者訊息，省掉之後那一次 `herdr agent prompt`。實測之後不採用，量測結果與否決理由記在這裡。

基本可行性沒有問題。四家 CLI 都帶得進初始使用者訊息，也都能透過 `herdr agent start` 在 `--` 之後傳遞，四家也都實測到該訊息確實被執行並取得預期回覆：

- `claude` 用位置參數，`claude --help` 的 Usage 是 `claude [options] [command] [prompt]`，該位置參數的說明是 `Your prompt`。
- `codex` 用位置參數，`codex --help` 的 Usage 是 `codex [OPTIONS] [PROMPT]`，該位置參數的說明是 `Optional user prompt to start the session`。
- `opencode` 用 `--prompt`，說明是 `prompt to use`；它的位置參數是 `project`、內容是路徑，不能拿來放訊息。
- `agy` 用 `--prompt-interactive`（短旗標 `-i`），說明是 `Run an initial prompt interactively and continue the session`。要特別註明 `agy --prompt` 是 `--print` 的別名、屬非互動模式，容易誤用。

差異出在 `herdr agent start` 何時回傳，四家分成三種。`claude` 與 `agy` 等到那一輪回合結束才回傳；`codex` 在該訊息送出之前就回傳——實測當下 `agent start` 已回報 `agent_status` 為 `idle`、`interactive_ready` 為真，而畫面仍停在 `Ask Codex to do anything`、`Context 0% used`，之後才轉入 `working`；`opencode` 在該訊息開始執行前就回傳，回傳當下讀畫面是一片空白，之後才轉入 `working`。

決定性的一次實測是給 `claude` 與 `agy` 一個確定超過三十秒的前景回合，指令是 `python3 -c "import time; time.sleep(60); print('done')"`。兩家症狀完全相同：`herdr agent start` 在約三十一秒後回傳失敗，對應預設的 `--timeout 30000`，`agy` 那次的錯誤原文是 `{"error":{"code":"timeout","message":"timed out waiting for agent startup"},"id":"cli:agent:start"}`；隨後對該 pane 下 `herdr agent get`，`agent_status` 為 `working`、`interactive_ready` 欄位缺席，也就是「啟動成功判準」三項不成立；以啟動時所取的名稱下 `herdr agent get`，回傳 `{"error":{"code":"agent_not_found","message":"agent target <名稱> not found"}}`，`herdr agent list` 中該 pane 的 `name` 欄位為 `null`，也就是名稱根本沒有註冊上。但那個 agent 本身完全正常，`claude` 那一次在一分七秒後正確完成並回覆。

要用前景指令才測得出這個邊界。先前用 `sleep 45` 測不出來，因為 `claude` 把它放到背景執行、約二十秒就回到 `idle`。

不採用的理由有三點：

1. 名稱沒註冊上，後續一連串動作全部定址不到。`SKILL.md`「派工階段」以 `phase-` 接 sub-issue 編號為 agent 命名，之後的 `herdr agent prompt`、`herdr agent wait`、`herdr agent send-keys` 全靠這個名稱定址，進度表的 herdr 座標欄位也記它。
2. 「啟動成功判準」三項在這種情況下必然不成立，於是走「失敗行為」第一列：orchestrator 讀 pane 判因後若不是信任對話框，就會自行關掉這個 pane 重啟一次——被關掉的是一個健康、正在跑、已經載入完整 context 的 phase agent，而「失敗行為」第二列正是為了避免這件事才明文規定不重啟。
3. 這在真實情境是常態不是例外：開場指令那一輪要跑到 phase agent 自己停下來為止，遠超過 `herdr agent start --timeout` 的上限 300000 毫秒。

這批實測還給既有設計補上一個新理由。「啟動成功判準必須排在開場指令送出之前」原本的理由是不要對著一個卡住的畫面送指令；現在多一條更強的：一旦把開場指令併進啟動，那個判準本身就失去了它要量的東西，因為 agent 不會停在等待輸入的狀態。

### `herdr agent wait` 的 `--until` 可接受值與逾時語意

依該子命令自己的 `--help` 輸出：`--until` 接受 `idle`、`working`、`blocked`、`done`、`unknown` 五個值，可重複指定以匹配多個狀態；不帶 `--until` 時預設匹配 `idle`、`done`、`blocked` 三者；`--timeout` 的單位是毫秒，不帶時無限等待。

設計因此顯式指定 `idle` 與 `blocked` 兩個值、不用預設值，理由是預設集合還包含 `done`，而 `done` 對一個 Claude Code session 的確切語意尚未實測。這份輸出的另一句——不帶 `--timeout` 時無限等待——涵蓋的是仍走 `herdr agent wait` 的那一種握手，也就是代按執行中途核准框之後另外等的那一次；這一句掛在 `--timeout` 旗標自己的說明上，不在輸出末段。`herdr agent prompt` 那一種握手已經併進送出的同一次呼叫，它的逾時掛在 `herdr agent prompt` 上，依據是那個子命令自己的 `--help` 輸出末段逐字寫的 `Without --timeout, the settled-state wait is indefinite.`——兩邊的出處不同，不要合寫成一句。兩種握手不設逾時的後果相同（orchestrator 永久阻塞在這一次呼叫上，整個 epic 跟著停擺），但走得到那裡的情形兩邊不同：`herdr agent prompt` 那一種是狀態確實變了、卻始終沒走到 `working`（例如 `idle` 轉進 `blocked` 就停住），已被受理、送出時對方處於 `idle` 而單純沒被接手的那一種反而會在 5000 毫秒內以 `agent_prompt_stalled` 回來——在本設計所取的 10000 之下，帶不帶 `--timeout` 都一樣（`--timeout` 短於 5000 才會改回逾時，可調範圍見下面「十輪門檻與握手逾時都是估計值」）；`herdr agent wait` 那一種沒有記載對應的門檻，代按沒被接受、狀態一直停在 `blocked` 時就一路等下去。

### 併進送出的那次握手已實測，`herdr agent send-keys` 那一路沒有選項可帶

`SKILL.md`「下行送出後的握手」把三種握手分成不對稱的兩路——第一種把送出與等待併成單次呼叫，走 `herdr agent send-keys` 的兩種只能送出與確認分兩步——依據是一正一負兩筆。

正面那筆：對一個 `agent_status` 為 `idle` 的 `claude` agent 實測 `herdr agent prompt <TARGET> <TEXT> --wait --until working --timeout 10000`，指令回傳碼為 0，回應中的 `agent_status` 為 `working`，整次呼叫不到一秒就回傳，且該 prompt 確實被執行並取得預期回覆。所以送出與握手併成同一次呼叫是成立的，不必送完再補一次 `herdr agent wait`。

負面那筆：`herdr agent send-keys --help` 的完整輸出如下，除了兩個位置參數之外沒有任何選項，`--wait` 與 `--timeout` 都給不進去。這就是 `SKILL.md` 說第三種「不能比照第一種」的全部依據：

```text
Send key presses to an agent

Usage: herdr agent send-keys <TARGET> <KEY>...

Arguments:
  <TARGET>
  <KEY>...

Use esc as the canonical Escape key name; escape is also accepted.
```

## GitHub API 的實測依據

### issue dependencies 端點可用

REST 端點為 `repos` 底下 `issues` 編號底下的 `dependencies/blocked_by` 與 `dependencies/blocking`，回傳的 issue 物件含對方的 `state` 欄位。GraphQL 側有 `Issue.blockedBy`、`Issue.blocking`，以及彙總欄位 `Issue.issueDependenciesSummary`，其欄位名為 `blockedBy`、`blocking`、`totalBlockedBy`、`totalBlocking`。判斷端點存在的依據是正確路徑回傳 200 與空陣列，猜錯的路徑才回傳 404。

### sub-issue 清單端點可用

REST 端點為 `repos` 底下 `issues` 編號底下的 `sub_issues`，回傳的 issue 物件含 `state`；另有 `sub_issues_summary`，欄位為 `total`、`completed`、`percent_completed`。GraphQL 側為 `Issue.subIssues` 與 `Issue.subIssuesSummary`。

### 由 issue 反查 PR 不可靠

GraphQL 的 `closedByPullRequestsReferences` 只有在 PR 內文使用 Closes、Fixes、Resolves 這類 closing 關鍵字時才有值。本倉庫的 PR 撰寫慣例是內文開頭放裸的 issue 編號，因此該查詢回傳零筆，必須改查 `timelineItems` 的 `CrossReferencedEvent` 才抓得到關聯。設計因此不採用反查，改為記住 phase agent 回報的 PR 編號、直接正查那個 PR 的合併狀態。

## 倉庫設定的實測依據

### MD029 與顯式編號慣例互相牴觸

本倉庫的 markdownlint 設定把 MD029 的 `style` 設為 `one`，要求有序清單一律用 `1.` 前綴；本 skill 的定義檔則一貫使用顯式編號。兩者相牴觸時取顯式編號，理由是檔內的自我檢測句以序數回指清單項目（「指得出第幾項嗎」），而模型讀到的是原始 markdown 而不是算繪結果，全部寫成 `1.` 就得自己數，數錯一位就整條走錯處置。

因此這幾份檔案的 lint 違規全部落在 MD029 這一條，而且會隨新增的顯式編號清單而增加，這是預期內的結果而非缺陷。設定與慣例互相牴觸是先前就存在的問題，修改設定會影響全倉庫所有檔案，因此不處理。

## 待驗證的假設

### git worktree 信任繼承的樣本數有限

git worktree 的信任繼承只實測過一次，且未涵蓋建立在倉庫目錄之外的 worktree。設計把 worktree 放在倉庫內的 `.worktrees` 底下，並在真的撞到信任對話框時停下問使用者，因此這項假設不成立時的失敗形態是多一次詢問，不是靜默出錯。

### 不帶 add-dir 旗標時的讀取後果未經驗證

未實測不帶 `add-dir` 旗標時，phase agent 是否真的讀不到工作目錄之外的設計文件。沒有實測的理由是該探測需要另外啟動一個 session，而結論不會改變設計取捨：帶了這個旗標無害，不帶則可能靜默失效，所以設計採取帶旗標的保險做法。

### phase agent 會遵守只送四種訊息的契約嗎

phase agent 主動送出的訊息應只有報到、決策請求、PR ready、收尾完成這四種，但沒有任何機制強制它遵守，只靠契約文字撐著。假設不成立時的失敗形態是 orchestrator 的 context 被逐步填滿，不是流程中斷。

### 第二條禁令在 orchestrator 可讀 pane 之後只剩自律

讀 pane 這個例外開出來之後，第二條禁令（不主動去取 phase 的開發內容）就沒有任何機制兜底：畫面讀進 context 就是讀進去了，沒有東西把「它停在什麼上面」以外的內容濾掉，也沒有東西阻止那些內容影響後續判斷，這條完全靠定義檔文字對模型的約束力撐著。假設不成立時的失敗形態是 orchestrator 的主 context 被 pane 上的開發內容逐步污染，epic 越大、讀 pane 的次數越多，就越早出現。設計端能做的只有把例外收在四個具名觸發條件上，讓讀 pane 的次數本身有上界。

### 十輪門檻與握手逾時都是估計值

「監控節奏」的十輪空轉門檻與「下行送出後的握手」的 10000 毫秒逾時，兩個數字本身都沒有實測依據。十輪是依整輪 60 秒的牆鐘上限推算的，但 60 秒是上限不是下限——其他 phase 早退時整輪遠短於 60 秒，所以十輪可能只有兩三分鐘。握手那一邊只有「不帶 `--timeout` 會無限等待」是查證過的——走 `herdr agent wait` 的那一種見上面 `--until` 那一節，併進 `herdr agent prompt` 的那一種出自該子命令自己的 `--help` 輸出末段——10000 這個值同樣是估的。假設不成立時的失敗形態不是流程中斷，是誤報或漏報：門檻太緊會對正在做事的 phase 一再讀 pane，太鬆則讓真的卡住的 phase 拖很久才被發現。實際使用時若發現誤報或漏報過多，這兩個數字是第一個該調的參數——但第一種握手的那個數字只調得動它兩支走法中的一支。第三種握手掛在 `herdr agent wait` 上，10000 往上往下都直接改變它等多久；第一種併在 `herdr agent prompt` 上，`--wait` 是兩段式的（見 `SKILL.md`「下行送出後的握手」）：已被受理、送出時對方處於 `idle` 的那則下行，5000 毫秒內一次狀態變化都沒有觀測到時回 `agent_prompt_stalled`，這一支釘在那道固定的 5000 毫秒門檻上，把 10000 往上調完全不改變行為，唯一調得動的方向是調到 5000 以下——而那只是把回傳從 `agent_prompt_stalled` 換成逾時，兩者在 `SKILL.md` 裡走同一條處置，等於沒調；狀態變化發生過、卻始終沒走到 `working` 的那一支（例如 `idle` 轉進 `blocked` 就停在那裡）則相反，門檻已經過了、攔不到它，收尾的正是 `--timeout`，10000 直接決定 orchestrator 在這次呼叫上阻塞多久，往上調就是延長阻塞——這一支也正是第一種握手不能省略 `--timeout` 的理由（見上面 `--until` 那一節）。

## 設計取捨：為什麼不寫 shell script

本 skill 不寫 shell script。理由是 `pr-review-by-multi-agents` 需要腳本，是因為它要把契約全文原文嵌進多個 prompt、還要跑一個無頭監督行程；這裡兩者都不存在。契約用檔案路徑傳遞，不必嵌進 prompt；而清單以外的關卡雖然已改由 orchestrator 自決、不再每一個都要使用者介入，每一個關卡仍然要拿設計文件、依賴圖與讀 pane 得到的那一句判定結論做判斷，自決換掉的是誰做決定，不是這件事還要不要判斷，所以照樣沒有可以整段自動化的區塊。
