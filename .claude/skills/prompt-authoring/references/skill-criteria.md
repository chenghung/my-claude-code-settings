# Skill Criteria

本檔是 `skills/`、`.claude/skills/` 目錄下 skill 定義檔的專屬判準，與 `shared-criteria.md` 一併載入。

## Progressive Disclosure

本節不對 `SKILL.md` 設行數門檻：行數門檻本身是一條與內容脫鉤的固定數字規則，落在 `shared-criteria.md` `Mandatory Wording Classification` 的第三類（行為指引或風格偏好），反例測試會問「拿掉這條門檻，模型最可能怎麼做錯」——答案因 skill 複雜度而異，說不出單一具體失敗場景，通不過第三類的保留檢驗。改用三個可用是或否回答的檢測：

1. `SKILL.md` 裡的細節判準——具體規則、清單、操作步驟等內容——是否只有單一分支會用到、其他分支用不到？是的話應下放到 reference。分支路由（例如 `Mode Selection`、`File Type Routing` 等用來決定該走哪條分支的判斷邏輯）與流程骨架（例如 `Authoring Flow`、`Review Flow`、`Findings Grading and Adoption`、`Convergence` 等描述某條分支底下流程如何進行、彼此如何銜接的章節）不是細節判準，不受此檢測約束——即使骨架內容只在特定分支下執行（例如某段只適用撰寫模式），它定義的正是「這條分支要做什麼」，本身就是分支結構的一部分，沒有可抽離的下放對象。
1. 是否存在從未被 `SKILL.md` 指向的 reference 檔案？有的話屬於無用負擔。
1. `SKILL.md` 指向的 reference 是否都實際存在？否則屬於幻覺引用。

可執行的檢查方式：以 `rg` 取出 `SKILL.md` 中所有 `references/` 字樣的引用，與 `ls references/` 的實際檔案清單雙向比對。

```bash
rg -o 'references/[a-z-]+\.md' SKILL.md | sort -u
ls references/
```

`SKILL.md` 有指向但 `ls` 結果沒有的檔名，即檢測 3 的幻覺引用；`ls` 結果有但 `SKILL.md` 沒指向的檔名，即檢測 2 的無用負擔。

## Trigger Description

skill 的 description 是唯一決定它會不會被觸發的依據。觸發與不觸發情境是否成對寫出，已由 `shared-criteria.md` 的 `Safety Boundary` 檢查涵蓋，本節不重複。本節檢查另外兩項：

- **客觀事實優於語意判斷**：觸發條件是可機械判定的客觀事實（例如檔案路徑、副檔名），還是需要語意判斷的模糊描述？前者優於後者——語意判斷留給模型自由心證的空間越大，跨次執行的觸發結果越不穩定。
- **與其他 skill 的觸發範圍是否重疊**：重疊即為規則衝突來源，兩個 skill 同時符合觸發條件時，模型無法判斷該呼叫哪一個。

自我檢測：逐條列出本 skill description 中的觸發條件，能否分類為「客觀事實」或「語意判斷」；再與同倉庫其他 skill 的 description 比對，是否有相同或包含關係的觸發範圍。

## Structure

skill 目錄結構慣例：`SKILL.md` 為主檔，置於 skill 目錄根；細節檔置於 `references/` 子目錄。`SKILL.md` 須以表格或等效形式明確寫出每份 reference 的載入時機，不可只放檔名清單而不寫時機。

自我檢測：讀者能否只看 `SKILL.md`、不必打開任何 reference 本體，就判斷出「這份 reference 什麼時候該載入」？只有檔名清單、沒有時機說明，視為不通過。
