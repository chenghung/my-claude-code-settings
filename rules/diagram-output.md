# 圖表輸出規則

在 CLI 中，需外部 renderer 顯示的圖表 DSL 直接輸出到 stdout 沒意義，本規則規定改寫入 `.md` 檔或以 kroki.io 預覽。

## 適用語法

受本規則約束的圖表語法：`mermaid`、`plantuml`、`graphviz` / `dot`、LaTeX `tikz`、`d2`，以及其他任何需外部 renderer 才能顯示的圖表 DSL。

## 設計階段委派

產出任何受本規則約束的圖表 DSL 之前，main agent 必須先呼叫 `diagram-designer` skill 完成圖表類型與語法選型；免除觸發的情境以該 skill 的 description 為準。

## 使用 kroki.io 輸出 URL

```text
https://kroki.io/{diagram_type}/{output_format}/{encoded_diagram}
```

> [!WARNING]
> 不可使用一般的 URL percent-encoding（`%xx`）取代此流程。必須確實執行 zlib 壓縮再做 base64 url-safe 編碼，否則 kroki.io 無法正確解析內容。

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

```bash
# Open the kroki.io URL in Google Chrome in the background
google-chrome-stable "<URL>" & disown
```

若 `google-chrome-stable` 不可用或執行失敗，改將 URL 直接提供給使用者點擊查看。

## 判斷流程

收到需要產生圖表的任務時，依序判斷：

1. 使用者明示要原始碼 → 直接輸出到 stdout
1. 使用者要的是 ASCII 字元圖示 → 直接輸出到 stdout
1. 呼叫 `diagram-designer` skill 完成選型
1. 需要持久保存 → 寫入 `.md` 檔，依 `markdown-editing` rule 委派處理
1. 僅需即時呈現 → 產生 kroki.io URL 後以 `google-chrome-stable` 在背景開啟
1. 任何情況下禁止將受約束的圖表 DSL 以圖表為目的直接輸出到 stdout
