---
name: github-review-comment-reply
description: >
  當使用者要回覆、處理或收合 PR 上 reviewer 的審查留言時觸發。在主對話層逐則分類，組裝繁體中文、結論先行的回覆，再交給 github-manager 執行張貼與 resolve。純唯讀查看留言、建立或修改 issue 或 PR 內文、與審查無關的隨手討論留言，都不觸發本 skill。觸發關鍵字：resolve reviewer comment、回覆審查留言、回覆 review、resolve conversation、address review feedback、處理 code review 留言。
---

# GitHub Review Comment Reply

## 目標

回覆並收合 PR 上 reviewer 的審查留言。分類與回覆組裝需要對話脈絡——這次改了什麼、為什麼這樣改——因此留在 main agent 主對話層；抓取留言以及張貼、resolve 等 gh 執行則下沉給 github-manager。

## 流程

main agent 在主對話層統籌四步：

1. 委派 github-manager 抓取這個 PR 未解決的 review threads 與 top-level 審查留言，取回各留言的內容、作者、所在檔案行號，以及行內 thread 的識別與 resolved 狀態。
1. 逐則把留言分類成下方三類之一。
1. 依對應模板組裝繁體中文、結論先行的回覆。
1. 交付一份清單給 github-manager 執行張貼與收合：每項標明目標留言、回覆內文，以及該行內 thread 是否要 resolve。

## 三類回覆模板

所有回覆一律繁體中文、結論先行。

### 變更請求

reviewer 要求改動時：

- 第一行寫結論：`Accepted` 或 `Rejected`。
- `Accepted`：說明依這則留言做了什麼調整；當最終作法與 reviewer 建議有落差時，補述落差與理由。
- `Rejected`：說明為何不採納。

### 提問或討論

reviewer 提問或開啟討論、而非要求改動時：直接回答，結論先行，不套 `Accepted` 或 `Rejected`。

### 共同規則：回覆是訊息回應，不是貼檔案位置

適用於全部三類：

- 回覆是對這則留言的訊息回應，不是把檔案位置丟出去。
- 需要引用程式碼時，用 repo 相對路徑（例如 `src/foo.ts:42`）或直接描述改了什麼，讓 reviewer 讀得懂。
- 禁止貼本機絕對路徑（例如 `/home/...` 開頭），也禁止把尚未 commit 的本機檔案當成請 reviewer 打開來看的 reference。

## 收合規則

- 只有「變更請求且結論為 `Accepted`」的行內 thread，回覆後才在交付清單中標記為要 resolve。
- `Rejected` 與提問討論類只回覆、不收合，把對話串留給 reviewer 回應或自行收合。
- top-level 審查留言沒有 resolve 機制，一律只回覆。

## 與日常討論留言的邊界

本 skill 只處理對 reviewer 審查留言的結構化回覆。若只是張貼一則與審查無關的隨手討論留言，不套本 skill 的三類模板、也不經本流程，直接交給 github-manager 以一般 comment 處理。
