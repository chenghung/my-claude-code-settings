# d2 Layout Engines 與 Render Styles 參考

本檔為 diagram-designer skill 的 reference，僅在使用 d2 且圖較複雜，需要決定 layout engine 或 render style 時載入。

## 目錄

- [釐清概念](#釐清概念)
- [Layout Engines](#layout-engines)
- [Render Styles](#render-styles)
- [kroki.io 對應參數](#krokiio-對應參數)
- [選用建議](#選用建議)

## 釐清概念

d2 中常被混淆的三件事，三者互相獨立可自由組合：

- **Layout engine**：負責計算節點位置與連線路徑的演算法
- **Render style**：圖形外觀風格（精緻 vs 手繪）
- **Theme**：配色方案

## Layout Engines

| Engine | 來源 | 特性 | 適合情境 |
| --- | --- | --- | --- |
| `dagre` | 預設，JavaScript 移植版 Graphviz | 階層式、輕量、速度快 | 中小型流程圖、一般架構圖 |
| `elk` | Eclipse Layout Kernel | 更成熟的階層演算法，處理大型圖更整齊 | 節點數多、需嚴格階層對齊 |
| `tala` | Terrastruct 商業 engine | 視覺密度最佳化，自動避免連線穿越 | 商業文件、複雜架構需專業視覺 |

`tala` 為 Terrastruct 商業產品，本機 d2 CLI 需有授權；kroki.io 與 d2 Studio 提供部分 tala 支援。

## Render Styles

- **預設精緻風格**：適合正式文件、技術規格，線條清晰、字體整齊
- **Sketch 手繪風格**：適合提案、白板感簡報、創意文件；透過 `--sketch` flag 在 CLI 啟用，或在 kroki.io URL 中以對應參數啟用

兩種風格可與任一 layout engine 自由組合。

## kroki.io 對應參數

kroki.io 的 d2 endpoint 可透過 query string 切換 layout engine 與 sketch 風格。詳細參數說明請見官方文件：

<https://docs.kroki.io/kroki/setup/diagram-options/>

## 選用建議

- 預設情況：`dagre` + 預設精緻風格
- 圖過於擁擠或階層複雜：改用 `elk`
- 強調設計感的提案或概念圖：加 sketch 風格
- 商業正式文件需要專業視覺：評估 `tala`（確認 kroki.io 支援狀況）
