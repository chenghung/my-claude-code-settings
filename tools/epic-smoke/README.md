# tools/epic-smoke

## 用途

`my-claude-code-settings` 是一個集中式的個人設定中心，底下以 `agents`、`skills`、`rules` 等目錄分類存放各類定義檔。`tools/epic-smoke` 是一組極輕量的 shell 工具，用來快速查看這些定義檔的數量。

## 檔案組成

- `lib.sh`：共用的記錄層，提供 `log_msg` 函式，將訊息寫到標準錯誤（stderr）。
- `check.sh`：統計腳本，載入 `lib.sh`，遞迴統計倉庫根目錄底下 `agents`、`skills`、`rules` 三個目錄各自的一般檔案數量。

## 使用方式與輸出

執行環境需要 bash，以及 find、tr、wc、dirname 這幾個標準系統工具。

預設模式（不帶任何引數）：

```sh
./tools/epic-smoke/check.sh
```

三個目錄的檔案數量會以人類可讀的形式，透過 `log_msg` 印到標準錯誤，標準輸出為空：

```text
agents: 12
skills: 8
rules: 15
```

JSON 模式（加上 `--json`）：

```sh
./tools/epic-smoke/check.sh --json
```

除了照樣把上述人類可讀訊息印到標準錯誤之外，另外把統計結果以單行 JSON 印到標準輸出：

```json
{"agents":12,"skills":8,"rules":15}
```

（以上人類可讀輸出與 JSON 輸出範例中的數字皆僅為示例，實際數字會隨倉庫內容變動。）

只有加上 `--json` 才會啟用 JSON 模式；不帶引數，或帶其他任意引數，行為都與預設模式相同。

人類可讀的記錄訊息一律走標準錯誤，可被程式解析的 JSON 一律走標準輸出，兩者不混流，因此可以安全地把標準輸出直接接給 JSON 解析器：

```sh
./tools/epic-smoke/check.sh --json | jq .
```

此處的 `jq` 僅用於示範如何解析 JSON，並非這組腳本本身的相依；未安裝 `jq` 不影響 `check.sh` 的執行。
