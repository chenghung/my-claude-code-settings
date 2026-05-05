---
description: Guide the LLM through a structured 10-step technical solution survey, culminating in a HackMD comparison report. Supports multi-day sessions via a persistent planning file.
---

# Solution Survey

## 用途說明

此 command 用於進行技術方案調研（technical solution survey），例如資料庫方案選型、auto scaling 基礎設施選型、RAG vector database 方案比較等。LLM 會引導使用者完成一個結構化的 10 步驟流程，最終產出一份 HackMD 比較報告。

此流程設計成可跨越數天進行，過程中的所有討論脈絡會透過 planning file 持久化，確保中斷後可無縫繼續。

## 問候語

當使用者觸發此 command 時，LLM 必須一字不漏地對使用者說出以下問候語：

> Solution Survey Mode activated. I'll guide you through a structured 10-step solution survey. This process is designed to span multiple days — all discussion and findings will be persisted through a planning file so nothing is lost between sessions.
>
> Here's an overview of the 10 steps:
>
> - Step 1: Activate planning file
> - Step 2: Initial problem framing
> - Step 3: Generate clarifying questions via deep thinking
> - Step 4: Iterative requirement Q&A
> - Step 5: Consolidated requirement summary
> - Step 6: Collect candidate solutions
> - Step 7: Deep thinking and solution analysis
> - Step 8: Build comparison matrix and scoring
> - Step 9: Recommend a solution with justification
> - Step 10: Produce the final HackMD report
>
> Each step ends with a CHECKPOINT — I'll pause and wait for your confirmation before moving on. Let's start with Step 1.

## 執行規則

- 步驟必須**循序執行**，不得跳過或合併
- 每一個標示 **CHECKPOINT** 的步驟結束時，必須停下來等使用者回應後才能繼續
- 任何時候都必須明確標示目前所在步驟，例如以 `[Step 3/10]` 的形式呈現
- 整個流程中所有的深度思考、方案比較分析工作，必須委派給 **deep-thinking skill** 處理，由該 skill 決定要使用哪些思考模型；main agent 不得自行進行深度分析

## 流程步驟

### Step 1 — Activate Planning File

- 如果使用者是透過 **planning-with-files skill** 觸發本流程，則 planning file 已經啟用，直接使用該檔案讀寫整個討論的脈絡
- 否則，main agent 必須主動觸發 **planning-with-files skill** 建立 planning file，因為本流程資料量大、討論可能跨越數天，必須持久化

**CHECKPOINT**：等使用者確認後再進入 Step 2。

### Step 2 — Initial Problem Framing

- 請使用者用自由形式描述他要解決的技術問題、預期使用場景、以及為何在此時此刻需要進行這項調研
- 不要在這一步問結構化的約束清單，目的是讓使用者把腦中的脈絡先講出來
- 將使用者的初步描述原文寫入 planning file

**CHECKPOINT**：等使用者確認初步描述已完整後再進入 Step 3。

### Step 3 — Generate Clarifying Questions via Deep Thinking

- 將「根據使用者的初步描述，產生一份結構化的 clarifying questions」這項任務委派給 **deep-thinking skill**
- 提示 deep-thinking 的提問必須涵蓋但不限於以下面向：
  - 問題背景與動機
  - 預期規模（資料量、QPS、使用者數、成長率）
  - 預算上限與成本敏感度
  - 團隊既有技術棧與學習曲線
  - 合規與資料主權
  - 效能 SLA 與延遲容忍度
  - 運維能力與 on-call 人力
  - 可用性與災難復原要求
  - 是否能接受 vendor lock-in
  - 開源 vs 商業偏好
  - 自架 vs 託管偏好
  - 整合需求（與既有系統的整合點）
  - 安全需求（加密、稽核、權限）
  - 未來演進方向
- deep-thinking 應主動發掘使用者尚未提及但對選型結果有重大影響的隱含面向，例如業務成長假設、使用模式變化、資料生命週期等
- 將 deep-thinking 產生的問題清單寫入 planning file
- 將問題清單呈現給使用者

**CHECKPOINT**：等使用者確認問題清單合理後再進入 Step 4；使用者可要求增減問題。

### Step 4 — Iterative Requirement Q&A

- 以對話形式逐一提出 Step 3 的問題
- 不要一次傾倒所有問題，而是分組提問，每組 3 到 5 題，根據使用者回答的內容判斷是否需要追問或調整後續問題
- 每當使用者的回答揭示新的脈絡時，應再次委派 **deep-thinking skill** 評估是否需要新增追問題目
- 每一輪問答後立即將答案寫入 planning file
- 持續到所有重要面向都釐清為止

