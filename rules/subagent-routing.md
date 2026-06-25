本檔集中列出觸發特定 subagent 的 routing rule。當使用者意圖落在表中描述的範圍時，main agent 必須委派給對應 subagent，不得自行處理。

## Routing Table

| Subagent | Trigger Scope |
| --- | --- |
| `docker-expert` | Dockerfile 撰寫與最佳化、Docker Compose 配置、容器 runtime 診斷（OOM、networking、resource constraints） |
| `github-manager` | 透過 gh 執行 GitHub issue 與 PR 的實際操作，涵蓋查詢、列表、檢視等唯讀操作，以及接收已組好的內容去建立或更新 issue 與 PR；不負責內文的結構化組裝 |
| `manjaro-linux-admin` | Manjaro 或 Arch Linux 系統管理，包含系統診斷、log 分析、pacman/yay/flatpak 套件管理、需要 sudo 或修改系統狀態的操作 |
| `shell-script-developer` | 產生 `.sh` 檔案、實質邏輯超過 20 行的 shell script，或含 eval、trap、特殊字元檔名處理、複雜 quoting 等高風險語法的片段 |

## Selection Notes

- 跨範圍任務（例如同時涉及 GitHub PR 與 Linux 系統設定）時，main agent 應拆解後分別委派。
- 當任務涉及建立或修改 issue 或 PR 的標題或內文時，應先觸發 `github-issue-pr-authoring` skill 進行內容組裝，再委派 `github-manager` 執行。

## Delegation Contract

此契約對 Routing Table 中所有 subagent 適用，規範 main agent 在執行委派時的行為邊界。

- 委派任務時，main agent 只描述任務目標、意圖或預期產出，不指定 subagent 內部應使用哪些 CLI 指令、子命令、工具呼叫或執行步驟。
- 具體實作細節由 subagent 自行決定。Subagent 是該領域的專家，main agent 不應越過抽象層級指揮 subagent 的內部流程。
- 任務所需的具體事實（例如目標檔案路徑、套件名稱、issue 編號、card ID 等）仍應由 main agent 提供；此類資訊屬於「事實或約束」，不屬於「指令」，與本契約不衝突。
- 當不確定 subagent 是否能達成某項目標時，正確做法是描述目標並讓 subagent 回報可行性，而不是預先決定要用哪些指令來達成。
