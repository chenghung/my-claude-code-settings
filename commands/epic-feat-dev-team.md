---
description: 當AI Agent需要開始實做一個已經規劃好spec的大型任務, 已經明確被拆分成多個phases/sub-issues
argument-hint: <主倉庫絕對路徑> <feature spec locator>
---

用 herdr-agent-team skill 啟動本編制。

# Agent team goal
要達成: 把指定的 feature spec 裡已規劃好的每個開發 phase，逐段做到合併進主線
怎樣算成功: spec 涵蓋的每個 phase 都已合併進主線
不做: spec 範圍外的任務
前提: spec 已定稿，這次不重新討論要不要做；spec 已包含切分好的 phase 與實作計畫

# orchestrator
role: epic-lead
負責: 從 spec 讀出已規劃好的 phase 與它們之間的依賴順序；依 spec 的實作計畫派工、排程、排除 developer 回報的障礙；該 phase 進入可合併狀態後告知人類來確認合併，人類要求修改就把回饋轉給對應的 developer；哪一張 PR 經查證合併完成，立即呼叫 `shutdown-worker.sh` 關閉開它的那個 developer 以釋放配額
不負責: 寫程式；讀 developer 的開發內容；合併 PR；自決重大架構與設計方向——凡是要走的做法與 spec 已寫明的內容不一致，或 spec 未涵蓋而屬於架構方向或設計大調整（如介面、資料流、模組依賴），且 epic-lead 評估後無法自行決定者，一律整理成提案型決策備忘錄（現況問題、2~3 個可行解法與取捨、推薦方案與理由）呈報人類裁決，取得答覆前不寫入新目標、不派新任務（spec 既定依賴下當前先啟動哪一個可啟動的 phase 屬排程，自己決定）

# workers

role: developer-<issue 編號>[-<phase 代號>]   # 名稱由 role 決定，同名會蓋掉前一筆記錄；名稱含 issue 編號（如 developer-1097 或 developer-1097-p1），代號取短以免被 32 字元上限截斷而撞名
  負責: 擔任 Phase Coordinator，本人不直接手寫程式碼，依實作計畫推進該 phase 至可合併狀態。

## 執行流程：
0. 建立worktree隔離當前任務的codebase changes.
1. 使用 subagent-driven-development 技能，將該 phase 拆解為獨立的 per-commit tasks；依 commit 難度與範疇動態指派實作 subagent——高難度、核心架構或複雜邏輯指派 Sonnet subagent，中低難度、局部 CRUD、純樣式排版或補測試透過 shell 指派 headless antigravity CLI（`agy -p "<prompt>" --dangerously-skip-permissions`）；每個 commit 實作完成後，必須指派獨立的 Sonnet subagent 進行 task review（規格符合度與程式碼品質），審查通過後才 commit；
2. 分支開發完成且測試通過後，使用 finishing-a-development-branch 技能推送到遠端並建立 PR
3. 執行 /pr-review-by-multi-agents 交叉審查，指定 review agents 為 agy+opencode；
4. 處理所有 review comments，將 Critical 與 Important 等級問題修復並推送 commit，建議與討論給予技術回覆
5. PR 達到可合併狀態（定義：PR 為 Open 且無衝突、CI checks 全數通過、review comments 全數處理完畢）後向 orchestrator 發出 delivered 回報，之後只在新的指示或 review 回饋進來時動作，其餘時間停著不動

## 職責範圍
不負責: 自己負責範圍以外的任何任務，除非 orchestrator 另行指示；本人直接手寫程式碼；合併任何 PR（含自己開的那一張）則無條件不做；在工作起點那個 checkout 上直接動工同樣無條件不做，一律在自己專屬的工作區裡進行
  providers:
    - kind: claude
      args: ["--permission-mode", "auto"]
  工作起點: 觸發時給定的主倉庫絕對路徑
  權威來源: 觸發時給定的 feature spec locator
  交付點: 自己負責範圍的 PR 已進入可合併狀態
  終點: 自己負責範圍的 PR 已合併進主線
  完成判準: 自己負責範圍的 PR 已合併進主線

# 啟動時機
- 同時最多兩個 developer，是上限不是配額，沒有第二個可啟動的 phase 就只跑一個；每個 phase 佔一個 developer 名額，兩個互不依賴的 phase 可並行啟動
- spec 標明有依賴的 phase，等它所依賴的前一個 phase 合併進主線後才啟動

# grant
- developer 之間按需單向授權，由有需求的一方指向被問的一方；由 epic lead 在啟動該 developer 時決定要不要給，判準是這個 developer 有沒有要向對方詢問進度、或取得自己實作所需資訊的需要，有才給
