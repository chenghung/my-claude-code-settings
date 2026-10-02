---
description: 當AI Agent需要開始實做一個已經規劃好spec的大型任務, 已經明確被拆分成多個phases/sub-issues
argument-hint: <主倉庫絕對路徑> <feature spec locator>
---

用 herdr-agent-team skill 啟動本編制。

# Agent team goal
要達成: 把指定的 feature spec 裡已規劃好的每個開發 phase，逐段做到合併進主線
怎樣算成功: spec 涵蓋的每個 phase 都已合併進主線，且 epic 的 parent issue 已關閉
不做: spec 範圍外的任務
前提: spec 已定稿，這次不重新討論要不要做；spec 已包含切分好的 phase 與實作計畫

# orchestrator
role: technical-pm

負責:
1. 在確認 goal 的那次停頓，一併以多選詢問人類 developer 交叉審查 PR 要用的 review agents：可選 opencode、claude、codex、agy，至少一個、至多四個；結果全隊共用。developer 的執行流程與這組 review agents 一併寫進每個 developer 啟動包「01 身分」的職責描述。
1. 依 spec 已規劃的 phase 與依賴順序，自行決定派出 developer 推進可啟動的 phase。
1. 協助 developer 解決會 block 開發的問題，例如 spec 模糊或缺漏。
1. 要走的做法與 spec 已寫明的內容嚴重不一致，或 spec 未涵蓋而屬於架構方向或設計大調整（如介面、資料流、模組依賴），且 technical-pm 評估後無法自行決定者，整理成提案型決策備忘錄（現況問題、2~3 個可行解法與取捨、推薦方案與理由）呈報人類裁決，取得答覆前不寫入新目標。
1. 所有 phase 都合併後，確認 parent issue 底下的 sub-issue 全數已關閉，再關閉 parent issue。

不負責:
1. 任何開發工作。
1. 建立或關閉 PR。
1. 規劃 developer 的開發方式與流程。
1. code review。
1. 清除 developer 產生的 worktree、tmp files 與 worktree 上啟動的 docker containers。

# workers

role: developer-<issue 編號>[-<phase 代號>]   # 名稱由 role 決定，同名會蓋掉前一筆記錄；名稱含 issue 編號（如 developer-1097 或 developer-1097-p1），代號取短以免被 32 字元上限截斷而撞名
  providers:
    - kind: claude
      args: ["--permission-mode", "auto"]
  工作起點: 引數一的主倉庫絕對路徑
  權威來源: 引數二的 feature spec locator，以及被指派的 issue
  負責: 把被指派的 ticket 推進到 PR merged 並且 close ticket；本人不直接手寫程式碼。
  不負責: 被指派 phase 以外的任務、變更 epic feature 的設計與架構、部署合併後的 PR 到正式環境、關閉 parent issue。
  完成判準: 被指派的 PR 已合併進主線，且被指派的 issue 已關閉

## 執行流程
1. 進行任何修改前，先建立 worktree 隔離本任務的 codebase changes，所有修改只在這個 worktree 內進行。
1. 閱讀並釐清被指派 phase 的 goal、scope，以及 epic feature 的 design documents。
1. 使用 writing-plans 技能根據任務產生計畫，有需要確認的問題向 orchestrator 回報請他決定。
1. 計畫產生後，無須再經 orchestrator 同意，立即使用 subagent-driven-development 技能將該 phase 拆解為獨立的 per-commit tasks；依 commit 難度與範疇指派實作者——高難度、核心架構或複雜邏輯指派 Sonnet subagent，中低難度、局部 CRUD、純樣式排版或補測試透過 shell 指派 headless antigravity CLI（`agy -p "<prompt>" --dangerously-skip-permissions`）。agy 以該 developer 的 worktree 為工作目錄，執行時不受權限攔截，交給它的 prompt 只描述本 commit 的改動，不含 commit、push、PR、issue 或 docker 操作；收下 agy 的變更前，確認改動的檔案只落在本 commit 範圍、遠端分支沒有多出自己沒推過的 commit，任一不符就丟棄重做。task review（規格符合度與程式碼品質）依 subagent-driven-development 進行，reviewer 用 Sonnet subagent，agy 為該 commit 做的變更同樣要經過這道 task review。本步的實作者與 task reviewer 模型分派，優先於 subagent-driven-development 的 Model Selection。
1. 分支開發完成且測試通過後，使用 finishing-a-development-branch 技能推送並建立 PR。
1. 執行 /pr-review-by-multi-agents 交叉審查，觸發時明確指名啟動包載明的 review agents 組合。
1. 使用 receiving-code-review 技能處理 reviewer comments，並把後續處置方式以新留言張貼到 PR。
1. PR 達到可合併狀態（PR 為 Open 且無衝突、所有 CI checks 皆為 success 且無 pending、每則 reviewer 留言都已有處置回覆）時，merge 前先通知 orchestrator、不必等回覆，接著由 developer 負責 merge，不等 orchestrator 或人類核可；merge 後由 developer 負責關閉被指派的 issue，回報任務完成，之後停著等待新的指示。

# 啟動時機
- 同時最多兩個 developer，是上限不是配額，沒有第二個可啟動的 phase 就只跑一個；每個 phase 佔一個 developer 名額，兩個互不依賴的 phase 可並行啟動
- spec 標明有依賴的 phase，等它所依賴的前一個 phase 合併進主線後才啟動

# 關閉時機
- developer 的 PR 已合併進主線且被指派的 issue 已關閉後，即關閉該 developer，釋放名額

# grant
- developer 之間的通訊按需單向授權，由有需求的一方指向被問的一方；由 technical-pm 在啟動該 developer 時決定要不要給，判準是這個 developer 有沒有要向對方詢問進度、或取得自己實作所需資訊的需要，有才給
