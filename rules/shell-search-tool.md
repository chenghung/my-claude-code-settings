# Shell 搜尋工具規則

在 shell 中執行文字搜尋時，一律優先使用 `rg`（ripgrep）；僅當 `rg` 不存在於當前環境時，才 fallback 使用 `grep`。本規則只規範在 shell 中執行的文字搜尋。

此規則存在的理由是：當搜尋必須落到 shell 執行時，原本由 harness 內建搜尋工具白拿的「預設略過 `.gitignore` 忽略項」行為就消失了，必須在 shell 層自己補回來。`rg` 有這個行為，`grep` 沒有。

需要搜尋被 ignore 的內容（例如 `node_modules`、build 產物、`.git` 內部檔案）時，不構成 fallback 回 `grep` 的理由，改用 `rg` 對應的 include-ignored 開關即可。此處要特別留意：`rg` 在這類路徑上會安靜地回傳零命中而不報錯，容易被誤讀為「該內容不存在」。
