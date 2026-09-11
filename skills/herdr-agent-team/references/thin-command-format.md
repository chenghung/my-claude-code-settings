# Thin Command 格式

thin command 是其他開發者用來定義一個 team 編制的檔案：有哪些 role、各自的候選 provider、工作起點、grant、啟動與關閉時機、完成判準——全是偏好與領域知識，不是協定細節（規格 §3）。它不提 herdr、不提腳本、不提狀態偵測、不提訊息格式或 token 詞彙，那些全部屬於這個 skill 這一層。

本檔沒有對應的解析腳本。thin command 是純文字檔，由 orchestrator（一個 AI agent）直接讀取理解；格式存在的目的是讓人類作者與 orchestrator 雙方都能穩定地讀出同一組欄位，不是給程式解析用的結構化格式。orchestrator 在兩種時機載入本檔：一是拿到一份 thin command 檔案、需要照這裡定義的欄位去讀它；二是沒有 thin command 時，需要知道該在對話裡把哪些欄位問出來。

## 兩條入口

- **有 thin command 時**：orchestrator 直接讀取檔案內容，依下面「欄位」一節逐項取出編制。讀完之後，把這份檔案的路徑寫進 `team.json` 的 `.thin_command_source` 欄位——這個欄位沒有專屬包裝腳本，直接 `source lib/common.sh` 後呼叫 `hat_json_set "$registry_root/team.json" '.thin_command_source' '"<絕對路徑>"'`（`hat_json_set` 的欄位白名單已經納入這個路徑，見 `lib/common.sh`）。
- **沒有 thin command 時**：由 orchestrator 在對話中把同一組欄位跟人類問出來。goal 四項（要達成、怎樣算成功、不做什麼、前提）一律經 `set-goal.sh` 寫進 `team.json`，見 `SKILL.md`「啟動流程」；其餘欄位（role、候選 provider、工作起點、grant、啟動與關閉時機、完成判準等）不是團隊層級的持久設定，只在 orchestrator 當下的判斷裡使用，直接化成呼叫 `launch-worker.sh` 時的參數。**這一版沒有附範例 command 檔可讀，所以第二條入口是預設路徑**，不是退路。

兩條入口取得的是同一組欄位，差別只在來源是檔案還是對話；後續怎麼用這些欄位（哪個進 `launch-worker.sh` 的參數、哪個進啟動包、哪個進契約實例）不因入口不同而不同。

## 欄位

- **team goal（預設四項）**：要達成什麼、怎樣算成功（必須是外部查得到的形式）、不做什麼、依賴哪些還沒驗證的前提。這四項只是**模板**——同一份 thin command 可能被重複觸發很多次，把目標寫死在裡面就不能重用；這一次真正生效的目標，是模板加上這次觸發時的引數與對話內容之後的實例，經 `set-goal.sh` 寫入、由人類確認（規格 §9，完整流程見 `SKILL.md`）。
- **orchestrator 的 role**：`負責`／`不負責` 兩份清單，是 orchestrator 自己internalize 的職責邊界，不寫進任何 registry 欄位。
- **workers（每個 role 一份）**：
  - `role`：這個角色的名稱，會經 `hat_normalize_name` 正規化成實際的 agent 名稱（見下方「grant 用的是正規化後的名稱」）。
  - `providers`：一個候選清單，每一項是 `kind` 加 `args` 的組合。`args` 是直通不解讀的原生引數陣列，model 型號併在裡面（例如 `["--model", "opus"]`）；orchestrator 從候選清單裡挑一個實際呼叫 `launch-worker.sh` 時使用。`kind` 必須落在 `provider-drivers.md` 的四家驅動表內，否則啟動時會被 `hat_assert_supported_kind` 以結束碼 4 拒絕。
  - `工作起點`：對應 `launch-worker.sh` 的 `--cwd`。要不要另開工作隔離區（worktree 或其他），由 worker 自己決定，thin command 只給起點目錄。
  - `權威來源`：一個 locator（規格 §7：中性字串，skill 從不打開它），有牴觸時以它為準。寫進啟動包「02 任務」一節，見 `briefing-template.md`。
  - `參考材料`：選填、不具約束力的 locator，同樣寫進啟動包「02 任務」。
  - `交付點`、`終點`、`完成判準`：worker 啟動成功之後，由 orchestrator 呼叫 `set-worker-field.sh --to <worker> --field <delivery_point|end_point|completion_criteria> --value <內容>`，把這三項分別寫進 `workers/<name>.json` 對應的 `.delivery_point`、`.end_point`、`.completion_criteria`。這支腳本帶完整入口守衛（workspace 邊界、名稱格式驗證），且自己再帶一層只放行這三個欄位加 `.stage` 的白名單，不透過任何繞過守衛的路徑寫入。**完成判準必須是外部查得到的形式**，理由見下方 callout。
  - `啟動時機`、`關閉時機`：orchestrator 自己的排程判斷，不持久化。
