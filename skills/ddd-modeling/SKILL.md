---
name: ddd-modeling
description: >
  領域驅動設計（DDD, Domain-Driven Design）建模流程。當討論一個 business-domain-heavy
  的新需求或改動既有需求、需要在實作前先做領域建模，或使用者明確要求做 DDD 建模、
  event storming、bounded context 或 aggregate 設計時觸發，產出語言中立的模型文件供後續
  implement design follow。單純 CRUD、純技術性任務或純唯讀解說既有程式碼不觸發。
  觸發關鍵字：DDD、領域驅動設計、domain modeling、領域建模、event storming、事件風暴、
  bounded context、aggregate、戰略設計、戰術設計、ubiquitous language。
---

# DDD Modeling Skill

## 定位

此 skill 是 DDD 領域建模的統一入口，只負責觸發判斷、需求規模評估、加權派工、收斂迴圈與最終交付。實際建模與審查全部委派給三個 subagent：`ddd-strategic-modeler` 做戰略建模、`ddd-tactical-modeler` 做戰術建模、`ddd-model-reviewer` 做獨立審查。main agent 不自行建模，也不自行審查，並盡量不把 DDD 過程的內容吸進自己的 context，最終只持有各模型檔的路徑。

此 skill 產出的是語言中立的 markdown 模型文件，作為下游 implement design 的輸入。本 skill 不產生程式碼，也不預設接任何特定下游流程。

## 觸發時機

應觸發：

- 討論一個 business-domain-heavy 的新需求，值得在實作前先建模
- 改動既有需求且涉及領域邏輯的重新建模
- 使用者明確要求 DDD 建模、event storming、bounded context 或 aggregate 設計

不應觸發：

- 單純 CRUD 或純技術性任務，無豐富領域邏輯
- 純唯讀解說既有程式碼
- 明顯不是領域建模的任務

## 執行流程

1. **評估需求**：由 main agent 內部執行，輸出限制在三到五行，釐清核心領域問題、是否 domain-heavy、屬 greenfield 或 brownfield、需求規模，據此決定戰略與戰術的加權。
1. **補齊 context（條件式）**：僅在存在明顯阻塞的未知時，用 AskUserQuestion 一次問最關鍵的問題；否則自主推進。brownfield 情境於派工時要求 subagent 先依循既有建模。
1. **加權派工**：依需求規模決定跑哪些 subagent、跑多深，此為軟性判準，由 main agent 視個案決定。委派 `ddd-strategic-modeler` 與 `ddd-tactical-modeler` 時各給一個目標寫檔路徑；`ddd-tactical-modeler` 若在戰略之後執行，於 prompt 提供戰略模型檔路徑供其在既定邊界內建模。
1. **審查**：委派 `ddd-model-reviewer` 讀兩份模型檔，回傳判定與 findings。
1. **收斂迴圈**：若判定 `changes-recommended`，將 findings 中歸屬戰略或戰術的部分退回對應的建模 subagent 修正其模型檔，再重審。回合數需有節制，多輪仍不收斂時由 main agent 停下，把剩餘衝突呈報使用者。
1. **交付**：把各模型檔案路徑與審查結論交給使用者。

## 加權判準

依需求規模決定戰略與戰術的投入，以下為軟性參考：

- 需求大而模糊，或涉及多個 bounded context：完整戰略，再戰術，戰術在戰略界定的邊界內建模
- 需求中等且邊界大致清楚：輕量戰略確認邊界與語言，加完整戰術
- 需求小而明確且屬單一 context：可略過戰略，直接戰術

## 互動限制

subagent 無狀態且一次性，無法在任務中途反過來與使用者來回問答。因此需要與領域專家釐清的協作只能發生在此 skill 這一層：main agent 先把需求脈絡問夠再一次性派工。subagent 卡在模糊處時是回報需要澄清，由 main agent 轉達使用者，而非 subagent 直接詢問。

## 委派 Prompt 要求

委派各 subagent 時，prompt 必須包含：

- 完整的需求脈絡（subagent 無狀態，需重新提供）
- 該 subagent 的目標寫檔路徑（戰略與戰術各一）
- brownfield 情境下要依循既有建模的指示，以及既有模型或程式碼的位置
- 戰術於戰略之後執行時，戰略模型檔的路徑

prompt 只描述目標與所需事實，不指定 subagent 內部該用哪個建模方法或工具。

## 產物落點

戰略與戰術各產出一份語言中立的 markdown 模型檔，預設寫到當前工作專案的 docs 位置，使用者可於觸發時指定路徑；過程中的中間 scratch 依 `tmp-file-usage` rule 使用暫存區。

## 輸出格式

main agent 最終回應使用者時包含：

- 各模型檔案的路徑
- 審查判定（`pass` 或經修正後收斂）與簡短摘要
- 若未能收斂，明確標示未解的衝突，交由使用者裁決
