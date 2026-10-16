# HTML

用來呈現終端機塞不下的密集概念或版面。

## 做法

1. 用 HTML、CSS、inline SVG 畫圖。流程或互動適合 Mermaid 時，可內嵌 Mermaid，由 CDN 載入的 mermaid.js 渲染（開啟時需要網路）。`<pre class="mermaid">` 裡的 `&quot;`、`&lt;` 這類 HTML entity 會先被瀏覽器解碼，Mermaid 收到的是 `"`、`<`，因而報 Syntax error。改用 Mermaid 的 `#quot;`、`#lt;`、`#gt;`，或避開這些字元。
1. 依暫存檔案存放規則取得 `.tmp`，存成 `.tmp/what-<主題>.html`，`<主題>` 用小寫英文加連字號。檔案留給對話者，不刪。
1. 用了 Mermaid 且有 headless 瀏覽器時，確認渲染成功：執行 `chromium --headless --dump-dom --virtual-time-budget=15000 file://<路徑>`，輸出的 `<svg>` 要有 `aria-roledescription`，且值不是 `error`。少了 `--virtual-time-budget`，DOM 會在 Mermaid 渲染完成前就被輸出。沒有瀏覽器就略過。
1. 執行 `xdg-open <檔案路徑>` 開啟。
1. 檔案裡只放選中 HTML 的那張圖。一句話結論、全局前提、其他選中的圖、待對話者決定的事，照常輸出在終端機，並附上檔案路徑。對話者不開瀏覽器也能抓到重點。

## 骨架

照抄後替換標題（這張圖的主題）、圖與說明：

```html
<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>主題</title>
<style>
  body { font-family: system-ui, sans-serif; max-width: 960px; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
</style>
</head>
<body>
<h1>這張圖的主題</h1>

<pre class="mermaid">
flowchart LR
  A[使用者] -->|/what| B[agent]
  B --> C[結論與圖]
</pre>
<p>照箭頭順序說明這張圖。</p>

<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({ startOnLoad: true });
</script>
</body>
</html>
```
