# 人類介入邊界

AI 驅動開發的核心原則：人類只在兩個點介入——核准設計、確認合併——兩點之間全程自主，不停下等人類做例行決定或審閱。

## 設計核准後自主執行

透過 superpowers 流程（brainstorming → plan → 實作 → PR）開發時，使用者在 brainstorming 核准設計後即進入全自主：不再要求重新審閱已寫出的 design 或 spec；writing-plans、實作、code review、開 PR 全程自動推進，沿途每個原本要「請人類選擇或審閱」的關卡一律由 AI 以推薦選項自決——執行模式取 subagent-driven，分支收尾取 push 並開 PR。

唯一例外是遇到真正的 blocker（缺依賴、測試反覆失敗、指令有歧義、plan 有致命缺口等）須停下詢問；此屬錯誤處理，非例行關卡。

## Ready for handover：可交回人類確認合併的條件

以下三條件同時成立，才可宣告 PR ready、交回人類確認合併：

- CI 已實際查證通過，不得假設；
- self code review 已通過，無未解決的 Critical 或 Important 問題；
- PR 上每一則 reviewer 留言都已處理——已修正並 push，或已附理由回覆並 resolve。

任一未達成，據實回報現況與缺口，不得宣稱 ready。

## 合併確認與收尾

AI 不自動 merge：達到 ready 即停下回報，由使用者確認合併。使用者確認合併後，AI 自主完成收尾、不再介入：

- 關閉本次工作對應的 GitHub issue（已關閉則略過）。
- 若該 issue 是某 parent 的 sub-issue，關閉後檢查該 parent 底下的 sub-issue 是否已全數關閉，是則一併關閉 parent（更上層 parent 同理遞迴）。
- 例外：若有更具體的契約文件已把 parent issue 的檢查與關閉職責另行指派給別的角色，本條不適用於執行 sub-issue 收尾的那一方。
- worktree 與分支的清理見 git worktree 工作流程。