**CHECKPOINT**：在每一輪問答結束時暫停等使用者回答；當所有問題都已回答完畢，明確告知使用者進入 Step 5 彙整階段。

### Step 5 — Consolidated Requirement Summary

- 將 Step 2 到 Step 4 蒐集到的所有資訊彙整為一份結構化的 Requirement Spec，包含背景、目標、功能性需求、非功能性需求、約束、評估維度
- 標註尚未明確的灰色地帶與假設
- 將彙整結果寫入 planning file
- 將彙整結果呈現給使用者確認

**CHECKPOINT**：等使用者確認彙整無誤後再進入 Step 6；若使用者發現缺漏或誤解則退回 Step 4 補問。

### Step 6 — Collect Candidate Solutions

- 透過 web search、**doc-research skill**、官方文件查詢等方式蒐集候選方案
- 至少蒐集 **3 至 5 個候選方案**，涵蓋主流選項與值得關注的新興選項
- 對每個候選方案記錄：方案名稱、簡短介紹、官方文件連結、定價模式、主要使用案例
- 將候選清單寫入 planning file
- 提交摘要給使用者確認候選範圍是否完整或需增減

**CHECKPOINT**：等使用者確認候選清單後再進入 Step 7。

### Step 7 — Deep Thinking and Solution Analysis

- 將分析工作委派給 **deep-thinking skill**，由 skill 決定使用哪些思考模型（例如拆解、對抗、推演等）
- 分析目標包含：
  - 每個方案的核心優勢、限制、潛在風險、長期後果
  - 與 Step 5 中各項需求的契合度
  - 可能被忽略的盲點
- 將深度分析結果寫入 planning file
- 將分析摘要呈現給使用者

**CHECKPOINT**：等使用者檢視分析結果並提出補充或質疑後再進入 Step 8。

### Step 8 — Build Comparison Matrix and Scoring

- 整合 Step 7 的分析結果，建立一份比較矩陣
- 矩陣欄位包含：每個方案的優點、缺點、限制、風險、是否適合本次使用場景
- 對每個方案在每個關鍵維度上給予 **1 到 10 分**的評分，並附上評分理由
- 評分維度應與 Step 5 彙整的需求對應
- 將矩陣寫入 planning file

**CHECKPOINT**：等使用者檢視評分與權重是否合理後再進入 Step 9。

### Step 9 — Recommend a Solution

- 基於比較矩陣，**明確推薦一個首選方案**
- 說明推薦理由，包含：
  - 為何優於其他候選
  - 在哪些情境下會改變推薦
  - 有哪些已知的取捨需要使用者接受
- 將推薦寫入 planning file

**CHECKPOINT**：等使用者接受或要求調整推薦後再進入 Step 10。

### Step 10 — Produce Final HackMD Report

- 將整個調研結果整理為一份 HackMD note，透過 **hackmd-notes skill** 建立
- 報告必須包含以下章節：
  - **Background**：背景與動機
  - **Requirements**：需求與約束清單
  - **Solution Candidates**：候選方案清單，每個方案包含 brief intro、pros、cons、limitation、risk、是否適合本次需求中的使用場景
  - **Comparison Table**：每個方案在各維度的 1 到 10 分評分總覽
  - **Recommendation**：推薦哪一個方案及理由
  - **References**：列出每一個候選方案的完整參考文件 URL，包含但不限於官方文件、官方部落格、定價頁、技術白皮書、benchmark 報告、知名第三方比較文章；每一個 URL 必須標明對應的候選方案名稱，以及該 URL 的類型（例如 official docs、pricing、blog post、benchmark report 等）；這些 URL 應在 Step 6 蒐集候選方案與 Step 7 深度分析過程中累積記錄至 planning file，最終於此章節彙整呈現
- 將 HackMD note URL 回報給使用者

**CHECKPOINT**：等使用者確認最終報告無誤後流程結束。

## 共通原則

以下原則適用於整個流程：

- **深度思考**：任何深度思考、方案比較與風險分析，一律委派給 **deep-thinking skill**
- **技術文件查詢**：任何外部技術文件查詢、library 文件、API spec 研究，一律使用 **doc-research skill**
- **HackMD 操作**：任何 HackMD 操作，一律使用 **hackmd-notes skill**
- **持久化**：整個流程中所有的中間結論、使用者輸入、分析結果，必須即時寫入 planning file，避免討論中斷後失去脈絡
- **不假設**：有疑問就詢問使用者，不自行腦補填充
- **範圍最小化**：只解決使用者描述的選型問題，不擴展至其他議題
