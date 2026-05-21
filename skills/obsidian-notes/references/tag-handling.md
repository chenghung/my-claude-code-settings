---
name: tag-handling
description: obsidian-notes skill 的 tag 自動決策協定，定義建立與更新筆記時的 tag 處理流程
---

# Tag 自動決策協定

## 觸發條件

本協定僅在 SKILL.md 將 main agent 引導至本檔案時生效。外部觸發判準由 SKILL.md 負責；本檔案內部則進一步處理 Create 與 Update 兩種情境的細節決策。

## 核心原則

1. **優先重用既有 tag**：vault 中已有的 tag 應優先沿用，避免產生同義詞重複與 tag 體系膨脹
1. **委派取得 tag 清單**：查詢現有 vault tag 清單必須委派 obsidian-manager 執行，main agent 不得憑記憶猜測 vault 內存在哪些 tag
1. **回報所有自動決策**：任何自動產生的 tag 都必須回報給使用者，讓使用者有機會撤回或更正

## 信心判準

### 高信心

符合下列全部條件：

- Tag 對應的主題在筆記內容中有**多處明確指涉**
- 該 tag 在 vault 中已有穩固的使用脈絡，是該主題的 canonical tag

### 低信心

符合下列任一條件：

- Tag 對應的主題在筆記中只是**順帶提及**
- 該 tag 在 vault 中很少使用、用法不穩定
- 筆記內容語意模糊，可能對應到多個近義 tag

### 對照範例

**範例一（高信心）**：筆記主題是 React 效能優化，內容多處提及 React、useMemo、re-rendering、虛擬 DOM。Vault 中 `react` tag 已被使用 30 次，是該主題的 canonical tag。→ 高信心，可直接套用。

**範例二（低信心）**：筆記主題是週末規劃，內容中只有一句話順帶提到自己用 Notion 紀錄。Vault 中 `productivity-tools` tag 雖被用過 5 次，但用法不一致。→ 低信心，列為候選等待使用者確認。

**範例三（高信心 vs 低信心並存）**：筆記主題是 Kubernetes 部署實務，內容大量討論 Pod、Deployment、ConfigMap。Vault 中 `kubernetes` tag 使用 20 次（高信心），另有一段順帶提到 Helm chart 語法，vault 中 `helm` tag 只出現 2 次（低信心）。→ `kubernetes` 直接套用，`helm` 列為候選。

## Create 流程

### 使用者完全未指定 tag

1. 委派 obsidian-manager 取得現有 vault tag 清單
1. Main agent 根據筆記內容與 tag 清單，將候選 tag 分為三類：
   - **高信心 tag**：符合高信心判準的既有 tag
   - **低信心 tag**：符合低信心判準的既有 tag
   - **NEW tag 建議**：現有 tag 池無法涵蓋的主要主題（詳見 NEW tag 政策）
1. 高信心 tag 直接寫入 frontmatter；低信心 tag 與 NEW tag 列出來請使用者確認
1. 回報給使用者，必須包含：
   - 直接套用了哪些 tag 及對應理由
   - 等待確認的低信心 tag 與 NEW tag 候選

### 使用者只給部分 tag

1. 保留使用者提供的所有 tag，**絕不修改或刪除**
1. 委派 obsidian-manager 取得現有 vault tag 清單，針對使用者未涵蓋的主題面向提出互補 tag 建議
1. **不直接套用**任何 main agent 自行決定的 tag，所有互補建議列出來請使用者確認

> [!NOTE]
> 使用者已表達 tag 偏好時，main agent 應更保守，僅提案不直接套用。此分支與完全未指定分支的關鍵差異在於：有使用者意圖存在時，高信心 tag 亦不直接寫入。

## Update 流程

### 步驟一：判定是否屬於主題擴展

依據實際內容變動判斷，而非僅依賴使用者的 prompt 描述：

- 讀取筆記更新前的內容
- 檢視即將套用的變更
- 計算內容 delta 中是否出現原本沒有的主題關鍵詞或新概念

若 delta 只是錯字修正、潤飾、格式調整、原有概念的局部改寫，**不觸發**後續 tag 評估。

**不應觸發 tag 評估的負面範例：**

- 修正「使用」誤植為「使月」這類錯字
- 把一個句子改寫得更通順，但意思不變
- 調整 bullet list 的縮排層級
- 把一段文字改成 callout 區塊，內容不變

### 步驟二：取得現有資訊

判定為主題擴展後，委派 obsidian-manager 取得：

- 現有 vault tag 清單
- 筆記目前已有的 tag

### 步驟三：評估 tag

依據信心判準，評估新增主題是否需要補充 tag 到此筆記。

### 步驟四：回報

明確區分以下情境，每種情境都必須向使用者說明，不得無聲跳過：

| 情境 | 說明 |
| --- | --- |
| 建議新增高信心 tag，已直接套用 | 說明套用了什麼及原因 |
| 建議新增低信心 tag 或 NEW tag | 列出候選等使用者確認 |
| 評估後現有 tag 仍足以涵蓋，無需變動 | 明確告知使用者評估已完成、結論為 no change |

## NEW tag 政策

### 允許建議 NEW tag 的條件

現有 vault tag 池中**沒有任何 tag 能涵蓋筆記中的主要主題之一**時，才允許建議 NEW tag。若只是內容中某個次要面向沒有對應 tag，不應建議 NEW tag。

### 標示方式

所有 NEW tag 候選在呈現給使用者時必須以 `NEW:` 前綴明確標記，例如：

```text
NEW: #machine-learning
```

避免使用者誤以為是既有 tag。

### 為何必須使用者確認

即使是高信心情境，新建 tag 也需要使用者確認，不得直接寫入。原因是避免 vault tag 體系膨脹與同義詞污染——使用者對整個 vault 的 tag 架構有最終決策權。

## 回報格式

每次 tag 決策完成後，回報給使用者的資訊至少須包含以下欄位：

- **直接套用的 tag**：清單與每個 tag 的套用理由
- **等待確認的低信心 tag 候選**：清單與每個 tag 的判斷理由
- **等待確認的 NEW tag 候選**：清單（須有 `NEW:` 前綴）與建議理由
- **no change 結論**：若評估後無需變動 tag，明確告知使用者「已評估，現有 tag 無需調整」
