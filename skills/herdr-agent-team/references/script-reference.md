# 腳本參考

本檔由 orchestrator 在任何腳本非 0 結束，或輸出出現 `SKILL.md` 未說明的格式，或要覆寫門檻時載入。

## 腳本一覽

`HERDR_ENV` 不等於 `1` 時，所有腳本一律以結束碼 `3` 結束。九個結束碼所有腳本共用同一組語意：

| 碼 | 意義 |
| --- | --- |
| 0 | 成功 |
| 1 | 個別腳本自行產生的部分失敗或迴圈異常 |
| 2 | 呼叫端用錯：缺必填參數、參數格式不對 |
| 3 | 環境前提不成立：`HERDR_ENV` 不等於 `1` |
| 4 | 守衛不通過（workspace 邊界、provider 白名單、開工閘門、關閉閘門、代按前的狀態重查、grant——讀訊息那一行分辨是哪一類） |
| 5 | registry 缺漏或內容不合法 |
| 6 | herdr 拒絕 |
| 7 | 握手未取得憑據（逾時或 `agent_prompt_stalled`），或代按之後仍是 `blocked` |
| 8 | 啟動未就緒 |

### orchestrator 呼叫的腳本

| 腳本 | 呼叫時機 | 拿到結果之後怎麼判斷 |
| --- | --- | --- |
| `team-init.sh [--recover]` | `team-launch.md` 第 1 步；`--recover` 見 `session-recovery.md` | 印出 `orchestrator=<名稱> registry=<路徑>`；`--recover` 另印 `pending-resend` 行，處置見 `session-recovery.md` 第 3 步。專屬結束碼 `9`：偵測到 `AGENT_TEAM_SELF` 或 `AGENT_TEAM_ROLE`（只有 worker tab 會被注入）即判定呼叫端是 worker 環境，拒絕執行，不呼叫 herdr、不寫 registry |
| `set-goal.sh --achieve <> --success <> --not-doing <> --assumption <> [--confirmed] [--changed-by <>] [--rationale <>]` | 收斂 goal 之後、每一次要覆寫 goal 時 | 印出 `GOAL-SUCCESS-CHANGED version=<N>` 代表動到「怎樣算成功」，要轉述給使用者 |
| `launch-worker.sh --role <> --kind <> --cwd <> --briefing-file <> [--arg <>]... [--ack-timeout <秒>]` | goal 確認之後，逐個 role 啟動 | 成功印 `worker=<名稱> pane=<id> tab=<id> ack=ok`；結束碼 `8` 是已內部重試一次仍啟動失敗，registry 記錄已移除、啟動包副本仍留在 `briefings/<worker>.md`；`6` 是識別碼取不到或 herdr 拒絕，沒有寫入 registry；`2` 是 herdr 語法錯誤（呼叫端用錯，不是啟動失敗） |
| `instruct.sh --to <> (--text <> \| --text-file <>) [--reply-to <序號>] [--kind instruct\|decision\|goal-update\|halt]` | 下行任何指令、定案、goal 傳播；回覆 `need-you` 用 `--reply-to` | 結束碼 `7` 是對方卡在核准框、這一則進了 `.pending_resend`：重送沒有意義，但看門狗只在它離開 `blocked` 後才補投，必須去處理那個框（見 `SKILL.md`「派調查者的時機」），否則佇列永遠排不空且全程靜默。`0` 與 `7` 都會把 `delivered` 撥回 `running`；`closing`／`closed` 不動，`--kind halt` 不撥回（見 `drift-handling.md` 第 3 步） |
| `press-approval.sh --to <> --key <> --allows <> [--rule <>] [--startup]` | worker 卡在 `blocked`、已知要按哪一顆鍵與放行什麼，**且那個框不屬於不該代按的兩類**（工作區信任框、放行範圍大於當次那個具體動作的「總是允許」，這兩類停下來交給人類，見 `SKILL.md`「派調查者的時機」） | 結束碼 `4` 有兩種，讀訊息分辨：代按前重查已經不是 `blocked`（不必按了）；或帶 `--startup` 時規則不在允許清單上、分不出是哪條規則（框還在，要升級給人確認）。`2` 包括 `--key` 與允許清單對該規則載明的按鍵不一致，腳本拒絕代按，呼叫端與清單要先對齊。`7` 是按了仍是 `blocked`（可能按錯鍵或疊了另一個框），要重新讀畫面 |
| `shutdown-worker.sh --to <> --reason <done\|abandon\|superseded> [--evidence <>] [--handoff-file <>]` | `done` 已核對外部證據；或放棄／被取代（`abandon`／`superseded`，必須附交接檔） | 結束碼 `4` 是拒絕點命中：它還有未回覆的 `need-you`、其他 worker 的 `.grants` 仍指向它、還在 `delivered` 關卡、或不屬本 workspace。還在 `delivered` 時先 `set-worker-field.sh --to <worker> --field stage --value running` 撥回再關（見 `SKILL.md` Token 表 `done` 那一列） |
| `set-worker-field.sh --to <> --field <stage\|completion_criteria\|delivery_point\|end_point> --value <>` | 交付點／終點／完成判準確定時；`.stage` 需要變動時 | `--field stage` 的值只能是 `running`／`delivered`／`closing`／`closed`；座標類、計數類欄位不透過本腳本寫 |
| `grant-peer.sh --from <> --to <> [--revoke]` | thin command 的 `grant` 落地時；漂移處置改變了介面時 | 下行通知是 best-effort，送不到只印一句提示，授權本身已經生效 |
| `team-status.sh` | 中斷恢復核對哪些 tab 還活著；委派讀畫面前；想看全隊概況時 | 逐行 `worker=<> stage=<> status=<> seq=<> held=<> pending_resend=<> unprocessed=<>`；座標對不上本 workspace 的記錄會被跳過，不影響其餘行 |
| `fetch-detail.sh --seq <序號>` | 某則回報需要讀細節之前，先取路徑 | 印出絕對路徑（不含內容），交給調查者去讀；結束碼 `5` 是該序號沒有細節檔 |
| `watchdog.sh [--once]` | goal 確認之後即背景長駐；中斷恢復時依 `session-recovery.md` 第 6 步的條件決定是否重掛（最後一步）；`--once` 供人工巡檢一輪 | 啟動方式與存活判讀見 `team-launch.md` 第 6 步；長駐時不會自己結束 |

