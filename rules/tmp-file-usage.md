# 暫存檔案存放規則

任務期間若需建立暫存檔，必須遵守以下規則。

## 存放位置

- 任務期間若需暫存檔，優先使用工作區根目錄下的 `.tmp` 資料夾。
- 先依下一章節定義的方式判斷工作區根目錄下是否已存在可用的 `.tmp`。若已存在且可用（無論是使用者或專案自行建立的實體資料夾，或是先前已建立、指向有效目標的 symbolic link），直接沿用，不替換、不重建。
- 若工作區根目錄下沒有可用的 `.tmp`，LLM 應自動建立，依序執行下列步驟：
  1. 在使用者家目錄下的 `~/.tmp` 中建立此專案專用的資料夾；若 `~/.tmp` 本身不存在則一併建立。
  1. 在工作區根目錄建立名為 `.tmp` 的 symbolic link，指向剛才建立的 `~/.tmp` 下的專案專用資料夾；symbolic link 的目標必須使用絕對路徑。
- `~/.tmp` 下專案專用資料夾的命名規則：採用「專案目錄的 basename」加上連字號，再加上「專案絕對路徑經 sha256 雜湊後取前 8 個十六進位字元」。此命名具決定性——同一個專案在不同 session 重新計算都會得到相同名稱，確保對應關係可重複。範例：專案路徑為 `/home/eddie/projects/my-claude-code-settings` 時，名稱類似 `my-claude-code-settings-1a2b3c4d`，雜湊取法如下：

  ```sh
  printf '/home/eddie/projects/my-claude-code-settings' | sha256sum | cut -c1-8
  ```

- LLM 不得在工作區根目錄直接建立實體 `.tmp` 資料夾；工作區的 `.tmp` 只能是指向 `~/.tmp` 下該專案專用資料夾的 symbolic link。唯一例外是使用者或專案已自行建立的既有實體 `.tmp`，此時依上述規則直接沿用。

## 判斷 .tmp 是否存在

- 判斷工作區根目錄下的 `.tmp` 是否存在，必須以檔案系統層級的檢查為準，例如使用 `test -d <workspace>/.tmp`。
- 不得以 git 追蹤狀態（例如 `git ls-files`、`git status` 的輸出）作為判斷依據，因為 `.tmp` 可能已被加入 `.gitignore` 而未被 git 追蹤，但實際存在於檔案系統中。
- `test -d` 會自動 follow symlink，因此即使工作區的 `.tmp` 是指向 `~/.tmp` 的 symbolic link，這個檢查仍能正確判斷其指向的目標是否為有效目錄。
- 邊界情況：若工作區存在名為 `.tmp` 的 symbolic link，但其指向的目標已不存在（dangling symlink，此時 `test -d` 回傳 false），應先移除這個失效的 symbolic link，再依「存放位置」章節的自動建立流程，重新建立指向有效 `~/.tmp` 專案專用資料夾的 symbolic link。

## 任務結束後的處理

- 任務完成後應主動清除不再需要的暫存檔。
- 工作區的 `.tmp` symbolic link 本身，以及它指向的 `~/.tmp` 專案專用資料夾內的暫存內容，皆不得提交至版本控制。
