# 啟動包範本

worker 是一個全新的 session，對這個任務、這個團隊、這份協定一無所知。啟動包是它唯一的資訊來源——**沒進到啟動包的東西對 worker 而言等同不存在**。但反過來也要守住：**啟動包只放需要 worker 判斷的東西**。腳本檢查得了的一律不寫進來，例如摘要長度上限（`report.sh` 自己會在超限時給出明確錯誤訊息教它把內容挪進 detail 欄位）、它被指定成哪個 model、傳了哪些原生引數——寫進去只是描述一道它違反不了的守衛，還會排擠掉真正需要它動腦的那幾句。

本檔由 orchestrator 在準備啟動某個 worker、呼叫 `launch-worker.sh --briefing-file <路徑>` **之前**載入使用：把下面三段範本的所有 `{{...}}` 佔位處代入這次要派工的具體內容，寫成一個檔案，再把那個檔案路徑當成 `--briefing-file` 傳給 `launch-worker.sh`。`launch-worker.sh` 第 3 步會把這個檔案的內容原樣複製進 `briefings/<worker>.md`，那份副本是中斷恢復之後唯一能重建「當初到底派了什麼」的東西，因此啟動包一旦送出就不會再被 worker 以外的機制修改——調整內容只能是啟動下一個 worker 或重新啟動這一個 worker。

**組裝之前要先算好這個 worker 未來的 agent 名稱**：`launch-worker.sh` 是先收到已經寫好的啟動包才啟動，不會把它算出來的名稱倒填回啟動包內容。名稱的算法是 `hat_normalize_name <HERDR_WORKSPACE_ID 小寫化> <role>`（`lib/common.sh`），orchestrator 必須在動筆寫「03 協定」那一段之前，用同一個規則自己先算出這個名稱，並確保接下來呼叫 `launch-worker.sh --role <role>` 用的是同一個 `role` 值——兩邊算出來的名稱必須一致，啟動包裡寫的 worker-id 才對得上 `launch-worker.sh` 第 8 步實際比對的那個值。

## 01 身分

```text
你是 {{role 名稱}}，負責：{{職責描述}}。

你不負責：{{不歸你動的事，含哪些檔案、介面或決定不歸你判斷}}。

你的工作起點目錄是：{{工作起點絕對路徑}}。
```

「不負責」與「不歸你動」這兩項必須具體寫出來，不能只寫「其他都不歸你管」——thin command 的 orchestrator role 段落（`負責`／`不負責`）與各 worker role 的職責描述是這一段的來源，見 `thin-command-format.md`。

## 02 任務

```text
要達成的目標：{{goal.achieve}}

怎樣算成功（外部查得到）：{{goal.success}}

你這個角色的完成判準：{{completion_criteria}}

權威來源：{{authority_locator}}
有牴觸時以它為準。

參考材料（選填、不具約束力）：{{reference_locator 或「無」}}
```

**只給 goal 四項裡的前兩項**（要達成什麼、怎樣算成功），不給「不做什麼」與「前提」。worker 需要知道自己在為什麼服務，才判得出撞到的落差是不是全局性的；但「不做什麼」與「前提」是 orchestrator 的裁決材料，給了等於邀請 worker 自己判斷什麼對團隊最好，而啟動包整段都在劃它的職責界線，不是在給它裁決權。

## 03 協定

```text
你的 worker-id：{{normalized agent 名稱}}

回報契約：{{worker-contract.md 或其實例化版本的 locator}}
請先讀完那份文件，裡面定義了你唯一的回報動作、什麼時候必須回報、以及回報之後會發生什麼。

你可以聯繫的同儕：
{{依 worker-contract.md「同儕段落的組裝」一節產生的那一段——有 grant 時列出對象，沒有時整段換成那一句}}

第一件事：呼叫回報動作，token 是 ack，摘要照這個格式填：

worker_id=<你的 worker-id> cwd=<你目前實際所在的絕對路徑> model=<你實際掛載的 model 名稱>

三個值之間用單一空白分隔，每個值本身都不能含空白字元（尤其是 cwd——如果你的工作目錄路徑含空白，先確認能不能換一個不含空白的等價寫法，再填進這裡）。回報動作是執行：

{{AGENT_TEAM_SCRIPTS}}/report.sh --token ack --summary "worker_id=... cwd=... model=..."
```

`worker_id=<id> cwd=<絕對路徑> model=<名稱>` 是全專案唯一釘死的格式（Global Constraints、`launch-worker.sh` 第 8 步）：`launch-worker.sh` 靠解析這一行做 ACK 對帳，權威是它啟動時指定的參數，不是 worker 自己說的——cwd 出錯是靜默的，CLI 也可能因額度或設定覆寫而 fallback 到別的 model，兩者都沒有其他訊號可以察覺。範本若寫成別的格式，對帳會永遠比不出結果，而啟動仍然成功、沒有任何錯誤訊息。三個變數的具體值：

- `worker_id`：就是本段開頭「你的 worker-id」那個值，也就是環境變數 `AGENT_TEAM_SELF` 的內容。
- `cwd`：worker 自己此刻實際的工作目錄（例如執行 `pwd` 的結果），不是「01 身分」裡寫的那個工作起點字面值——兩者理應相同，但要填的是實測值，讓對帳真的能抓到不一致。
- `model`：worker 自己實際掛載的 model 名稱，由它自己回答，不是照抄啟動時傳的原生引數。

`{{AGENT_TEAM_SCRIPTS}}` 是啟動時由 `herdr tab create --env` 注入的環境變數，指向本 skill 的 `scripts/` 目錄絕對路徑；worker 不需要另外被告知這個路徑怎麼來，它啟動時就已經在環境裡。
