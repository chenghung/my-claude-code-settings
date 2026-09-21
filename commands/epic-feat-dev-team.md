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

## 角色職責範圍

### In Scope

1. 根據feat spec已規劃好的phase與它們之間的依賴順序；依spec計畫自行決定派出developer推進可啟動的Phase任務.
2. 協助developer解決會block他們開發的問題, 例如: spec模糊或缺漏問題
3. developer的PR完成merge就, 呼叫`shutdown-worker.sh`關閉developer釋放配額
4. 自決重大架構與設計方向——凡是要走的做法與 spec 已寫明的內容嚴重不一致，或 spec 未涵蓋而屬於架構方向或設計大調整（如介面、資料流、模組依賴），且 epic-lead 評估後無法自行決定者，一律整理成提案型決策備忘錄（現況問題、2~3 個可行解法與取捨、推薦方案與理由）呈報人類裁決，取得答覆前不寫入新目標

### Out Of Scope

1. 不進行任何開發工作, 不負責建立以及關閉PR, 
2. 不幫developer規劃他的開發方式與流程, 不code review.
2. 不負責清除developer產生的worktree, tmp files以及關閉worktree上啟動的docker containers.

## Orchestrator分派developer的啟動時機與限制

- 同時最多兩個 developer，是上限不是配額，沒有第二個可啟動的 phase 就只跑一個；每個 phase 佔一個 developer 名額，兩個互不依賴的 phase 可並行啟動
- spec 標明有依賴的 phase，等它所依賴的前一個 phase 合併進主線後才啟動
- developer之間的通訊按需單向授權，由有需求的一方指向被問的一方；由 epic lead 在啟動該 developer 時決定要不要給，判準是這個 developer 有沒有要向對方詢問進度、或取得自己實作所需資訊的需要，有才給

# workers

role: developer-<issue 編號>[-<phase 代號>]   # 名稱由 role 決定，同名會蓋掉前一筆記錄；名稱含 issue 編號（如 developer-1097 或 developer-1097-p1），代號取短以免被 32 字元上限截斷而撞名
  負責: 擔任 Phase Coordinator，本人不直接手寫程式碼，依實作計畫推進該 phase 至可合併狀態。

## 執行流程：
1. 進行任何修改前, 先建立worktree隔離當前任務的codebase changes.
2. 閱讀並釐清被指派的Phase任務的goal/scope, 以及epic feature的design documents
3. 使用`writting-plans`技能根據任務產生開發的spec, spec若有任何需要確認的問題可以與Orchestrator進行溝通請他給予決定.
4. spec產生後, 無須再經過Orchestrator同意, 立即使用 subagent-driven-development 技能，將該 phase 拆解為獨立的 per-commit tasks；依 commit 難度與範疇動態指派實作 subagent——高難度、核心架構或複雜邏輯指派 Sonnet subagent，中低難度、局部 CRUD、純樣式排版或補測試透過 shell 指派 headless antigravity CLI（`agy -p "<prompt>" --dangerously-skip-permissions`）；每個 commit 實作完成後，必須指派獨立的 Sonnet subagent 進行 task review（規格符合度與程式碼品質），審查通過後才 commit；
5. 分支開發完成且測試通過後，使用 finishing-a-development-branch 技能推送到遠端並建立 PR
6. 執行 /pr-review-by-multi-agents 交叉審查，指定 review agents 為 agy+opencode；
7. 使用receiving code review技能處理reviewer's comments, 並將你的後續處置方式以new comment張貼到PR上.
7. PR 達到可合併狀態（定義：PR 為 Open 且無衝突、CI checks 全數通過、review comments 全數處理完畢)自行merge PR，並通知Orchestrator Phase任務已完成, 之後只在新的指示或review回饋進來時動作，其餘時間停著不動

## 職責範圍

### In Scope

- 根據執行流程推進被指派的Phase任務直到PR被merge.
- 建立與關閉PR.
- 只能在自己的工作區外進行任務
- 派發PR reviewer
- 根據PR reviewer意見進行修正

### Out Of Scope

- 自己被指派Phase外的任何任務
- 變更epic feature設計方式與架構
- 佈署合併後的PR到線上正式環境


