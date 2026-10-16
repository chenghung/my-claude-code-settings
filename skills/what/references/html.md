# HTML

用來呈現終端機塞不下的密集概念或版面。選中就直接產生。

## 做法

1. 用 HTML、CSS、inline SVG 畫圖。流程或互動適合 Mermaid 時，可內嵌 Mermaid，由 CDN 載入的 mermaid.js 渲染（開啟時需要網路）。`<pre class="mermaid">` 裡的 `&quot;`、`&lt;` 這類 HTML entity 會先被瀏覽器解碼，Mermaid 收到的是 `"`、`<`，因而報 Syntax error。改用 Mermaid 的 `#quot;`、`#lt;`、`#gt;`，或避開這些字元。
1. 存到工作區的 `.tmp/what-<主題>.html`，`<主題>` 用小寫英文加連字號。`.tmp` 依暫存檔案存放規則處理：已有可用的 `.tmp`（實體目錄或有效 symlink）就直接沿用；不存在時，建立 `~/.tmp/<專案 basename>-<專案絕對路徑 sha256 前 8 碼>`，再在工作區建立指向它的 symlink（絕對路徑）；是失效 symlink 時，先移除它再照前述建立。檔案留給使用者，不刪。
1. 有 headless 瀏覽器時，確認 Mermaid 渲染成功，例如 `chromium --headless --dump-dom` 的輸出含 `<svg>`，且其 `aria-roledescription` 不是 `error`。沒有就略過。
1. 執行 `xdg-open <檔案路徑>` 開啟。
1. 檔案裡只放選中 HTML 的那張圖。一句話結論、背景、其他選中的圖、待使用者決定的事，照常輸出在終端機，並附上檔案路徑。使用者不開瀏覽器也能抓到重點。

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
