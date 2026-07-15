# Shell 搜尋工具規則

在 shell 中，被執行的指令名不得是 `grep`，一律改用 `rg`（ripgrep），僅當環境中沒有 `rg` 時才 fallback 回 `grep`。此規定無例外，涵蓋管線中的 `... | grep`。判準只看被執行的指令名：`grep` 出現在其他位置一律不算違規，例如作為 flag 名（`git log --grep=...`，此用法沒有 `rg` 等價替代）、搜尋樣式（`rg '\bgrep\b'`）或引數。本規則不涉及 harness 內建的搜尋工具。

規範對象是 LLM 當下自己執行的指令，含為了執行而臨時寫出、隨即自己跑的一次性 script。寫進檔案交由他人或其他機器日後執行的 script（如本 repo 的 `install.sh`、hook、CI script）不受約束：那類產出物在別人機器上跑，`grep` 是 POSIX 保證存在而 `rg` 不是，可攜性的取捨在那裡相反。

對檔案樹搜尋另有一個實質理由：harness 內建搜尋工具白拿的「預設略過 `.gitignore` 忽略項」行為，在搜尋落到 shell 時就消失，必須自己補回來，而這行為 `rg` 有、`grep` 沒有。需要搜尋被 ignore 的內容（`node_modules`、build 產物、`.git` 內部檔案等）時，不構成 fallback 回 `grep` 的理由，改用 `rg` 的 include-ignored 開關即可；但要注意 `rg` 在這類路徑上會安靜回傳零命中而不報錯，容易被誤讀為「該內容不存在」。

`rg` 與 `grep` 的 regex 方言不同，既有 `grep` pattern 不得逐字搬到 `rg`，替換時須確認其在 `rg` 下的實際行為。
