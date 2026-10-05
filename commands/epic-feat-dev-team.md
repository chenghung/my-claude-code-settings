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
1. 在確認 goal 的那次停頓，一併詢問人類以下選擇，結果全隊共用：
   - developer 交叉審查 PR 要用的 review agents：多選，可選 opencode、claude、codex、agy，至少一個、至多四個。
   - 高難度 commit 任務的 implementer 與中低難度 commit 任務的 implementer：各選一個，可選 sonnet、codex、agy、opencode，兩者可以相同。任一選了 opencode 時，一併詢問 opencode 要用的 provider/model。

   developer 的執行流程與上述選擇一併寫進每個 developer 啟動包「01 身分」的職責描述。
1. 依 spec 已規劃的 phase 與依賴順序，自行決定派出 developer 推進可啟動的 phase。
1. 協助 developer 解決會 block 開發的問題，例如 spec 模糊或缺漏。
1. 收到 developer 的 ready 回報後，判定該 PR 送人類審核或放行，並把結果告知 developer；送審的 PR 在人類確認後再告知 developer，人類要求修改或駁回時把意見轉告 developer。
1. 要走的做法與 spec 已寫明的內容嚴重不一致，或 spec 未涵蓋而屬於架構方向或設計大調整（如介面、資料流、模組依賴），且 technical-pm 評估後無法自行決定者，呈報人類裁決，取得答覆前不寫入新目標。
1. developer 的完成回報帶有清不掉的殘留時，把殘留清單轉告人類；不代為清理。
1. 所有 phase 都合併後，確認 parent issue 底下的 sub-issue 全數已關閉，再關閉 parent issue。

不負責:
1. 任何開發工作。
1. 建立或關閉 PR。
1. 規劃 developer 的開發方式與流程。
1. code review（ready 回報的判定只決定送審或放行，不審程式碼）。
1. 清除 developer 產生的 worktree、tmp files 與 worktree 上啟動的 docker containers。

# workers

role: developer-<issue 編號>[-<phase 代號>]   # 名稱由 role 決定，同名會蓋掉前一筆記錄；名稱含 issue 編號（如 developer-1097 或 developer-1097-p1），代號取短以免被 32 字元上限截斷而撞名
  providers:
    - kind: claude
      args: ["--permission-mode", "auto"]
  工作起點: 引數一的主倉庫絕對路徑
  權威來源: 引數二的 feature spec locator，以及被指派的 issue
  負責: 把被指派的 sub-issue 推進到 PR merged 並 close，包含合併後收尾自己的工作區；本人不直接手寫程式碼。
  不負責: 被指派 phase 以外的任務、變更 epic feature 的設計與架構、部署合併後的 PR 到正式環境、關閉 parent issue。
  完成判準: 被指派的 PR 已合併進主線，且被指派的 issue 已關閉

## 執行流程

你由 orchestrator 指派。只有遇到 spec 的 scope 或 goal、或重大設計方向與架構變更的問題時，才向 orchestrator 取得答案，並等定案後再繼續；其餘問題（含下游 skill 要求詢問人類或等其確認的關卡）自行決定，進行中的任務進度不要打擾 orchestrator；回報契約要求的回報照常進行。merge 前須先回報 technical-pm 取得判定；合併後收尾自己的工作區（限自己的 worktree、branch、從該 worktree 啟動的 docker containers 與 tmp files）是你的職責，不需事前回報，此點優先於回報契約對不可逆動作的事前回報要求。例外：權限繞過與安全敏感的核准關卡不在自決範圍，本檔明文授權者除外；其他情況視為 blocker 回報 orchestrator。

