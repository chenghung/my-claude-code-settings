# 實測依據與設計理由

本檔是 `epic-orchestration` 的理由層。`SKILL.md` 只寫怎麼做，各項判斷背後的實測結果、尚未驗證的假設，以及一項設計取捨，都記在這裡。

執行流程時不需要載入本檔，撞到反常症狀時才打開對照。會讓人想打開本檔的症狀，至少涵蓋以下四種：

- phase agent 啟動時卡住不動
- 跨 session 訊息送不到或沒有回應
- phase agent 讀不到 epic 設計文件
- 由 issue 查不到對應的 PR

## 依症狀查找

| 症狀 | 對照結論 | 詳見章節 |
| --- | --- | --- |
| phase agent 啟動時卡住不動 | 常見成因是工作區信任對話框擋住了啟動，而 `herdr agent start` 在這種情況下回傳的錯誤具有誤導性，容易讓人誤以為 agent 沒建立成功 | 信任對話框會擋住啟動，但 git worktree 不受影響 |
| 跨 session 訊息送不到或沒有回應 | 上行與下行通道本身都已實測成立，閒置中的 session 也會被喚醒；真的送不到訊息時，該懷疑的是契約有沒有被遵守，不是通道本身 | 上行通道成立、下行通道會喚醒閒置 session、phase agent 會遵守只送四種訊息的契約嗎 |
| phase agent 讀不到 epic 設計文件 | 已知成因是設計文件放在 `docs` 目錄底下、被 `.gitignore` 忽略，worktree 內看不到；啟動時是否已補上 `add-dir` 旗標是第一個查核點，該旗標能否真正解決此症狀本身尚未實測 | 不帶 add-dir 旗標時的讀取後果未經驗證 |
| 由 issue 查不到對應的 PR | 這是預期行為，不是異常：由 issue 反查 PR 的 GraphQL 欄位依賴 PR 內文的 closing 關鍵字，本倉庫的撰寫慣例用不到它，設計因此本來就不採用反查 | 由 issue 反查 PR 不可靠 |
| 依賴關係或 sub-issue 清單查不到，懷疑是 GitHub API 不支援 | 兩個端點都已實測可用，查不到時該查的是呼叫路徑或參數，不是端點本身不存在 | issue dependencies 端點可用、sub-issue 清單端點可用 |

## 通訊與啟動的實測依據

### 上行通道成立

在 herdr 開的 tab 中啟動一個 Claude Code session，透過 `herdr agent prompt` 指示它用 SendMessage 送訊息給 orchestrator 這個 session，訊息即時送達，且送達時 orchestrator 正在執行其他工作。訊息以 `cross-session-message` 包裹，wrapper 上帶有 `from-name` 屬性，值是送訊端的 session 名稱。orchestrator 藉此能直接從報到訊息取得 phase agent 的位址，不需要另外猜測或比對。

### 下行通道會喚醒閒置 session

orchestrator 對一個正停在等待輸入狀態的 phase agent 送出 SendMessage，該 agent 的 herdr `agent_status` 由閒置轉為 `working`，並回訊自陳正停在等待輸入、這則訊息喚醒了它。這推翻了依工具說明字面推斷的疑慮，即閒置 session 沒有下一個工具回合、訊息可能卡住。

### 信任對話框會擋住啟動，但 git worktree 不受影響

在一個新建立的、非 git 倉庫的目錄啟動 Claude Code 時會出現工作區信任對話框，此時 `herdr agent start` 回傳 `agent_not_ready` 錯誤，但 agent 實際已存在於該 pane 且狀態為 `blocked`、`launch_pending` 為真。對一個已經就緒的 agent 下 `herdr agent get`，`agent_status` 為 `idle`、`interactive_ready` 為 `true`，而 `launch_pending` 這個欄位根本不存在於回應中，不是查到它的值為 `false`——這與卡在信任對話框時 `launch_pending` 存在且為真，是同一組事實的兩面。在既有的 git worktree 目錄（其主倉庫路徑已被信任）啟動時直接就緒，未出現信任對話框。

信任記錄的形式是使用者家目錄下 `.claude.json` 的 `projects` 欄位，以絕對路徑為鍵、每筆帶 `hasTrustDialogAccepted` 布林值；已信任的父目錄不會讓子目錄自動通過，但 git worktree 會繼承主倉庫的信任。worktree 繼承這一點只實測過一次，樣本數與涵蓋範圍的限制見下方「git worktree 信任繼承的樣本數有限」。

## GitHub API 的實測依據

### issue dependencies 端點可用

REST 端點為 `repos` 底下 `issues` 編號底下的 `dependencies/blocked_by` 與 `dependencies/blocking`，回傳的 issue 物件含對方的 `state` 欄位。GraphQL 側有 `Issue.blockedBy`、`Issue.blocking`，以及彙總欄位 `Issue.issueDependenciesSummary`，其欄位名為 `blockedBy`、`blocking`、`totalBlockedBy`、`totalBlocking`。判斷端點存在的依據是正確路徑回傳 200 與空陣列，猜錯的路徑才回傳 404。

### sub-issue 清單端點可用

REST 端點為 `repos` 底下 `issues` 編號底下的 `sub_issues`，回傳的 issue 物件含 `state`；另有 `sub_issues_summary`，欄位為 `total`、`completed`、`percent_completed`。GraphQL 側為 `Issue.subIssues` 與 `Issue.subIssuesSummary`。

### 由 issue 反查 PR 不可靠

GraphQL 的 `closedByPullRequestsReferences` 只有在 PR 內文使用 Closes、Fixes、Resolves 這類 closing 關鍵字時才有值。本倉庫的 PR 撰寫慣例是內文開頭放裸的 issue 編號，因此該查詢回傳零筆，必須改查 `timelineItems` 的 `CrossReferencedEvent` 才抓得到關聯。設計因此不採用反查，改為記住 phase agent 回報的 PR 編號、直接正查那個 PR 的合併狀態。

## 待驗證的假設

### git worktree 信任繼承的樣本數有限

git worktree 的信任繼承只實測過一次，且未涵蓋建立在倉庫目錄之外的 worktree。設計把 worktree 放在倉庫內的 `.worktrees` 底下，並在真的撞到信任對話框時停下問使用者，因此這項假設不成立時的失敗形態是多一次詢問，不是靜默出錯。

### 不帶 add-dir 旗標時的讀取後果未經驗證

未實測不帶 `add-dir` 旗標時，phase agent 是否真的讀不到工作目錄之外的設計文件。沒有實測的理由是該探測需要另外啟動一個 session，而結論不會改變設計取捨：帶了這個旗標無害，不帶則可能靜默失效，所以設計採取帶旗標的保險做法。

### phase agent 會遵守只送四種訊息的契約嗎

phase agent 主動送出的訊息應只有報到、決策請求、PR ready、收尾完成這四種，但沒有任何機制強制它遵守，只靠契約文字撐著。假設不成立時的失敗形態是 orchestrator 的 context 被逐步填滿，不是流程中斷。

## 設計取捨：為什麼不寫 shell script

本 skill 不寫 shell script。理由是 `pr-review-by-multi-agents` 需要腳本，是因為它要把契約全文原文嵌進多個 prompt、還要跑一個無頭監督行程；這裡兩者都不存在。契約用檔案路徑傳遞，而每一個關卡都需要 orchestrator 判斷或使用者介入，沒有可以整段自動化的區塊。