### worker 端腳本

以下三支由 worker 呼叫，列在此是為了看懂 worker 的行為與回報契約：

| 腳本 | 用途 |
| --- | --- |
| `report.sh` | worker 唯一的上行入口，六個 token 都經這裡送出，見 `worker-contract.md` |
| `send-peer.sh` | 已被 `grant-peer.sh` 授權的 worker，橫向直接送訊息給另一個 worker |
| `wait-peer.sh` | worker 端輪詢等同儕的 `state_change_seq` 改變；orchestrator 不使用 |

## 門檻值

| 環境變數 | 預設值 | 影響 |
| --- | --- | --- |
| `AGENT_TEAM_POLL_SECONDS` | 20 | `watchdog.sh` 每輪掃描的間隔 |
| `AGENT_TEAM_STALL_SECONDS` | 1800 | `running` worker 的 `state_change_seq` 多久沒變就判定停滯並升級 |
| `AGENT_TEAM_AUTO_PUSH_LIMIT` | 10 | 對同一個 worker 自動送出推進訊息（`lib/common.sh` 的 `HAT_AUTO_PUSH_TEXT`）的次數上限，達上限改為升級 |
| `AGENT_TEAM_NEEDYOU_LIMIT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS` 的三倍 | `need-you` 自 `.created_at` 起未回覆多久視為豁免到期 |
| `AGENT_TEAM_ESCALATION_REPEAT_SECONDS` | 當次生效的 `AGENT_TEAM_STALL_SECONDS`（該變數自身預設 1800） | 同一個升級條件兩次升級之間的最短間隔 |
| `AGENT_TEAM_LOCK_TIMEOUT_SECONDS` | 30 | registry 檔案鎖的等待上限，逾時以結束碼 `5` 失敗；定義在 `lib/common.sh`，不在 `watchdog.sh` 檔頭 |