- **grant**：哪個 role 可以聯繫哪個 role，格式是一組雙向或單向的配對（範例用 `↔` 表示雙向）。落地時對每一邊各呼叫一次 `grant-peer.sh --from <A> --to <B>`。
- **回報前的嘗試次數 N**：整數，餵給 `worker-contract.md` 組裝這個 role 的契約實例時代入 `{{N=3}}` 的位置；沒有指定時沿用契約全文預設的 3。

> **寫得出來，這個 role 就能被安全關閉**
>
> **「完成判準」那一行必須是外部查得到的形式。**
>
> 寫不出來本身就是訊號——orchestrator 看不到開發內容，所以「完成」不能靠自我宣告；那代表這個 role 沒辦法被安全關閉，得先改設計讓產物落到查得到的地方（例如一個檔案存在、一個 PR 已合併、一個測試套件通過），而不是「worker 自己說做完了」。

## grant 用的是正規化後的名稱

thin command 裡的 `grant` 配對寫的是 role 名稱（例如 `ux-designer`、`architect`），但 `grant-peer.sh --from`／`--to` 認得的是 `hat_normalize_name` 正規化之後的實際 agent 名稱（例如 `w3n-ux-designer`）——那個名稱要等對應的 worker 真的啟動過一次才確定存在。落地 grant 之前，先確認雙方都已經在 `workers/` 底下有記錄，再用正規化後的名稱呼叫 `grant-peer.sh`，不要直接把 thin command 裡的原始 role 字串當成 `--from`／`--to` 傳進去。

## 候選清單 ≠ 驅動表

**候選清單**（這個 role 可以用哪幾家 provider）是編制決定，屬 thin command。**驅動表**（每一家怎麼開、怎麼判就緒、快速核准旗標實際值）是事實，屬 `provider-drivers.md`。挑選候選清單時要參考驅動表決定要不要納入某個低保真 kind，但驅動表本身不重複抄進 thin command——散進每份 command 會抄成 N 份，漏改的那份不會報錯。

## 範例

以下取自規格 §14 的範例，一個從產品構想產出 PRD 與 mockup 的團隊，整份檔案沒有一個字提到 herdr、腳本、狀態偵測、訊息格式或 token 詞彙。**與規格原文有一處刻意的出入**：ux-designer 的 agy 候選項補上了 `--dangerously-skip-permissions`——`provider-drivers.md`「agy alias 陷阱」一節明講不給這個旗標，agy worker 會卡在啟動後第一個權限框，而且因為 agy 沒有正向 idle 規則，那個狀態在 herdr 眼中只是「閒置」，不會有任何錯誤訊息。這份範例是留給人抄的範本，照抄規格原文的版本就是把自己文件裡警告過的陷阱原樣複製一次，因此這裡直接補上，其餘部分維持逐字：

```text
---
name: prd-team
description: 從一個產品構想產出 PRD 與 mockup
---

# team goal（預設，觸發時可用引數或對話覆寫，見 §9）
要達成: 把一個產品構想做成可以交給工程團隊的 PRD 與 mockup
怎樣算成功: docs/prd/ 下同時有 mockup.md 與 tech-scope.md，且 PRD 主文引用到這兩份
不做: 實作程式碼、開工程 issue
前提: 產品方向已經定了，這次不重新討論要不要做

# orchestrator
role: product-manager
負責: 決定產品方向、裁決衝突、把各方產物整合成 PRD
不負責: 自己寫任何一節內容、讀 worker 的草稿全文

# workers

role: ux-designer
  providers:                        # orchestrator 從這裡自選
    - kind: claude
      args: ["--permission-mode", "auto", "--model", "haiku"]
    - kind: agy
      args: ["--model", "flash", "--dangerously-skip-permissions"]     # 低保真 kind：啟動時會告知失去哪兩種偵測；旗標見 provider-drivers.md「agy alias 陷阱」
  工作起點: docs/prd/           # 要不要另開隔離區，worker 自己決定
  權威來源: trello://card/8fK2   # locator，skill 不解析
  參考材料: docs/research/*.md
  交付點: mockup 產出
  終點: PM 宣告 PRD 定稿
  完成判準: docs/prd/mockup.md 存在且含「畫面清單」一節

role: architect
  providers:
    - kind: claude
      args: ["--permission-mode", "auto", "--model", "opus"]
    - kind: codex
      args: ["-s", "workspace-write", "-m", "gpt-5.6-terra"]
  工作起點: .                   # 繼承 orchestrator 的目錄
  權威來源: github://issue/412
  交付點: 技術邊界文件產出
  終點: PM 宣告 PRD 定稿
  完成判準: docs/prd/tech-scope.md 存在且含四個小節

# 啟動時機
- 構想確立後，同時啟動 ux-designer 與 architect

# 關閉時機
- 交付點到了不關，PM 整合時可能要求調整
- PRD 定稿後依序關閉，各自附交接檔

# grant
- ux-designer ↔ architect  # 畫面與技術邊界互相依賴，PM 答不了

# 回報前的嘗試次數
N: 3
```
