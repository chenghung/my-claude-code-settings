本檔集中列出觸發特定 subagent 的 routing rule。當使用者意圖落在表中描述的範圍時，main agent 必須委派給對應 subagent，不得自行處理。

## Routing Table

| Subagent | Trigger Scope |
| --- | --- |
| `docker-expert` | Dockerfile 撰寫與最佳化、Docker Compose 配置、容器 runtime 診斷（OOM、networking、resource constraints） |
| `github-manager` | GitHub issues 與 pull requests 的查詢、建立、更新、留言 |
| `manjaro-linux-admin` | Manjaro 或 Arch Linux 系統管理，包含系統診斷、log 分析、pacman/yay/flatpak 套件管理、需要 sudo 或修改系統狀態的操作 |

## Selection Notes

- Trigger Scope 與各 subagent 自身的 In Scope 一致，本表只是 routing 速查。
- 詳細邊界條件請見對應 agent 定義檔。
- 跨範圍任務（例如同時涉及 GitHub PR 與 Linux 系統設定）時，main agent 應拆解後分別委派。
