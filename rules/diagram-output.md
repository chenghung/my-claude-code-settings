# 圖表輸出規則

- [適用語法](#適用語法)
- [預設行為](#預設行為)
- [允許情境](#允許情境)
- [使用 kroki.io 輸出 URL](#使用-krokiio-輸出-url)
- [判斷流程](#判斷流程)

在 CLI 終端機中，需要外部 renderer 才能顯示的圖表語法輸出到 stdout 後，使用者只會看到原始文字，無法看到圖形，純粹浪費 output token。本規則禁止此類語法直接出現在聊天訊息中，並規定應依情境改寫入 `.md` 檔案或產生 kroki.io URL 供使用者查看。

## 適用語法

下列圖表語法受本規則約束：

- `mermaid`
- `plantuml`
- `graphviz` / `dot`
- LaTeX `tikz`
- `d2`
- 其他任何需要外部 renderer 才能顯示為圖像的 markdown 圖表語法

## 預設行為

禁止將上述語法直接輸出到聊天訊息（stdout）。若任務需要產生此類圖表，依使用情境選擇下列兩種方式之一：

- **持久性圖表**：寫入正式 `.md` 檔案，依 `markdown-editing` rule 委派給 `markdown-editor` 或 `obsidian-md-editor` 處理；main agent 不得自行寫入。
- **暫時性視覺化或需要在聊天中即時呈現**：產生 kroki.io 圖片 URL 提供給使用者點擊查看，不得直接將 DSL 原始碼輸出到 stdout。若同時需要保留 DSL 原始碼以供日後修改，依 `tmp-file-usage` rule 寫入工作區的 `.tmp` 目錄，並將 URL 一併回傳。

## 允許情境

以下兩種情況可直接輸出到 stdout，不受本規則限制：

- **使用者明確要求原始碼**：例如「給我這段流程圖的 mermaid 原始碼讓我複製貼到別處」，此時圖表語法本身就是使用者要的純文字產出。
- **ASCII 圖示**：以 box-drawing 字元或純文字繪製的示意圖，在終端機中可直接觀看，不需要外部 renderer。

## 使用 kroki.io 輸出 URL

[kroki.io](https://kroki.io) 是公開的圖表渲染服務，接受多種 DSL 語法並回傳 SVG 或 PNG 圖片。URL 格式如下：

```text
https://kroki.io/{diagram_type}/{output_format}/{encoded_diagram}
```

各欄位說明：

- `diagram_type`：圖表語法類型，例如 `mermaid`、`plantuml`、`d2`、`graphviz`、`erd` 等
- `output_format`：輸出格式，常用 `svg` 或 `png`
- `encoded_diagram`：DSL 原始碼經過壓縮與編碼後的字串

`encoded_diagram` 的產生方式為：先以 **zlib 壓縮**（即 deflate 加上 zlib header 與 adler32 checksum）DSL 原始碼，再對壓縮結果做 **base64 url-safe 編碼**（使用 `-` 和 `_` 取代標準 base64 的 `+` 和 `/`，且不加 padding `=`）。

> [!WARNING]
> 不可使用一般的 URL percent-encoding（`%xx`）取代此流程。必須確實執行 zlib 壓縮再做 base64 url-safe 編碼，否則 kroki.io 無法正確解析內容。

可透過以下指令產生 `encoded_diagram`：

```bash
# Use Python to zlib-compress and base64 url-safe encode the DSL source
python3 -c "
import sys, zlib, base64
src = sys.stdin.read().encode('utf-8')
compressed = zlib.compress(src)  # zlib-compress (deflate with header + adler32)
print(base64.urlsafe_b64encode(compressed).rstrip(b'=').decode())
" <<'EOF'
<DSL 原始碼貼於此>
EOF
```

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 允許直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 允許直接輸出到 stdout
1. 需要持久保存的圖表 → 寫入 `.md` 檔案，依 `markdown-editing` rule 委派處理
1. 僅需在聊天中即時呈現的圖表 → 產生 kroki.io URL 提供給使用者
1. 任何情況下都禁止把 mermaid、plantuml、d2、graphviz、tikz 等 DSL 原始碼以圖表為目的直接輸出到 stdout
