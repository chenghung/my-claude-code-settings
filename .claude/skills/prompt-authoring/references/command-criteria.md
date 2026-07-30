# Command Criteria

command 定義檔位於 `commands/`，是使用者以斜線指令主動觸發的流程定義。本檔是其專屬判準，與 `shared-criteria.md` 一併載入。

## Invocation Contract

command 由使用者主動觸發而非模型自主判斷，因此必須寫明三件事：這個 command 做什麼、需要使用者提供什麼參數、沒給參數時的行為。

自我檢測：只看定義檔、不看實作，能否回答「這個 command 要做什麼」「要傳什麼參數」「不傳參數會怎樣」三個問題？任一答不出來即為 finding。

## Scope Boundary

command 是否寫明適用範圍、破壞性或不可逆操作是否標示邊界，已由 `shared-criteria.md` 的 `Safety Boundary` 檢查涵蓋，本節不重複。

本節的增量檢查是資源觸及範圍：command 是否寫明它會動到哪些檔案或外部資源、哪些不會動。

自我檢測：讀者能否從定義檔列出一份「會被此 command 讀寫或呼叫的目標」清單，以及一份「不受影響」的清單？只寫其中一份、或兩份都沒寫，視為不通過。

## Delegation

command 的內容若涉及需要專門處理的工作類型（例如 shell script 撰寫、資料庫查詢等領域任務），應寫明委派意圖，不內嵌完整實作細節。理由：command 檔案被讀入時是整份載入，內嵌細節會造成不必要的 context 佔用。

自我檢測：把這段內容換成一句「達成 XX 目標，交由處理此類工作者執行」，模型還能照做嗎？可以，就代表原文寫多了，應精簡為意圖描述。
