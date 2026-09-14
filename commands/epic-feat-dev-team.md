---
description: 依 feature spec 已規劃好的 phase，派 developer 逐段推進到合併進主線
argument-hint: <主倉庫絕對路徑> <feature spec locator>
---

用 herdr-agent-team skill 啟動本編制。

# team goal（模板，觸發時以引數與對話實例化）
要達成: 把指定的 feature spec 裡已規劃好的每個開發 phase，逐段做到合併進主線
怎樣算成功: spec 涵蓋的每個 phase 都已合併進主線
不做: spec 範圍外的任務
前提: spec 已定稿，這次不重新討論要不要做；spec 已包含切分好的 phase 與實作計畫；前後端程式碼在同一個倉庫內

# orchestrator
role: epic-lead
負責: 從 spec 讀出已規劃好的 phase 與它們之間的依賴順序；依 spec 的實作計畫判讀每個 phase 涉及 backend、frontend 或兩者；派工、排程、排除 developer 回報的障礙；該 phase 進入可合併狀態（分端時兩端都到齊）後告知人類來確認合併，人類要求修改就把回饋轉給對應的 developer，哪一張 PR 合併完成就關閉開它的那個 developer
不負責: 寫程式；讀 developer 的開發內容；合併 PR；自決設計方向——凡是要走的做法與 spec 已寫明的內容不一致，或 spec 未涵蓋而屬於設計方向的選擇（例如介面、資料流、模組層級的依賴關係；spec 既定的依賴順序下此刻先啟動哪一個可啟動的 phase 只是排程，不在此列，自己決定），一律停下來問人類，取得答覆前不寫入新目標、不派新任務

# workers

role: developer-<phase 代號>[-be|-fe]   # 名稱由 role 決定，同名會蓋掉前一筆記錄；名稱過長會從尾端截斷，代號取短（如 p1、p2）以免 -be/-fe 被截掉而撞名
  負責: 把指派到的那一個 phase 開發到 CI 通過、self code review 無未解決的 Critical 或 Important 問題且結論已貼成該 PR 的一則 comment、review 回饋都已處理的可合併狀態；該 phase 由兩個 developer 分做兩端時，只做分到的那一端；進入可合併狀態後只在新的指示或 review 回饋進來時才動作，沒有就停著不動
  不負責: 自己負責範圍以外的任何任務，除非 orchestrator 另行指示；合併任何 PR（含自己開的那一張）則無條件不做；在工作起點那個 checkout 上直接動工同樣無條件不做，一律在自己專屬的工作區裡進行
  providers:
    - kind: claude
      args: ["--permission-mode", "auto", "--model", "opus"]
  工作起點: 觸發時給定的主倉庫絕對路徑
  權威來源: 觸發時給定的 feature spec locator
  交付點: 自己負責範圍的 PR 已進入可合併狀態
  終點: 自己負責範圍的 PR 已合併進主線
  完成判準: 自己負責範圍的 PR 已合併進主線

# 啟動時機
- 同時最多兩個 developer，是上限不是配額，沒有第二個可啟動的 phase 就只跑一個。名額算法：倉庫內 frontend 與 backend 各有自己的程式碼目錄、且某個 phase 兩端都要動時，該 phase 要兩個 developer 各做一端，名額用盡、只能單獨進行；其餘 phase 每個各佔一個名額，兩個互不依賴的可並行，不要求落在同一端
- spec 標明有依賴的 phase，等它所依賴的前一個 phase 合併進主線後才啟動

# grant
- developer 之間按需單向授權，由有需求的一方指向被問的一方；由 epic lead 在啟動該 developer 時決定要不要給，判準是這個 developer 有沒有要向對方詢問進度、或取得自己實作所需資訊的需要，有才給
