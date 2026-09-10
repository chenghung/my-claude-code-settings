#!/usr/bin/env bash
#
# skills/epic-orchestration/scripts/lib/common.sh
#
# 職責：epic-orchestration 事件驅動機制層的共用函式庫。七支操作腳本與
# event-generator.sh 常駐迴圈都會 `source` 本檔，取得：
#   - 環境前提檢查（HERDR_ENV）與 workspace 歸屬守衛
#   - 狀態檔（state.json）的建立與讀寫，一律經 jq，寫入用「暫存檔＋
#     mv」做到原子性
#   - agent 名稱推導、統一的結束碼與最小化錯誤輸出
#   - 對 herdr 呼叫的結束碼映射（1→6，2 原樣拋出並註明來源）
#
# 刻意偏離慣例：本檔不下 `set -euo pipefail`。它會被腳本與測試
# `source` 進呼叫端自己的 shell；若在這裡設定全域選項，會覆寫呼叫端
# 原本的選項狀態。全域安全選項一律由每一支「使用」本檔的腳本自行在
# 檔頭設定，本檔只提供函式。
#
# 機制層的權威文件就是這份檔案本身的說明與註解，不另外維護一份
# markdown 副本（規格第十五節）。
#
# ---- 結束碼對照表（所有腳本共用）----
#   0  成功
#   1  由個別腳本自行產生的部分失敗或迴圈異常，本檔不產生：
#      phase-status.sh 查全部模式下掃描已完成但至少一個 phase 失敗；
#      event-generator.sh 的主迴圈在低頻掃描子行程死亡時以 1 結束並在
#      stderr 請編排端重掛。這一列先前漏在本表之外，而 SKILL.md 的結
#      束碼表一直有它——兩份表的列數要對得上，補在這裡
#   2  呼叫端用錯：缺必填參數、參數格式不對
#   3  環境前提不成立：HERDR_ENV 不等於 1
#   4  workspace 守衛不通過
#   5  狀態檔缺漏：檔案不存在，或該 phase 不在檔內
#   6  herdr 拒絕：agent_blocked、agent_not_found、pane_not_found、
#      tab_not_found 等（herdr 自身結束碼 1 一律映射成本碼）
#   7  握手未取得憑據（逾時或 agent_prompt_stalled）——由呼叫
#      eo_herdr 的後續腳本自行判斷後使用，本檔不產生
#   8  啟動未就緒：agent start 未在逾時內回報就緒——同上，由呼叫端
#      使用，本檔不產生
#
# herdr 自身結束碼 2（語法錯誤）視為腳本呼叫 herdr 的方式有 bug，由
# eo_herdr 原樣往上拋（仍是 2）並在 stderr 註明是哪一次呼叫。

# ---- 未查證推估門檻 ----
# 來源：規格附錄 B。首次真實跑 epic 為校準回合，數值逐字照抄、不得
# 自行調整；供後續腳本（尤其 event-generator.sh）直接引用，避免各處
# 各自硬寫數字。

# 未查證推估，首次真實跑 epic 為校準回合：同一個 phase 被事件產生器
# 自動推進的累計次數上限，單位：次。是累計而不是連續，這個區別會改變
# 校準時該記什麼：計數只在 eo_classify_stop 交回編排端的那條最終分類
# 路徑上歸零，中途夾一則標記缺席並不會把它打回零，所以它量的是「自上
# 次最終路徑事件以來累計了幾次」。自動推進是產生器對 working-ok 標記
# 送出一則「繼續」下行，與代按核准框無關——那是 press-approval.sh 的
# 另一條路徑，不吃這個上限。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_AUTO_PUSH_LIMIT=40

# 未查證推估，首次真實跑 epic 為校準回合：state_change_seq 連續無
# 變化達此秒數才印 SPINNING（原始門檻為 25 分鐘）。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_SPINNING_SECONDS=$((25 * 60))

# 未查證推估，首次真實跑 epic 為校準回合：低頻掃描每
# EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS 秒一輪，連續
# EO_UNCLASSIFIED_ROUNDS 輪都判為 unknown 才印 UNCLASSIFIED。
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_UNCLASSIFIED_ROUNDS=5
# shellcheck disable=SC2034 # 本檔不使用，供後續腳本（event-generator.sh 等）source 後引用
readonly EO_UNCLASSIFIED_SCAN_INTERVAL_SECONDS=60

