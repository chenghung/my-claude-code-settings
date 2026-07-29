---
name: prompt-authoring
description: >
  當要建立或修改 prompt 定義檔，或要審查 prompt 定義檔時觸發。受管的 prompt 定義檔是位於
  agents、skills、rules、commands、.claude/agents、.claude/skills、.claude/rules 七個目錄下的
  定義檔，以及各層的 CLAUDE.md。不應觸發：一般 markdown 文件、程式碼、GitHub issue 與 PR 的
  標題及內文、設計文件與實作計畫。觸發關鍵字：prompt 定義檔、subagent 定義、skill 定義、rule
  定義、agent 規格、prompt 審查、prompt 品質。
---

本 skill 統一本倉庫 prompt 定義檔的撰寫與審查判準。判準只有一份，存放在 `references/` 下；撰寫與審查不是兩套標準，而是同一份判準的兩種用法——撰寫時當規格遵守，審查時當檢查表核對。因此凡是撰寫時被要求做到的，審查時就會被逐項檢查；審查挑出的問題，也必然能在同一份判準中找到出處。

## Mode Selection

第一層分支，先判斷本次屬於哪一種模式：

- **撰寫模式**：本次要建立或修改受管的 prompt 定義檔。
- **審查模式**：只對既有 prompt 定義檔給出 findings，不修改任何檔案。

兩種模式導向同一批 reference，差異只在使用方式：撰寫模式把 reference 當規格遵守，審查模式把 reference 當檢查表逐項核對。

## File Type Routing

第二層分支，依目標檔案路徑決定要載入哪幾份 reference：

| Reference | 載入時機 |
| --- | --- |
| `references/shared-criteria.md` | 任何模式、任何檔案類型都載入 |
| `references/agent-criteria.md` | 目標檔案位於 `agents/` 或 `.claude/agents/` |
| `references/skill-criteria.md` | 目標檔案位於 `skills/` 或 `.claude/skills/` |
| `references/rule-criteria.md` | 目標檔案位於 `rules/` 或 `.claude/rules/`，或目標檔案為任一層的 `CLAUDE.md` |
| `references/command-criteria.md` | 目標檔案位於 `commands/` |

一次任務涉及多種檔案類型時，載入所有命中的 reference。

## Authoring Flow

撰寫模式的流程如下：

- **委派撰寫**：實際的撰寫工作委派給 `prompt-author`，main agent 不自行編輯 prompt 定義檔。
- **撰寫者與審查者必須是不同的 subagent**：不得由 `prompt-author` 審查自己剛產出的內容。此規定屬於 `references/shared-criteria.md` 三分類中的第二類（順序敏感的副作用檢查點）——撰寫者審查自己的產出存在自我偏誤，被偏誤放過的問題會直接進入 commit，該後果在單次流程內無法自我修正。
- **平行委派三個審查端 subagent**：撰寫完成後，同時委派下列三者，各自只取得目標檔案與自身視角的判準，不得取得其他審查者的 findings，以維持視角互相盲目：
  - `prompt-compliance-reviewer`：內容軸與措辭軸中，除另兩者負責面向、以及其定義檔 `Out of Scope` 逐節列舉的格式類章節外的全部，含幻覺引用與跨檔案單一來源。
  - `prompt-constraint-auditor`：強制措辭三分類、規則衝突。
  - `prompt-boundary-auditor`：安全邊界、輸入輸出適當性、驗收模糊性。
- **合併去重後交回撰寫端**：三者回傳的 findings 由 main agent 合併，指向同一位置且同一問題的重複 findings 併為一則，再交回 `prompt-author` 處理。

## Review Flow

審查模式跳過撰寫階段，直接平行委派上述三個審查端 subagent，findings 合併去重後回報使用者。審查模式不進入迭代、不修改任何檔案。

## Findings Grading and Adoption

分級與採納規則，兩種模式都適用。

must-fix 的判定範圍限定為以下四種，不得自行擴充：

- 安全邊界缺失
- 假的保證：屬三分類第一類的安全或權限硬邊界，宣稱強制執行但沒有 hook 或 permission 設定支撐。第二類順序敏感副作用檢查點不要求執行機制，無 hook 支撐不列 must-fix
- 規則之間直接衝突
- 幻覺引用：引用不存在的檔案、工具或功能

不屬於上述四種者，一律歸為 nice-to-have。

每則 nice-to-have 必須附 0 到 100 的推薦採納分數，給分落在兩軸：

- **不採納會導致什麼具體失敗場景**：說不出具體場景者一律 40 分以下。
- **修改幅度與連帶影響**：幅度越大、牽動越多其他檔案，分數越低。

撰寫端的預設處置：分數 70 含以上採納並修改，未達 70 記錄但不修改。允許偏離此預設，但偏離時必須附理由並回報，不得靜默偏離。

## Convergence

迭代收斂條件，只適用於撰寫模式。

- 迭代上限 5 輪，每跑一次審查算一輪。
- **收斂出口**：某一輪審查回傳的 must-fix 為 0，且該輪沒有分數 70 含以上的 nice-to-have 被採納，即判定收斂，回報結果並結束迭代。第 1 輪就達成此條件同樣算收斂，不視為失敗。
- **採納後的驗證輪**：must-fix 為 0 但該輪有分數 70 含以上的 nice-to-have 被採納時，改完後再跑一輪審查驗證改動。該輪 must-fix 仍為 0 即結束迭代，不論是否又出現新的 nice-to-have——nice-to-have 不構成繼續迭代的理由。該輪若出現新的 must-fix，修正後再驗證一次，仍未歸零則走失敗出口。
- **續跑條件**：must-fix 未歸零時，每輪數量須較前一輪下降。
- **失敗出口**：must-fix 未歸零且數量停滯不再下降，或跑滿 5 輪仍有剩餘 must-fix，停止迭代，回報剩餘 findings 交人類判斷，不再自行嘗試。
