# Git Worktree 工作流程

為了讓多個 AI agent 平行開發時互不干擾，對本 repo 內檔案的任何寫入或修改都必須在隔離的 git worktree 中進行。

## 動手改檔前先確認

修改 repo 內任何檔案前，先確認目前工作區是否為 worktree。若不是，將「一律在隔離 worktree 中工作」視為既定偏好：直接建立並切入新 worktree 再繼續，不另行徵詢。

不受此約束：純唯讀操作；repo 外的檔案（如 scratchpad、`~/.claude` 設定）；以及使用者明確指示就地（非 worktree）修改時。

## 路徑呈現

處於 worktree 模式時，對話中呈現給使用者、指向 repo 內檔案的路徑，一律用以該 worktree 為根的絕對路徑，以免使用者依相對路徑找不到檔案。此要求只適用於呈現給使用者的路徑；commit message、plan、spec 檔內文的 repo 相對路徑屬內部參照，不受影響。

## 合併後清理

使用者確認合併（PR 或 branch merged）後，自動收尾此 worktree，不另行徵詢：

- 先確認本次合併的變更已進入 origin/main。若有更具體的契約文件已把合併執行職責另行指派給別的角色，取得該方確認合併完成後發出的通知，視為已滿足此確認要求。確認後：將 local main 同步至 origin/main、移除 worktree 及其 local branch、刪除已無用的 remote branch（GitHub 未自動刪時補刪）。
- 若無法確認變更已進 origin/main，不得移除，保留 worktree 並回報使用者。