# eo_die <exit_code> <message>
# 把 <message> 印到 stderr，並以 <exit_code> 結束呼叫端的 shell。
eo_die() {
  local exit_code="$1"
  local message="${2:-}"
  printf '%s\n' "$message" >&2
  exit "$exit_code"
}

# eo_join_args <args...>
# 把引數以單一空白串接成一行印出，供診斷訊息引用。
#
# 診斷訊息裡不能直接寫 `$*`：八支腳本的檔頭都把 IFS 設成換行加 tab，
# 而 `$*` 用 IFS 的第一個字元串接，於是「herdr $*」這種一行診斷會在真
# 實呼叫下裂成好幾行（獨立審查實測一次失敗的 herdr 呼叫變成四行）。這
# 不只是排版：整套設計的核心約束就是編排端 context 的純度與「一則事件
# 一行」，多出來的行全部直接進編排端的 context。
#
# 也不能改成在 eo_die 內部把 IFS 設成單一空白——`$*` 是在呼叫端組訊息
# 的當下就展開完了，等進到 eo_die 只剩一個已經串好的字串，那裡改 IFS
# 影響不到它。所以串接必須發生在呼叫端，這個函式就是那個落點。
eo_join_args() {
  local out="" a
  for a in "$@"; do
    out="${out:+$out }$a"
  done
  printf '%s' "$out"
}

# eo_require_herdr_env
# HERDR_ENV 不等於字串 "1" 時以 3 結束；供腳本一開頭做前提檢查。
eo_require_herdr_env() {
  if [ "${HERDR_ENV:-}" != "1" ]; then
    eo_die 3 "HERDR_ENV 不是 \"1\"：目前不在 herdr 管理的環境中，拒絕執行"
  fi
}

# eo_main_repo
# 印出主倉庫絕對路徑。優先取環境變數 EO_MAIN_REPO；未設時改由 git 的
# common directory 推導：`git rev-parse --path-format=absolute
# --git-common-dir` 在主倉庫內回傳自己的 .git，在任一 worktree 內也
# 回傳同一個主倉庫的 .git（而不是 worktree 自己的 .git 檔案），取其
# 上層目錄即為主倉庫路徑，因此不論從主倉庫或任一 worktree 執行都得到
# 同一個答案。這條路徑不讀狀態檔的 main_repo 欄位：狀態檔路徑（見
# eo_state_file）本身就是由本函式推出來的，若又反過來讀狀態檔會構成
# 循環依賴，故該欄位保留給已經拿到檔案路徑的讀者，不在此處使用。
# 環境變數與 git common directory 兩者皆不可得時以 5 結束——寧可停
# 下，也不要用猜的路徑讓狀態檔寫到錯的地方。
eo_main_repo() {
  if [ -n "${EO_MAIN_REPO:-}" ]; then
    printf '%s\n' "$EO_MAIN_REPO"
    return 0
  fi

  local git_common_dir
  if git_common_dir="$(/usr/bin/git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    dirname "$git_common_dir"
    return 0
  fi

  eo_die 5 "EO_MAIN_REPO 未設，且目前不在任何 git 倉庫內，無法推導主倉庫路徑"
}

# eo_agent_name <phase>
# 印出 phase-<phase>-<主倉庫絕對路徑 sha256 前 4 碼>。
eo_agent_name() {
  if [ "$#" -lt 1 ]; then
    eo_die 2 "eo_agent_name 缺少必填參數 <phase>"
  fi
  local phase="$1"
  local main_repo hash
  main_repo="$(eo_main_repo)"
  hash="$(printf '%s' "$main_repo" | sha256sum | cut -c1-4)"
  printf 'phase-%s-%s\n' "$phase" "$hash"
}

# eo_state_file
# 印出狀態檔絕對路徑：<主倉庫>/.tmp/epic-orchestration/state.json。
eo_state_file() {
  printf '%s/.tmp/epic-orchestration/state.json\n' "$(eo_main_repo)"
}

