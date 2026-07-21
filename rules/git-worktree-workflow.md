# Git Worktree 工作流程

為了讓多個 AI agent 平行開發時互不干擾，對本 repo 內檔案的任何寫入或修改都必須在隔離的 git worktree 中進行。

## 動手改檔前先確認

修改 repo 內任何檔案前，先確認目前工作區是否為 git worktree。若不是，將「一律在隔離 worktree 中工作」視為既定偏好：直接建立並切換進新的 worktree 再繼續，不就此再徵詢使用者。

不受此約束的情形：純唯讀操作；repo 外的檔案（如 scratchpad、`~/.claude` 設定）；以及使用者明確指示要就地（非 worktree）修改時，以使用者指示為準。

## 路徑呈現

worktree 路徑通常較深且不直觀，相對路徑容易讓使用者找不到檔案。因此處於 worktree 模式時，對話中呈現給使用者、指向 repo 內檔案的路徑，一律使用以該 worktree 為根的絕對路徑。

此要求只適用於呈現給使用者看的路徑；寫進 commit message、plan 或 spec 檔內文的 repo 相對路徑屬內部參照，不受影響。
