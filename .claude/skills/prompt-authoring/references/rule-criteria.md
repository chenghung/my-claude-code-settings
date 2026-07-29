# Rule Criteria

本檔是 `rules/`、`.claude/rules/` 目錄下 rule 定義檔，以及各層 `CLAUDE.md` 的專屬判準，與 `shared-criteria.md` 一併載入。

## Residency Cost

`rules/` 與 `.claude/rules/` 下的檔案會被 main agent 永久載入，因此每條 rule 都必須通過一個問題：不論當前任務為何，這條內容都需要嗎？答案為否者，屬於應降級為 skill 或 subagent 定義的內容，列為 finding。

本節與 `shared-criteria.md` 的 `Content Necessity` 是遞進的兩層判斷，不是同一個問題問兩次：`Content Necessity` 檢驗「這段內容該不該存在於任何 prompt 定義檔中」，答案為否就整段刪除；本節檢驗的是「這段內容如果該存在，是否該以常駐姿態載入 main agent context」，答案為否不是刪除，而是搬遷——移到只在特定情境才會被載入的 skill 或 subagent 定義中。一段內容可以同時通過 `Content Necessity`（值得寫）卻通不過本節（不該常駐）。

應留在 rule 的內容類型：

- routing 邏輯，例如依任務類型決定要委派給哪個 subagent
- 全域行為準則，不論當前任務為何都適用的行為要求

不得放入 rule 的內容類型：

- 只在特定情境才需要的格式細節
- 語法說明
- CLI 參數規格

自我檢測：換一個與這條內容完全不相干的任務，模型會不會因為少了它而做錯？答案為否即為 finding。

## Single Source

同一條規則不得同時存在於多個會被同時載入的檔案中。

檢查方式：對受審查檔案中的規則，取其關鍵詞在 `agents/`、`skills/`、`rules/`、`commands/`、`.claude/agents/`、`.claude/skills/`、`.claude/rules/`、`CLAUDE.md` 範圍內跨檔搜尋，確認沒有第二處在講同一件事。

```bash
rg -n '<關鍵詞>' agents/ skills/ rules/ commands/ .claude/agents/ .claude/skills/ .claude/rules/ CLAUDE.md
```

例外：不同層級之間（rule 對 subagent 對 skill）的重複，若是為了避免污染 main agent context 而刻意保留，不算違反；同層級之間的重複（rule 對 rule、subagent 對 subagent、skill 對 skill）一律算違反。

**Subagent 結構性重複的窄豁免**：同層級一律算違反的原則，對 subagent 對 subagent 有一個窄豁免。每份 subagent 定義檔是獨立、完整載入的 prompt，沒有 include 機制，角色同構的兩份定義檔在 `Input from Main Agent`、`Boundary and Failure Behavior`、`Output to Main Agent` 三個章節裡，描述通用輸入欄位、通用失敗處置、通用回傳欄位的部分必然相似，此類結構性內容不算違反。豁免不涵蓋判準內容本身：若兩份定義檔在這三個章節裡各自複製了同一條判準的實質規則（例如都完整重述某個面向的判斷標準或門檻，而非引用判準檔的對應章節），仍算違反，應改為指向判準檔。

自我檢測：這條規則的關鍵詞，在同層級的其他檔案裡搜得到第二次命中嗎？搜到即為 finding；若命中落在上述三個章節內，進一步問——拿掉判準名稱與面向指稱後，剩下的是「必填/選填」「缺什麼就停止」這類共通樣板，還是可獨立成立的判斷規則或門檻？前者屬豁免範圍不算 finding，後者仍算 finding。

## Conflict

檢查方式：找出同一情境下會導向不同行為的兩條規則。

常見衝突形態三種：

- 同一個動作，一處要求委派、另一處要求自行處理
- 同一個對象，一處納入範圍、另一處排除
- 同一個判斷，一處給硬性門檻、另一處給裁量空間

自我檢測：把兩條規則套在同一個具體情境上，模型會不會被要求同時做兩件互斥的事？
