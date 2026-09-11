# Provider 驅動表

本檔記載 `herdr-agent-team` 支援的四家 provider 的實測事實：偵測規則的保真度、快速核准旗標、以及啟動就緒的已知落差。這些都是規格 §5、2.1、2.5 對真實 herdr 0.8.2 與四家 CLI 的量測結果，不是理論推導。orchestrator 在挑選或驗證某個 role 的 provider、或處理啟動框代按時載入本檔；thin command 作者在決定某個 role 要開放哪些候選 provider 時也應該讀這裡，而不是自己去猜每家的旗標。

清單外的 kind（herdr 認得的其餘十八種）一律在啟動之前就被 `lib/common.sh` 的 `hat_assert_supported_kind` 拒絕，結束碼 4，訊息點名這四家。原因不是保守：`omp`、`mastracode` 這類 kind 連狀態偵測規則檔都沒有，它們的 worker 會永遠顯示 `idle`，而 watchdog 會持續對一個其實卡住的 worker 送出「繼續」——使用者只看得到一個一直被推卻沒有進展的東西，看不出原因。四家之外沒有例外，thin command 寫了不支援的 kind 就是啟動失敗，不是靜默降級。

## 驅動表

| kind | 保真度 | 規則數 | 正向 idle 規則 | 有 unknown | 快速核准旗標 | 無引數啟動就緒 |
| --- | --- | --- | --- | --- | --- | --- |
| claude | 高 | 16 | 3 條 | 有 | `--permission-mode auto` | 沿用 epic-orchestration 既有實務 |
| codex | 高 | 9 | 1 條 | 有 | `--dangerously-bypass-approvals-and-sandbox` | 已實測以 `agent_not_ready` 失敗——herdr 回的錯誤訊息是該 agent 在啟動過程中處於 `blocked`、尚未準備好接受 prompt，成因見下方「codex 的更新框」 |
| agy | 低 | 3 | 無 | 無 | `--dangerously-skip-permissions` | 已實測結束碼 0 即就緒 |
| opencode | 低 | 3 | 無 | 無 | `--auto` | 已實測結束碼 0 即就緒 |

「保真度」對應 `lib/common.sh` 的 `hat_kind_fidelity`：claude、codex 印 `high`，agy、opencode 印 `low`。「規則數」與「正向 idle 規則」是 herdr 對每個 kind 的偵測規則檔（`~/.local/state/herdr/agent-detection/remote/<kind>.toml`）離線量測的結果，用 `herdr agent explain --file <路徑> --agent <kind>` 對任意快照跑一次就看得到逐條比對，不必真的起一個 worker。

**保真度分級不改變 role 與 provider 的自由組合。** 任何 role 都可以指定任何一家作候選；分級只改變 skill 在低保真 kind 上要多開一道回報靜默逾時（見下方「低保真的後果」）。理由是 2.2 的實測：`working` 在真實回合中是穩的（claude、agy、opencode 三家都做過連續取樣，沒有觀察到抖動），低保真 kind 承擔得起長任務；不穩的只有「沒有事情發生時它到底停了沒」，而那件事逾時接得住。

快速核准旗標欄位僅供 thin command 作者參考——`lib/common.sh` 與四支腳本都不驗證原生引數的語意，`args` 直通不解讀，作者自己決定要不要用它。codex 另提供兩種更保守的選擇：`-a` 或 `--ask-for-approval` 帶核准政策、`-s` 或 `--sandbox` 帶沙箱模式；選哪一種是 role 的偏好，不是 skill 的判斷。所有原生引數在 `launch-worker.sh` 呼叫 `herdr agent start` 時接在 `--` 之後逐一展開，不做任何額外組裝。

## 三件事

### 一、低保真的後果

`agy` 與 `opencode` 的 `idle` 不帶正向證據——它們的偵測規則檔完全沒有正向 idle 規則，字面意思是「三條規則都沒命中」的預設 fallback，不是「worker 確實停下」的證明。這兩家因此必須依賴 `watchdog.sh` 的停滯偵測（`AGENT_TEAM_STALL_SECONDS`，見下）接住兩種只有它們會漏接的失效：「worker 違約沒回報就停下」與「原地繞圈」。啟動這兩家的 worker 時，事件流裡要明確告知失去了這兩種偵測，讓使用者知道保真度降級不是隱性的。

### 二、agy alias 陷阱

這台機器上互動使用的 `agy` 是一個 shell alias，內容是 `agy --dangerously-skip-permissions`。`herdr agent start` 不經過使用者的互動 shell，是直接執行使用者家目錄底下 `.local/bin/agy` 這個真實二進位，alias 完全不會生效。因此 `--dangerously-skip-permissions` 這個旗標必須由 thin command 或呼叫端在原生引數裡明確給出、送到 `--` 之後。不給的話，agy worker 會停在啟動後第一個權限框前面；而因為 agy 沒有正向 idle 規則，那個狀態在 herdr 眼中只是「閒置」，不會有任何錯誤訊息指出真正原因。

### 三、啟動框允許清單目前只有一筆

`lib/common.sh` 的 `hat_approval_allowlist` 是 `press-approval.sh` 在 `--startup` 模式下查詢的允許清單，目前只登記一條：`startup_update`（codex 的版本更新提示，herdr 規則優先度 950），對應按鍵 `2`（Skip）。這是唯一已實測會撞到的啟動框（codex 的更新提示是週期性、不是一次性的，任何一次啟動都可能再遇到）；其餘三家的啟動框（登入過期、首次執行導覽、版本遷移提示）尚未撞見過，也不假設它們長什麼樣。

**清單外的規則名、`unknown` 分類、或規則名對得上但清單沒載明按鍵，三者一律升級給人，不代按**——`hat_approval_allowlist` 的介面就是為了把這三種收斂成同一個判斷：沒有回傳 0 並印出一個非空字串，就是「無法確定」。清單短不是安全問題，只是會比較常停下來問人；清單絕不能改成「擋掉已知的壞的、其餘放行」，那會對沒見過的框照按不誤。

**遇到新的啟動框時**：先確認它真的是啟動階段（`agent start` 之後、第一則 ACK 之前）撞到的框，而不是執行中途的核准框（那一類走 `press-approval.sh` 不帶 `--startup` 的路徑，見 `SKILL.md`「派調查者的時機」）；確認之後，把規則名與要按的鍵一併加進 `hat_approval_allowlist` 的 `case` 分支，並同步更新本檔這一節的清單說明，兩處一起改——只改程式碼、不改這份文件，會讓下一個讀者以為清單仍然只有一筆。

## 三個門檻值與低保真的關聯

`watchdog.sh` 的 `AGENT_TEAM_STALL_SECONDS`（預設 1800 秒，可覆寫）是低保真 kind 唯一的失效偵測手段，統一套用在四家 worker 上，不因為 kind 是低保真就另外調整門檻——目前沒有材料支持一個更精細的數字。門檻值本身沒有實測依據，是私用階段的起點，完整說明見 `SKILL.md`「門檻值」一節，本檔不重複。
