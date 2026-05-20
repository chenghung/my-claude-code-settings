# 模式 S：服務選型比較流程

此檔僅在 aws-architect skill 進入模式 S（Service Selection Survey）時動態載入，用於指導 AWS 服務選型比較的執行步驟。

## 執行規則

- 共 10 個步驟，逐步執行，每步驟結束須顯示 **CHECKPOINT**，等待使用者確認後才能進入下一步。
- 每則訊息必須明確標示目前所在步驟，例如：`Step 1 of 10`。

## 步驟一：啟動 planning file

若使用者已透過 planning-with-files skill 觸發本流程，直接沿用既有的 planning file。否則主動觸發 planning-with-files skill 建立新的 planning file。本流程資料量大且可能跨日，所有中間結論必須即時寫入 planning file 以確保可恢復性。

## 步驟二：初步問題描述

請使用者以自由形式描述：use case、預期使用場景、以及為何此時需要進行選型。將使用者的原文完整寫入 planning file，不加詮釋。

## 步驟三：產生 clarifying questions

委派 deep-thinking skill 產生 clarifying questions。提示 deep-thinking 必須涵蓋但不限於以下面向：

- 使用情境與業務背景
- 規模（資料量、QPS、使用者數、成長率）
- 預算上限與成本敏感度
- 團隊既有 AWS 經驗與學習曲線接受度
- 合規與資料主權（含 AWS region 與 AZ 選擇、data residency 要求）
- 效能 SLA 與延遲容忍度
- AWS 帳號架構（單一帳號或多帳號 Organizations 結構）
- 是否能接受 AWS-only vendor lock-in
- 整合需求（與既有 AWS 服務或既有 on-prem 系統的整合點）
- 安全需求（IAM、KMS、加密、稽核）
- Well-Architected 六支柱中的關鍵權衡
- AWS Service Quotas 是否會成為瓶頸

將 deep-thinking 產生的問題清單完整寫入 planning file，並呈現給使用者。

## 步驟四：對話式回答 clarifying questions

以每組 3 到 5 題的方式逐組呈現，根據使用者的回答動態調整後續問題；每輪答案須立即寫入 planning file。當使用者的回答揭示新的脈絡時，再次委派 deep-thinking 評估是否需要新增追問題目。

## 步驟五：彙整需求 spec

將前述所有資訊整理為結構化的 Requirement Spec，寫入 planning file，包含以下區塊：

- 背景
- 目標
- 功能性需求
- 非功能性需求
- 約束
- 評估維度（須包含 Well-Architected 六支柱中與本次相關的子項）

標註尚未明確的灰色地帶與假設。

## 步驟六：蒐集候選方案

委派 doc-research skill 並搭配 web search，蒐集 3 到 5 個候選方案。候選方案必須同時涵蓋 AWS 原生服務與主流第三方或開源方案。對每個方案記錄以下資訊並寫入 planning file：

- 方案名稱與簡介
- 官方文件 URL
- 定價模式
- 主要使用案例
- AWS Service Quotas 限制（若適用）

## 步驟七：深度分析

委派 deep-thinking skill 進行深度分析，由其自行決定使用哪些思考模型。分析目標包含：

- 每個方案的核心優勢、限制、潛在風險、長期後果
- 與步驟五各項需求的契合度
- Well-Architected 六支柱逐項的契合度
- AWS cost model 下的主要 cost driver 與相對成本方向
- 可能被忽略的盲點

將分析結果完整寫入 planning file。

## 步驟八：建立比較矩陣

整合步驟七的分析結果建立比較矩陣。矩陣欄位包含每個方案的優點、缺點、限制、風險、是否適合本次使用場景。對每個方案在每個關鍵維度上給予 1 到 10 分評分並附理由。評分維度須與步驟五彙整的需求對應，並包含 Well-Architected 六支柱中本次相關的支柱、cost direction、quota fit。

## 步驟九：推薦首選方案

明確推薦一個首選方案，並說明以下三點：

- 為何此方案優於其他候選
- 在哪些情境下推薦結論會改變
- 有哪些已知取捨需要使用者事先接受

## 步驟十：產出 HackMD 報告

透過 hackmd-notes skill 建立報告。報告章節依 `references/output-templates.md` 中模式 S 的輸出模板產出。完成後將 HackMD URL 回報給使用者。

## 共通原則

- 所有深度分析委派給 deep-thinking skill。
- 所有外部技術文件查詢委派給 doc-research skill。
- 所有 HackMD 操作透過 hackmd-notes skill。
- 所有中間結論即時寫入 planning file。
- 不假設、不腦補；有疑問即詢問使用者。
- 範圍最小化，只解決使用者描述的選型問題。