# ---- 狀態檔寫入的失敗必須由寫入端自己接住：errexit 不在，而回傳碼還
#      被遮住 ----
# 下面四個會寫狀態檔的函式（eo_state_init／eo_state_set／
# eo_state_update／eo_state_remove_phase）都是「mktemp → 產生新內容 →
# mv 置換」三步。這三步的失敗（磁碟滿、目錄變唯讀、配額用盡、jq 對一
# 份被截斷的狀態檔解析失敗）原本兩層保護同時不存在：
#
#   一、errexit 不在。這些函式的呼叫鏈上一定有一層命令替換（例如
#       event-generator.sh 的 `event="$(eo_classify_stop ...)"`），而
#       命令替換的子殼裡 errexit 根本不生效：已對 bash 4.3.48 與
#       5.3.15 各量一次，結果相同——命令替換內 `$-` 不含 e，非最後一
#       個指令失敗既不中止替換、呼叫端也看不到（完整規則見
#       event-generator.sh 對 eo_classify_stop 呼叫點的註解）。
#   二、回傳碼被遮住。這些函式的最後一句是關閉鎖用的檔案描述符，所以
#       函式的結束碼是「關檔案描述符成功」，不是「寫入成功」。
#
# 獨立審查把 mktemp 樁成失敗實測過後果：eo_classify_stop 對一則
# working-ok 標記照樣回 0、照樣判定自動推進，但 last_marker_seq 與
# auto_push_count 兩個欄位一個都沒動——也就是自動推進的累計上限永不
# 觸發、同一則標記每輪都被判成新的，全程沒有訊息也沒有非 0 結束碼。同
# 一形狀的第二個後果是 `mv` 原本無條件執行：餵一份被截斷的狀態檔，jq
# 解析失敗而 mv 照跑，狀態檔變成 0 bytes，函式仍然回 0。
#
# 修法是把三步串起來、失敗就 eo_die 5（狀態檔缺漏／內容不合法，沿用既
# 有語意，不新開結束碼），不新增任何呼叫端契約：eo_die 用的是 exit，
# 而 exit 不受上面那條命令替換豁免影響——它終止那個替換子殼，讓替換
# 的結束碼變成非 0（已對 4.3.48 與 5.3.15 各量一次：在
# `if ev="$(...)"` 這個既有的顯式檢查形狀下，兩個版本拿到的都正好是
# eo_die 帶的那個碼）。因此呼叫端既有的顯式結束碼檢查會直接接住它。
# 失敗時先 `rm -f` 那個暫存檔：mv 沒跑成功時它會留在狀態檔目錄裡。