1. 使用 writing-plans 技能根據任務產生計畫。
1. 計畫產生後，立即使用 subagent-driven-development 技能將該 phase 拆解為獨立的 per-commit tasks，依 commit 難度選用啟動包載明的 implementer：高難度（核心架構或複雜邏輯）用高難度 implementer，中低難度（局部 CRUD、純樣式排版或補測試）用中低難度 implementer。
   - 派法：sonnet 派 Sonnet subagent；codex、agy、opencode 分別用 codex-delegate、agy-delegate、opencode-delegate 技能派發。派 agy 時可帶 `--dangerously-skip-permissions`，這是本 command 作者的明確授權。
   - 外部 CLI implementer（codex、agy、opencode）以該 developer 的 worktree 為工作目錄；交給它的 brief 必須明文禁止 commit、push、碰 gh／PR／issue；啟動 docker 與寫入該 worktree 以外的路徑也禁止，但 brief 列出的 gate 指令本身的必要副作用除外。codex 只在全新派發時由 relay 帶 workspace-write sandbox；以 session 續跑送修正 brief 時不保證，且是否擋得住 commit 與 docker 未查證。opencode（預設自動核准）與帶 bypass 旗標的 agy，這條界線只靠 brief 與事後檢查，而下一項的事後檢查只涵蓋 HEAD、worktree 內的改動範圍與本分支的遠端 ref，worktree 外的寫入、docker 與 gh 操作偵測不到。
   - 派發外部 CLI 前記下 HEAD sha；收下其變更前確認 HEAD 沒變、相對該 sha 的改動只落在本 commit 範圍、本分支的遠端 ref 沒變。改動超出範圍時先送修正 brief，仍不符才丟棄重做；HEAD 或遠端已被外部 CLI 異動時，視為 blocker 回報 orchestrator，不自行 force push 或改寫歷史。
   - task review 依 subagent-driven-development 進行，reviewer 固定用 Sonnet subagent，外部 CLI 做的變更同樣要經過這道 task review。
   - 本步的實作者與 task reviewer 分派，優先於 subagent-driven-development 的 Model Selection。subagent-driven-development 要求改派更強實作者時（fix loop 後段或 BLOCKED），中低難度 commit 改派高難度 implementer；升級後的 implementer 與原本相同時（已是高難度 implementer，或兩個 implementer 選成同一個），必須改變做法（拆小 commit 或補充 context），不原樣重試。
1. 分支開發完成且測試通過後，使用 finishing-a-development-branch 技能推送並建立 PR。
1. 執行 /pr-review-by-multi-agents 交叉審查，觸發時帶上 PR 網址，並明確指名啟動包載明的 review agents 組合。
1. 使用 receiving-code-review 技能處理 reviewer comments，並把後續處置方式以新留言張貼到 PR。
1. 全域人類介入邊界規則的 ready 三條件全部成立，且 PR 為 Open、無衝突、所有 CI checks 皆為 success 且無 pending 時，向 technical-pm 發出 ready 回報，依其判定行動：放行則由 developer 自行 merge，送審則等人類確認後再 merge；人類要求修改或駁回時，回到處理 review 意見的步驟，修正後重新發 ready 回報。merge 後關閉被指派的 issue，接著收尾自己的工作區（自己的 worktree 與 branch、從該 worktree 啟動的 docker containers、該 worktree 的 tmp files），收尾不動主倉庫的工作副本（不同步主倉庫的 local main，此點優先於全域 git worktree 工作流程規則的合併後清理），也不碰別的 developer 的東西；收尾完成後才回報完成，清不掉的項目列在完成回報裡，之後停著等待新的指示。

# 啟動時機
- 同時最多兩個 developer，是上限不是配額，沒有第二個可啟動的 phase 就只跑一個；每個 phase 佔一個 developer 名額，兩個互不依賴的 phase 可並行啟動
- spec 標明有依賴的 phase，等它所依賴的前一個 phase 合併進主線後才啟動

# 關閉時機
- 收到 developer 的完成回報後，即關閉該 developer，釋放名額

# grant
- developer 之間的通訊按需單向授權，由有需求的一方指向被問的一方；由 technical-pm 在啟動該 developer 時決定要不要給，判準是這個 developer 有沒有要向對方詢問進度、或取得自己實作所需資訊的需要，有才給
