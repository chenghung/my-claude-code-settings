# 模式 M：變更風險與停機分析流程

此檔僅在 aws-architect skill 進入模式 M（Modification Analysis）時動態載入，用於指導既有 AWS 資源變更（upgrade、downgrade、replacement、migration）的風險與停機分析執行步驟。

## 執行規則

- 共 10 個步驟，逐步執行，每步驟結束須顯示 **CHECKPOINT**，等待使用者確認後才能進入下一步。
- 每則訊息必須明確標示目前所在步驟，例如：`Step 1 of 10`。

## 步驟一：啟動 planning file

若使用者已透過 planning-with-files skill 觸發本流程，直接沿用既有的 planning file。否則主動觸發 planning-with-files skill 建立新的 planning file。本流程涉及多輪分析且可能跨日，所有中間結論必須即時寫入 planning file 以確保可恢復性。

## 步驟二：定義變更目標

請使用者描述以下四項，並將描述完整寫入 planning file：

- 要變更的對象：具體哪個 service 或哪一組資源
- 變更類型：upgrade、downgrade、replacement、in-place migration、cross-region migration、cross-account migration 等
- 變更目的：為何此時需要進行此變更
- 必須達到的限制：例如 no downtime、low risk、必須維持 read-after-write 一致性、必須符合某 SLA

## 步驟三：取得既有資源現況

依 `references/current-state-discovery.md` 的程序取得現況資料，重點蒐集以下四類資訊：

- 被變更資源的詳細 config
- 所有上下游依賴：流量入口、資料依賴、IAM 依賴、network 依賴、第三方服務依賴
- 實際流量模式：peak、off-peak、retry 行為
- 現有 SLA 與 SLO

將現況完整寫入 planning file，並明確標註每筆資料的來源（IaC、AWS API 或使用者口述）。

## 步驟四：定義目標狀態

明確描述變更完成後的資源 config 與架構配置，並與步驟三的現況做 diff 對照，讓兩者的差異在 planning file 中清晰可見。

## 步驟五：建立風險矩陣

委派 deep-thinking skill 從以下五個面向逐項分析風險：

- Security
- Availability
- Performance
- Cost
- Operational

每項標示風險等級（高、中、低）、觸發條件、以及對應的緩解措施，結果寫入 planning file。

## 步驟六：Downtime 與影響分析

逐項評估以下三點並寫入 planning file：

- 哪些操作是 in-place 變更可能造成 service 中斷；哪些可以做到 zero-downtime
- 預估的 RTO 與 RPO
- Blast radius：哪些上下游會受影響，是否有級聯失敗風險

明確判斷使用者在步驟二所要求的 no downtime 是否真的可達。若不可達，必須直接告知使用者，不得粉飾，並提供折衷方案（例如 minimal downtime window、僅在 off-peak 執行）。

## 步驟七：Cutover 策略建議

根據變更性質從以下策略中推薦合適者，並說明推薦理由：

- Blue green deployment
- Canary release
- Dual-write 或 dual-read
- Shadow traffic
- In-place rolling update
- Stop-and-switch（短暫停機後切換）

委派 deep-thinking skill 評估各策略對本次場景的適用性，並將結論寫入 planning file。

## 步驟八：Rollback 計畫

針對步驟七推薦的 cutover 策略制定對應的 rollback plan，涵蓋三項：

- Rollback 觸發條件：什麼指標達到什麼閾值就執行 rollback
- Rollback 步驟：描述執行順序，不含實際 mutate 指令
- Rollback 後的資料一致性處理：例如 dual-write 期間累積的差異如何處理、如何避免雙寫衝突造成資料不一致

將 rollback plan 完整寫入 planning file。

## 步驟九：產出 step-by-step runbook

描述每個執行階段的步驟與檢查點，三欄並列：

- 使用者需要執行的動作
- terraform-engineer 負責處理的 IaC 變更
- 用於驗證該步驟完成的 read-only 指令

Runbook 不含 mutate 指令的具體形式；所有 mutate 操作保留給 terraform-engineer 在實作階段處理。將 runbook 寫入 planning file。

## 步驟十：產出 HackMD 報告

透過 hackmd-notes skill 建立報告，報告章節依 `references/output-templates.md` 的模式 M 模板產出。報告末尾的 Next Steps 章節須明確標示：交棒給 terraform-engineer 進入實作階段，或建議使用者先在 dry-run 或 staging 環境驗證 runbook。完成後將 HackMD URL 回報給使用者。

## 共通原則

- 所有深度分析委派給 deep-thinking skill。
- 取得現況依 `references/current-state-discovery.md` 的優先順序處理，並明確標註來源。
- No downtime 的承諾須先驗證可達性；不可達時必須明示使用者，不可粉飾。
- Runbook 描述步驟與驗證指令，不含 mutate 指令明細。
- 範圍最小化，只解決使用者描述的變更問題。