# eo_state_init
# 確保狀態檔存在：目錄不在就建，檔案不在就寫進最小的合法內容
# `{"phases":{}}`。檔案已存在時完全不動內容，重複呼叫是幂等的。
#
# 這個函式存在的理由是一個必然發生的失敗：整套腳本原本沒有任何一處會
# 建立這個檔案，而所有讀寫都經 _eo_state_file_or_die，它對不存在的檔
# 案一律以 5 結束。於是全新 epic 的第一次派工必然是「tab create 成
# 功、tab 真的開出來了，接著第一次寫狀態檔以 5 死掉」；而 close-phase
# .sh 第一件事就是從狀態檔取 tab_id，同樣以 5 死掉，於是那個已經真實
# 存在的 tab 沒有任何腳本關得掉，每個新 epic 都留下一個孤兒 tab。
#
# 為什麼是獨立一個函式、而不是讓 eo_state_set 自己順手建檔：「檔案不
# 存在」是一個有語意的訊號（結束碼 5；SKILL.md 的中斷恢復把整份狀態
# 檔遺失當成走 PR 編號反查退路的條件）。每一個寫入端都順手把檔案建回
# 來，等於把這個訊號從所有路徑上抹掉。建立記錄本來就只有
# start-phase.sh 一個職責方（SKILL.md「進度表與狀態檔」明文），因此建
# 檔也只由它明確呼叫一次，其餘路徑維持既有的 5。
#
# 而這個訊號現在真的有兩種意義，順手建檔會把兩種一起抹平：常駐的
# event-generator.sh 讀不到狀態檔時，主迴圈分開處理「還沒有人派工」與
# 「跑到中途被誰刪掉了」——當下沒有任何追蹤中的 phase 時照舊容忍（產
# 生器可以比第一個派工先起），已經追蹤到至少一個 phase 之後才讀不到，
# 就印一行 STATE-FILE-GONE 事件並以 5 結束，讓編排端察覺並依 SKILL.md
# 對 STATE-FILE-GONE 的處置走（見 event-generator.sh 的 main）。這比原
# 本的理由強，因為它現在有機制撐著，不是只有語意上的期望。
#
# 初始內容只有 phases 一個鍵，不補其他最上層鍵：已對整個 skills/ 目錄
# 搜過 main_repo 與 parent_issue，沒有任何生產程式碼讀或寫這兩個鍵
# （只有測試檔的樣本資料帶著它們），這裡不憑空寫進沒有人用的欄位。
# main_repo 尤其不能寫成「給讀者用的權威值」：狀態檔路徑本身就是由
# eo_main_repo 推出來的，反過來讀它會構成循環依賴（見 eo_main_repo 上
# 方註解）。
#
# 競態：多個 phase 可能在很短時間內接連啟動，於是有多個行程同時發現檔
# 案不存在。「檢查是否存在」與「寫入」兩步都放在與 eo_state_set 同一
# 把鎖（`<狀態檔>.lock`）的臨界區內，理由與 eo_state_update 把存在性
# 判斷搬進臨界區完全相同：檢查若落在鎖外，一個行程可能在檢查通過之後
# 才等到鎖，而這段等待期間另一個行程已經建好檔案、甚至寫進了真實記
# 錄，它拿到鎖後照樣寫下空的 `{"phases":{}}`，把那些記錄整個蓋掉。
eo_state_init() {
  local file dir lock_file lock_fd tmp
  file="$(eo_state_file)"
  dir="$(dirname "$file")"
  # mkdir -p 對「已存在」與「兩個行程同時建」都是安全的，而且它必須排
  # 在臨界區之前：鎖檔就開在這個目錄底下，目錄不存在就連鎖都開不起來。
  mkdir -p "$dir"

  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  if [ ! -f "$file" ]; then
    # 寫入失敗一律 eo_die 5，見上方「狀態檔寫入的失敗必須由寫入端自己
    # 接住」一節。
    tmp="$(mktemp "${file}.XXXXXX")" || eo_die 5 "eo_state_init: 無法在 $dir 底下建立暫存檔，狀態檔未建立"
    if ! { printf '%s\n' '{"phases":{}}' > "$tmp" && mv "$tmp" "$file"; }; then
      rm -f "$tmp"
      eo_die 5 "eo_state_init: 建立狀態檔失敗（寫入暫存檔或置換未成功）：$file"
    fi
  fi

  exec {lock_fd}>&-
}

# _eo_state_file_or_die（內部輔助函式，非公開介面）
# 回傳狀態檔路徑；檔案不存在時以 5 結束。供 eo_state_get／
# eo_state_set／eo_state_update／eo_state_phases／eo_state_remove_phase
# 共用，避免各處重複同一段檢查。
_eo_state_file_or_die() {
  local file
  file="$(eo_state_file)"
  if [ ! -f "$file" ]; then
    eo_die 5 "狀態檔不存在：$file"
  fi
  printf '%s\n' "$file"
}

# eo_state_get <phase> <field>
# 印出該欄位的值；檔案不存在、phase 不存在或欄位不存在時以 5 結束。
eo_state_get() {
  if [ "$#" -lt 2 ]; then
    eo_die 2 "eo_state_get 缺少必填參數 <phase> <field>"
  fi
  local phase="$1" field="$2" file has
  file="$(_eo_state_file_or_die)"

  # 先判斷 phase／欄位是否存在，避免布林 false 這種「JSON 假值但確實
  # 存在」的欄位被 jq -e 的真假值語意誤判成不存在。
  has="$(jq -r --arg p "$phase" --arg f "$field" \
    'if (.phases[$p] // null) == null then "missing"
     elif (.phases[$p] | has($f)) then "present"
     else "missing" end' "$file")"
  if [ "$has" != "present" ]; then
    eo_die 5 "phase $phase 或欄位 $field 不存在於狀態檔"
  fi

  jq -r --arg p "$phase" --arg f "$field" '.phases[$p][$f]' "$file"
}

