# 人類介入邊界

AI 驅動開發的核心原則：人類只在兩個點介入——核准設計，以及確認 PR 可以合併——兩點之間全程自主，不停下等人類做例行決定或審閱。下列 Part A 是此原則在 superpowers 開發流程中的具體落實，Part B 定義 PR 可合併的完成條件。

## 設計核准後自主執行

透過 superpowers 開發流程（brainstorming → plan → 實作 → PR）開發時，使用者在 brainstorming 核准設計後即進入全自主：

- 不再要求使用者重新審閱已寫出的 design 或 spec 檔。
- writing-plans、實作、code review、開 PR 全程自動推進；沿途每個原本要「請人類選擇或審閱」的關卡，一律由 AI 以推薦選項自行決定——執行模式取 subagent-driven，分支收尾取 push 並開 PR。

唯一例外：遇到真正的 blocker（缺依賴、測試反覆失敗、指令有歧義、plan 有致命缺口等）仍須停下詢問使用者。這是錯誤處理，不同於上面被移除的例行關卡。

## PR ready for merge 的定義

只有三個條件同時成立，才可向使用者宣告 PR ready for merge：

- CI 已實際查證為通過，不得假設；
- self code review 已實際執行且通過，即無未解決的 Critical 或 Important 問題；
- 其他 reviewer 的每一則留言都已處理，即已修正並 push，或已附理由回覆並 resolve。

任一未達成，據實回報現況與缺口，不得宣稱 ready。AI 不自動 merge：達到 ready 後即停下回報，最終合併由使用者確認。