# eo_state_set <phase> <field> <json_value>
# 以暫存檔加 mv 原子寫入。<json_value> 是 JSON 值而非字串，字串要由
# 呼叫端自帶引號（例如 '"running"'），這樣數字與布林不必另開函式。
# 暫存檔與目的檔同一目錄，確保 mv 落在同一個檔案系統上、是真的原子
# 置換。
#
# 合法性檢查刻意不用 `jq -e .`：`-e` 的結束碼是依「最後輸出值的真假」
# 決定，不是依「語法是否合法」——輸入合法的 JSON `false` 或 `null`
# 時，`-e` 一樣回傳非 0，會被誤判成不合法（獨立審查用真實 jq 1.8.2
# 重現過）。這裡改用 `. as $x | true`：不管 `$x`（也就是輸入值）本身
# 真假，永遠輸出字面上的 `true`，所以 `-e` 判的是「有沒有解析出東
# 西」而不是「解析出來的東西是不是真值」。也不能直接換成單純的
# `jq empty`：`empty` 對完全空字串或純空白輸入一樣回傳 0（因為它本來
# 就不輸出任何東西，`empty` 篩選器的『沒輸出』跟『合法但空』分不出
# 來），會把呼叫端漏帶引號、傳出空字串這種明確錯誤放行，這一點已用
# 真實 jq 驗證過（`jq empty <<<''` 回 0）。
eo_state_set() {
  if [ "$#" -lt 3 ]; then
    eo_die 2 "eo_state_set 缺少必填參數 <phase> <field> <json_value>"
  fi
  local phase="$1" field="$2" json_value="$3" file tmp lock_file lock_fd
  file="$(_eo_state_file_or_die)"

  if ! jq -e '. as $x | true' >/dev/null 2>&1 <<<"$json_value"; then
    eo_die 2 "eo_state_set 的第三個參數不是合法 JSON：$json_value"
  fi

  # 讀-改-寫（讀舊檔→算新內容→mv 換檔）整段用 flock 序列化，不只是
  # mv 那一刻：mv 本身雖然原子，但擋不住「兩個行程都讀到同一份舊內容
  # 後各自算出新內容、後寫入者蓋掉先寫入者變更」這種遺失更新。鎖檔用
  # `<狀態檔>.lock`，鎖只在本函式呼叫期間持有，函式結束就明確關閉
  # 對應的檔案描述符、釋放鎖。
  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  # 寫入失敗一律 eo_die 5，見上方「狀態檔寫入的失敗必須由寫入端自己接
  # 住」一節：這裡的裸 jq 沒有 errexit 罩著，而函式尾端關閉檔案描述符
  # 那一句又會把回傳碼遮掉。
  tmp="$(mktemp "${file}.XXXXXX")" || eo_die 5 "eo_state_set: 無法建立暫存檔，phase $phase 的 $field 未寫入：$file"
  if ! { jq --arg p "$phase" --arg f "$field" --argjson v "$json_value" \
      '.phases[$p] //= {} | .phases[$p][$f] = $v' "$file" > "$tmp" \
      && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    eo_die 5 "eo_state_set: 寫入狀態檔失敗，phase $phase 的 $field 未寫入（jq 解析或置換未成功）：$file"
  fi

  exec {lock_fd}>&-
}

# eo_state_update <phase> <field> <json_value>
# 跟 eo_state_set 用同一套暫存檔加 mv 原子寫入、同一把鎖檔，差別只有
# 一點：該 phase 必須已經存在於狀態檔，不存在就以 5（狀態檔缺漏）結
# 束、不落地暫存檔、不建立新記錄。`eo_state_set` 本身的「不存在就用
# `.phases[$p] //= {}` 自動起孔」這個行為維持不變、不受影響——
# event-generator.sh 依賴那個形式在讀取端補齊預設欄位，本函式是另開
# 一個名字的獨立函式，不是改寫 `eo_state_set`。
#
# 這個函式存在的理由是修一個真實重現過的競態：呼叫端若自己先呼叫
# `eo_state_get` 探測該 phase 存不存在、探測通過後才呼叫
# `eo_state_set` 寫入，這兩步是兩次獨立呼叫、各自對鎖檔開關一次，中
# 間有一段完全不持鎖的空窗。獨立審查用一個放大到一秒的睡眠窗口決定
# 性重現過：一個帶完整座標欄位的 phase 通過探測、進入睡眠，睡眠期間
# 另一個行程呼叫 `eo_state_remove_phase` 合法地把記錄移除，睡眠結束
# 後 `eo_state_set` 照跑，落地的正是這個函式要防的那種「只有剛寫的
# 那個欄位、沒有任何座標欄位」的幻影記錄，而呼叫端整支腳本以結束碼
# 0 結束、完全拿不到任何失敗訊號。把存在性判斷搬進本函式自己的臨界
# 區、跟寫入共用同一把鎖，兩者之間不再有任何行程能插進來改變狀態
# 檔，這條路徑因此不成立。
#
# 合法性檢查與 eo_state_set 完全相同：見上方 eo_state_set 的註解，理
# 由不重複。
eo_state_update() {
  if [ "$#" -lt 3 ]; then
    eo_die 2 "eo_state_update 缺少必填參數 <phase> <field> <json_value>"
  fi
  local phase="$1" field="$2" json_value="$3" file tmp lock_file lock_fd exists

  file="$(_eo_state_file_or_die)"

  if ! jq -e '. as $x | true' >/dev/null 2>&1 <<<"$json_value"; then
    eo_die 2 "eo_state_update 的第三個參數不是合法 JSON：$json_value"
  fi

  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  # 存在性判斷刻意放在拿到鎖之後：這就是本函式要解決的那個時間差
  # ——判斷與後面的寫入落在同一個臨界區，中間不會有其他行程插進來把
  # 這筆記錄移除或改變。
  exists="$(jq -r --arg p "$phase" \
    'if (.phases[$p] // null) == null then "missing" else "present" end' "$file")"
  if [ "$exists" != "present" ]; then
    exec {lock_fd}>&-
    eo_die 5 "phase $phase 不存在於狀態檔，eo_state_update 拒絕建立新記錄"
  fi

  # 寫入失敗一律 eo_die 5，理由與形狀見上方「狀態檔寫入的失敗必須由寫
  # 入端自己接住」一節。這條路徑走到這裡表示記錄確實存在，所以失敗訊
  # 息不會跟「phase 不存在」那一種混淆。
  tmp="$(mktemp "${file}.XXXXXX")" || eo_die 5 "eo_state_update: 無法建立暫存檔，phase $phase 的 $field 未寫入：$file"
  if ! { jq --arg p "$phase" --arg f "$field" --argjson v "$json_value" \
      '.phases[$p][$f] = $v' "$file" > "$tmp" \
      && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    eo_die 5 "eo_state_update: 寫入狀態檔失敗，phase $phase 的 $field 未寫入（jq 解析或置換未成功）：$file"
  fi

  exec {lock_fd}>&-
}

# eo_state_phases
# 每行印一個 phase 編號。
eo_state_phases() {
  local file
  file="$(_eo_state_file_or_die)"
  jq -r '.phases | keys[]' "$file"
}

# eo_state_remove_phase <phase>
# 移除該 phase 在狀態檔裡的整筆記錄。與 eo_state_set 共用同一把鎖檔
# 與同一套「讀-改-寫＋暫存檔＋mv」手法（理由見 eo_state_set 上方註
# 解：讀改寫這整段要在鎖內，不只是 mv 那一刻）。用在 close-phase.sh
# 三道守衛全數通過、成功關閉 tab 之後——設計規格生命週期第六步明文
# 要求收尾時把記錄移出狀態檔，記錄一旦留著不刪，事件產生器會一直監
# 看一個已經收尾的 phase。
#
# 對不存在的 phase 呼叫是幂等的，不報錯：jq 的 `del()` 對本來就不存
# 在的路徑是無操作，不是錯誤。這件事本身也是刻意的，不是湊巧——收
# 尾流程可能在同一個 phase 上被重複觸發（例如收尾一半中斷後重跑），
# 第二次呼叫不該因為記錄已經不在而失敗。
eo_state_remove_phase() {
  if [ "$#" -lt 1 ]; then
    eo_die 2 "eo_state_remove_phase 缺少必填參數 <phase>"
  fi
  local phase="$1" file tmp lock_file lock_fd
  file="$(_eo_state_file_or_die)"

  lock_file="${file}.lock"
  exec {lock_fd}>"$lock_file"
  flock -x "$lock_fd"

  # 寫入失敗一律 eo_die 5，理由與形狀見上方「狀態檔寫入的失敗必須由寫
  # 入端自己接住」一節。移除失敗要讓呼叫端知道：close-phase.sh 走到這
  # 一步時 tab 已經真的關掉了，記錄卻沒移除，事件產生器會繼續監看一個
  # 已經收尾的 phase。
  tmp="$(mktemp "${file}.XXXXXX")" || eo_die 5 "eo_state_remove_phase: 無法建立暫存檔，phase $phase 的記錄未移除：$file"
  if ! { jq --arg p "$phase" 'del(.phases[$p])' "$file" > "$tmp" \
      && mv "$tmp" "$file"; }; then
    rm -f "$tmp"
    eo_die 5 "eo_state_remove_phase: 移除 phase $phase 的記錄失敗（jq 解析或置換未成功）：$file"
  fi

  exec {lock_fd}>&-
}

# eo_assert_workspace <tab_id>
# 以 `herdr tab list --workspace` 確認該 tab 屬於本 workspace，不符
# 時以 4 結束。
#
# 「本 workspace」怎麼推導：取自 herdr 注入每個受管窗格的環境變數
# HERDR_WORKSPACE_ID（與 HERDR_TAB_ID、HERDR_PANE_ID 同一類、由 herdr
# 執行期自動設定，非本腳本自己匯出）。這是本檔唯一推導「本 workspace
# 為何」的地方；之後的腳本一律呼叫本函式取得判定結果，不得自行重新
# 推導或另讀 HERDR_WORKSPACE_ID。HERDR_WORKSPACE_ID 未設時視同守衛
# 不通過，一律以 4 結束。
eo_assert_workspace() {
  if [ "$#" -lt 1 ]; then
    eo_die 2 "eo_assert_workspace 缺少必填參數 <tab_id>"
  fi
  local tab_id="$1" workspace_id tabs_json match
  workspace_id="${HERDR_WORKSPACE_ID:-}"
  if [ -z "$workspace_id" ]; then
    eo_die 4 "HERDR_WORKSPACE_ID 未設，無法確認本 workspace"
  fi

  tabs_json="$(eo_herdr tab list --workspace "$workspace_id")"
  match="$(printf '%s' "$tabs_json" | jq -r --arg t "$tab_id" \
    '[.result.tabs[]?.tab_id] | index($t) // empty')"
  if [ -z "$match" ]; then
    eo_die 4 "tab $tab_id 不屬於本 workspace（$workspace_id）"
  fi
}

# eo_herdr <args...>
# 呼叫 `herdr <args...>`；stdout 原樣轉發給呼叫端（可用命令替換擷
# 取）。herdr 結束碼 1（伺服器錯誤，錯誤 JSON 印在 stderr）映射成
# 6；herdr 結束碼 2（語法錯誤，視為腳本呼叫方式有 bug）原樣拋出，並
# 在 stderr 額外註明是哪一次呼叫。
#
# ---- herdr 印在 stderr 上的內容一律接管，不讓它原樣繼承 ----
# 失敗時（不論結束碼 1 還是 2）都把 herdr 的 stderr 擷取下來，只重組
# error 底下的 code 與 message 兩個純字串欄位成同樣結構的 JSON
# （`{"error":{"code":...,"message":...}}`）再印回本函式呼叫端的
# stderr，不轉發 herdr 原始輸出。理由跟 send-to-phase.sh／
# press-approval.sh 對非逾時類錯誤的處理同一條：herdr 的原始回應可能
# 整包帶著 terminal_title 這類模型產出文字的載體（已查證 `agent wait`
# 的正常回應即是如此），一旦讓它原樣繼承到呼叫端的 stderr，就直接進了
# 編排端的 context，而編排端的 context 純度正是這裡要保護的東西。重
# 組後的形狀刻意沿用 herdr 原本 `error.code`／`error.message` 的慣
# 例，不是另創一套：send-to-phase.sh 與 press-approval.sh 對 herdr 的
# 直接呼叫（繞過本函式，見它們檔頭說明）都是用這個路徑讀
# `error.code` 分辨逾時類與其他，重組後的形狀不改變這個讀法會不會成
# 立。
#
# 取不到 error.code（stderr 根本不是合法 JSON，例如 herdr 自己
# panic、或結束碼 2 時印出的用法說明——後者正是這條路徑最常見的非
# JSON 內容）時，不把原始內容印出去，改印一則固定的替代訊息，並帶上
# herdr 的原始結束碼，讓人知道發生過什麼、只是內文被擋下了（見
# `_eo_relay_herdr_stderr`）。error.message 缺漏但 error.code 存在
# 時，只有 message 落到明確的替代字串，不影響 code 的可用性、也不
# 靜默留空。
#
# `herdr "$@"` 這一句刻意包在 `if` 的條件裡，不是寫成後面接一行
# `rc=$?` 的裸陳述句：bash 的 errexit 只在「一個指令的失敗正在被
# if／while／until 的條件、或 &&／|| 左側測試」時才豁免，其餘情況失
# 敗當下就終止整個 shell。呼叫端的腳本一律有 `set -e`，若 herdr 在
# 這裡是裸陳述句，一旦失敗，errexit 會在到達下面 `rc=$?` 與 case 之
# 前就先把整個呼叫端腳本終止，本函式的結束碼映射邏輯永遠執行不到
# ——這正是獨立審查用真實樁重現出的問題：外層腳本收到的是 herdr 原始
# 的 1，而不是約定的 6。把測試點放在 `if` 內部，讓豁免發生在本函式
# 自己身上，不必依賴呼叫端怎麼寫（是否包在子殼、邏輯運算子裡）。

# _eo_relay_herdr_stderr <stderr_file> <orig_rc>（內部輔助函式，非公
# 開介面）
# 把 <stderr_file> 裡 herdr 的原始 stderr 內容，轉成只含 error.code
# 與 error.message 兩個欄位的重組 JSON 印到本函式呼叫端的 stderr；取
# 不到 error.code 時改印固定的替代訊息（帶 <orig_rc>）。理由與形狀見
# 上方 eo_herdr 的「herdr 印在 stderr 上的內容一律接管」說明，不重複。
_eo_relay_herdr_stderr() {
  local stderr_file="$1" orig_rc="$2" raw code message
  raw="$(cat "$stderr_file")"
  code="$(printf '%s' "$raw" | jq -r '.error.code // empty' 2>/dev/null || true)"
  if [ -n "$code" ]; then
    message="$(printf '%s' "$raw" | jq -r '.error.message // empty' 2>/dev/null || true)"
    [ -n "$message" ] || message="(無法取得 error.message)"
    # `-c` 是必要的，不是風格偏好：jq 預設會把輸出美化成多行，這則重組
    # 後的錯誤 JSON 因此從一行變成六行，全部進編排端的 context（見
    # eo_join_args 上方那段：同一個約束的另一個出口）。
    jq -nc --arg code "$code" --arg message "$message" \
      '{error: {code: $code, message: $message}}' >&2
  else
    printf 'eo_herdr: herdr 以結束碼 %s 拒絕，其 stderr 無法解析出可用的 error.code（可能是非 JSON 輸出，例如 panic 或印出用法說明），原始內容已攔截、不轉發\n' \
      "$orig_rc" >&2
  fi
}

eo_herdr() {
  local rc=0 stderr_file
  # 擷取 herdr 的 stderr 到暫存檔，不是變數：本函式的 stdout 必須維
  # 持原樣直接繼承給呼叫端（呼叫端多半用命令替換擷取這個函式的
  # stdout 當回應 JSON），不能像 send-to-phase.sh／press-approval.sh
  # 那樣用 `2>&1 >/dev/null` 把 stdout 丟棄、只留 stderr——那種手法
  # 會讓成功時本來要回傳的 JSON 整個消失。
  stderr_file="$(mktemp)"
  # 刻意用 if／else 兩個分支各自處理，不是「if 判斷完再看 $?」：
  # `if cmd; then ...; fi`（沒有 else）在條件為假、又沒有 else 時，
  # 整個 if 陳述句本身的結束碼固定是 0，不是 cmd 失敗當下的原始結束
  # 碼——`$?` 要在 else 分支裡、緊接著失敗的那個當下取，才會是 herdr
  # 真正的結束碼。
  if herdr "$@" 2>"$stderr_file"; then
    rm -f "$stderr_file"
    return 0
  else
    rc=$?
  fi
  _eo_relay_herdr_stderr "$stderr_file" "$rc"
  rm -f "$stderr_file"
  # 引數用 eo_join_args 串接，不用 `$*`：IFS 是換行加 tab，`$*` 會讓這
  # 一行診斷裂成好幾行（見 eo_join_args 上方說明）。
  case "$rc" in
    1) eo_die 6 "eo_herdr: herdr 以結束碼 1 拒絕（見上方已重組的錯誤資訊）：herdr $(eo_join_args "$@")" ;;
    2) eo_die 2 "eo_herdr: herdr 以結束碼 2 拒絕，疑似腳本呼叫語法錯誤：herdr $(eo_join_args "$@")" ;;
    *) exit "$rc" ;;
  esac
}
