#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO/skills/herdr-agent-team/scripts/lib/common.sh"
fail=0
# 跑過的斷言數，供檔尾的下限檢查用（見那裡的說明）。
assert_count=0
pass() { assert_count=$((assert_count + 1)); printf 'PASS %s\n' "$1"; }
bad()  { assert_count=$((assert_count + 1)); printf 'FAIL %s\n' "$1"; fail=1; }

T="$(mktemp -d)"
STUB_BIN="$T/bin"

# ---- 「回報 0 FAIL 但其實只跑了一部分」要自己看得出來 ----
# 這份套件裡的 hat_die／hat_assert_workspace 呼叫失敗時是真正的 exit，
# 會直接把套件行程帶走；被帶走時已經跑過的斷言全是 PASS，只看 FAIL 數
# 的判讀會把它當成全綠（同一形狀在 tests/test-epic-orchestration-
# scripts.sh 已經實測過兩條真實路徑）。兩道防線一起做：這個 EXIT trap
# 負責「沒走到結尾」（不論被什麼帶走），檔尾的斷言數下限檢查負責「走
# 到結尾但少跑了」。訊息刻意用 `FAIL ` 前綴印在 stdout：任何以 FAIL
# 行數判讀成敗的讀法（人或腳本）都會看到它。
HAT_SUITE_REACHED_END=0
# shellcheck disable=SC2329 # 由下面的 EXIT trap 呼叫，靜態檢查看不到那個呼叫點
_hat_suite_on_exit() {
  local rc=$?
  if [ "$HAT_SUITE_REACHED_END" -ne 1 ]; then
    printf 'FAIL 套件提早終止：只跑了 %s 條斷言就以結束碼 %s 離開，後面的斷言一條都沒跑（不要把「0 FAIL」讀成全綠）\n' \
      "$assert_count" "$rc"
  fi
  rm -rf "$T"
}
trap '_hat_suite_on_exit' EXIT

mkdir -p "$STUB_BIN"

# ---- 樁遮蔽的結構性修法：這份套件全程不讓真實 herdr 出現在 PATH 上 ----
# herdr 是本檔唯一需要遮蔽的外部二進位（會啟動或附接終端介面、可能連
# 到真實 socket），也是唯一「跑真的會有副作用」的外部指令；其餘用到的
# 工具（jq／mktemp／mkdir／rm／cat／chmod／grep／tr／dirname／
# sha256sum／basename／cut／ln／mv／flock／find／wc／sort）都是唯讀或
# 副作用侷限在測試自己的暫存目錄內、零成本，已查證全部位於 /usr/bin，
# 跑真的完全安全（Task 2 新增 mv／flock／find／wc／sort 五項，用於
# hat_json_set 的加鎖讀改寫與 hat_worker_list／測試斷言本身，已在本任
# 務底下用受限 PATH（僅 /usr/bin:/bin，不含任何樁目錄）重新查證過五者
# 皆解析到 /usr/bin，不會落到別處）。整份套件的 PATH 一律是「樁目錄＋
# /usr/bin:/bin」，真實 herdr 所在的 ~/.local/bin 從頭到尾不在 PATH
# 上，忘了建樁的段落只會得到 command-not-found 而失敗，不會靜默地改打
# 真實 herdr session。
HAT_TEST_PATH="$STUB_BIN:/usr/bin:/bin"
export PATH="$HAT_TEST_PATH"

# ---- 守衛：確認 herdr 這個名字真的解析到樁 ----
# 用法：呼叫端建好 $STUB_BIN/herdr 之後，帶著本節名稱呼叫一次。
hat_assert_herdr_stubbed() {
  local stub_dir="$1" section="${2:-}" resolved
  [ -n "$section" ] || { bad "PATH guard: 沒有給本節名稱"; return; }
  resolved="$(command -v herdr || true)"
  [ "$resolved" = "$stub_dir/herdr" ] \
    || bad "PATH guard[$section]: herdr 解析到 '$resolved'，不是樁"
}

export HERDR_ENV=1 HERDR_WORKSPACE_ID=w3N
# shellcheck source=/dev/null
source "$LIB"

# ===== 命名正規化 =====
# 這幾條斷言改寫成 if/then/else/fi，不是任務簡報原始給的
# `[ cond ] && pass ... || bad ...`：pass 一定回 0，這裡的 `&&/||` 鏈
# 不會真的短路錯位，但 shellcheck（SC2015）看不出 pass 一定成功，會對
# 每一條都發出「C 可能在 A 為真時也執行」的提醒。改用 if/then/else/fi
# 讓警告在結構上就不存在，訊息與判斷式本身完全不變。
n="$(hat_normalize_name w3N backend)"
if [ "$n" = "w3n-backend" ]; then pass "命名：workspace id 小寫化"; else bad "命名：得到 '$n'"; fi

n="$(hat_normalize_name w3N 'UX Designer')"
if [ "$n" = "w3n-ux-designer" ]; then pass "命名：role 轉小寫且空白換連字號"; else bad "命名：得到 '$n'"; fi

n="$(hat_normalize_name w3N "$(printf 'a%.0s' {1..60})")"
if [ "${#n}" -le 32 ]; then pass "命名：截斷到 32 字元以內"; else bad "命名：長度 ${#n}"; fi
if printf '%s' "$n" | grep -Eq '^[a-z][a-z0-9_-]{0,31}$'; then
  pass "命名：符合 herdr 正規表示式"
else
  bad "命名：'$n' 不符合正規表示式"
fi

# ===== workspace 守衛 =====
# hat_assert_workspace 的介面在任務簡報的 Produces 有列，但簡報 Step
# 1-11 沒有替它安排測試步驟，也沒有像 hat_project_tmp／
# hat_registry_root 那樣被註明「驗證延後到後續任務」。這兩個斷言是本
# 次實作自行補上的最小覆蓋，理由：它直接控制結束碼 4（workspace 邊界
# 守衛），若完全不驗證就出貨，等於一個會真的呼叫 exit 4 的函式從頭到
# 尾沒被跑過一次。判定依據（pane_id／tab_id 為 `<workspace_id>:<local>`
# 格式）已用當前這個終端機的真實 HERDR_PANE_ID／HERDR_TAB_ID 實測過
# （見任務報告）。
# hat_die 呼叫的是真正的 exit，必須包在子殼裡才不會把整個套件行程帶
# 走；`&& rc=0 || rc=$?` 是這份套件安全擷取結束碼的慣用寫法，理由見下
# 面「herdr 封裝」小節開頭的說明，此處不重複。
( hat_assert_workspace "w3N:p2" ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then pass "workspace 守衛：屬於本 workspace 的 pane_id 放行"; else bad "workspace 守衛：得到 rc=$rc"; fi

( hat_assert_workspace "other:p2" ) 2>/dev/null && rc=0 || rc=$?
if [ "$rc" -eq 4 ]; then pass "workspace 守衛：不屬於本 workspace 時以 4 結束"; else bad "workspace 守衛：得到 rc=$rc"; fi

# ===== herdr 封裝：stderr 不外洩 =====
# 這節是安全性測試，不是格式測試：hat_herdr 的 stderr 直接就是
# orchestrator 的 context。
#
# 任務簡報給的原始寫法是 `out="$(hat_herdr ...)"; rc=$?`（bare 賦值，
# 賦值本身另起一行才讀 $?）。已實測：在這份套件開頭的 `set -euo
# pipefail` 之下，只要 hat_herdr 依規格回傳非 0（它本來就該回傳 6 或
# 2），這一行賦值當場觸發 errexit，套件行程在讀到 `rc=$?` 之前就先被
# 帶走——跟任務簡報描述 hat_herdr 內部呼叫 herdr 時要求包在 if 裡是
# 同一個成因，只是這裡是套件呼叫 hat_herdr 這一層再中一次。改寫成
# `... && rc=0 || rc=$?`：把整句賦值放進 `&&/||` 鏈的非最後位置，
# errexit 對它豁免；已用 `bash -c` 各自對 exit 與 return 兩種寫法各驗
# 證一次，行為相同，兩者都需要這個修法（實測記錄見任務報告）。這個寫
# 法也是 tests/test-epic-orchestration-scripts.sh 全篇擷取可能失敗之呼
# 叫的慣用寫法（例如該檔的 `( eo_herdr ... ) 2>/dev/null && rc=0 ||
# rc=$?`），沿用同一慣例。
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s' '{"error":{"code":"agent_blocked","message":"blocked"},"agent":{"terminal_title":"洩漏標記_SHOULD_NOT_APPEAR"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" herdr-wrapper

out="$(hat_herdr agent get x 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 6 ]; then pass "herdr 封裝：結束碼 1 映射成 6"; else bad "herdr 封裝：得到 rc=$rc"; fi
case "$out" in
  *洩漏標記_SHOULD_NOT_APPEAR*) bad "herdr 封裝：terminal_title 外洩到輸出" ;;
  *agent_blocked*) pass "herdr 封裝：只轉發 error.code" ;;
  *) bad "herdr 封裝：error.code 沒有出現在輸出：$out" ;;
esac

# ===== herdr 封裝：語法錯誤映射與非 JSON stderr =====
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'Usage: herdr agent get <TARGET>\n洩漏標記_USAGE_LEAK\n' >&2
exit 2
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" herdr-wrapper-usage

out="$(hat_herdr agent get 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then pass "herdr 封裝：結束碼 2 原樣保留"; else bad "herdr 封裝：得到 rc=$rc"; fi
case "$out" in
  *洩漏標記_USAGE_LEAK*) bad "herdr 封裝：非 JSON 用法說明外洩" ;;
  *) pass "herdr 封裝：非 JSON stderr 也不外洩" ;;
esac

# ===== 白名單投影 =====
sample='{"result":{"agents":[{"name":"w3n-backend","workspace_id":"w3N","agent_status":"done","state_change_seq":1007,"pane_id":"w3N:p2","tab_id":"w3N:t2","terminal_title":"洩漏標記_TITLE","terminal_title_stripped":"洩漏標記_STRIPPED","cwd":"/x"}]}}'
out="$(hat_whitelist_agents "$sample")"
case "$out" in
  *洩漏標記*) bad "白名單：標題欄位外洩" ;;
  *w3n-backend*done*1007*) pass "白名單：六個欄位齊全且無外洩" ;;
  *) bad "白名單：輸出不如預期：$out" ;;
esac

# ===== registry 讀寫 =====
# 這裡是本檔第一次用到 registry。先把 AGENT_TEAM_HOME／HOME 都收斂進
# $T：hat_registry_root 內部會呼叫 hat_project_tmp，而 hat_project_tmp
# 未被 HOME 收斂時會去動開發機真實的 $HOME/.tmp（hat_project_tmp 本身
# 的行為驗證延後到 Task 3，這裡只是借它的路徑推導，不能因此把真實
# $HOME 弄髒，寫法沿用 Task 3 簡報既有的 `HOME="$T/fakehome"` 慣例）。
export AGENT_TEAM_HOME="$T/teamhome" HOME="$T/fakehome"
mkdir -p "$AGENT_TEAM_HOME"
hat_registry_init
REG="$(hat_registry_root)"

# ---- hat_registry_init：六個子目錄與空 team.json（本任務自行補的覆
#      蓋率缺口，見任務報告）----
# 任務簡報 Produces 有列 hat_registry_init，但 Step 1-6 沒有安排任何測
# 試步驟驗證它本身；hat_json_get／hat_worker_list 也是同樣情形。已用
# 關鍵字搜過全部 15 份 task brief，這三者從頭到尾沒有被排定由任何地方
# 驗證。比照 Task 1 對 hat_project_tmp／hat_assert_workspace 同類缺口
# 的處理方式：不是排定由後續任務驗證的，就在本任務自行補最小斷言。
for d in workers inbox details replies peer-log handoff; do
  if [ -d "$REG/$d" ]; then
    pass "registry：hat_registry_init 建立子目錄 $d"
  else
    bad "registry：子目錄 $d 沒有被建立"
  fi
done

content="$(cat "$REG/team.json" 2>/dev/null || true)"
if [ "$content" = '{}' ]; then
  pass "registry：team.json 初始為空物件"
else
  bad "registry：team.json 初始內容不是 {}：$content"
fi

# 幂等：team.json 已存在時重跑不得清空既有內容。用跟六個子目錄／欄位
# 白名單都無關的自訂標記內容，確認這條檢查測的是「保留既有檔案」本
# 身，不是碰巧跟其他斷言用同一份資料。
printf '{"marker":"kept"}' > "$REG/team.json"
hat_registry_init
content="$(cat "$REG/team.json")"
if [ "$content" = '{"marker":"kept"}' ]; then
  pass "registry：hat_registry_init 重跑不清空既有 team.json"
else
  bad "registry：重跑後 team.json 內容變成：$content"
fi
printf '{}' > "$REG/team.json"

# ---- Step 1（任務簡報逐字）：mktemp 失敗必須讓 hat_json_set 以 5 結束 ----
# 這是整個 lib 最重要的一條測試：epic-orchestration 那邊踩過的實際後
# 果是 mktemp 被樁成失敗之後，函式照樣回 0、自動推進的累計上限永不觸
# 發、同一則標記每輪都被判成新的，全程沒有訊息也沒有非 0 結束碼。
cat > "$STUB_BIN/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_BIN/mktemp"
rc=0; ( hat_json_set "$REG/team.json" '.goal_version' '2' ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "registry：mktemp 失敗以 5 結束"
else
  bad "registry：得到 rc=$rc（靜默成功是最危險的結果）"
fi
rm -f "$STUB_BIN/mktemp"

# ---- Step 2: 函式結束碼不得被關檔案描述符遮住；mv 不得無條件執行 ----
cat > "$STUB_BIN/jq" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_BIN/jq"
rc=0; ( hat_json_set "$REG/team.json" '.goal_version' '3' ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "registry：jq 失敗不被遮成成功"
else
  bad "registry：jq 失敗卻回 0"
fi
rm -f "$STUB_BIN/jq"
size="$(wc -c < "$REG/team.json")"
if [ "$size" -gt 0 ]; then
  pass "registry：jq 失敗時原檔未被截斷"
else
  bad "registry：team.json 變成 0 bytes"
fi

# ---- Step 5: 欄位白名單拒絕清單外的欄位 ----
rc=0; ( hat_json_set "$REG/team.json" '.arbitrary_field' '"x"' ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "registry：白名單外的欄位被拒絕"
else
  bad "registry：白名單沒有生效（rc=$rc）"
fi

# ---- 額外覆蓋（本任務自行補上，理由見上方 hat_registry_init 小節）----
# hat_json_get 的成功路徑與缺漏路徑、hat_json_set 對巢狀路徑與
# workers／inbox 兩類檔案的白名單路由、hat_worker_list，任務簡報都只
# 列在 Produces、Step 1-5 完全沒有測到。
hat_json_set "$REG/team.json" '.goal_version' '5'
v="$(hat_json_get "$REG/team.json" '.goal_version')"
if [ "$v" = "5" ]; then
  pass "registry：hat_json_set 寫入後 hat_json_get 讀得回來"
else
  bad "registry：讀回 '$v'，預期 5"
fi

rc=0; ( hat_json_get "$REG/team.json" '.not_a_real_field' ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "registry：hat_json_get 對缺漏欄位以 5 結束"
else
  bad "registry：得到 rc=$rc"
fi

hat_json_set "$REG/team.json" '.goal.achieve' '"做出 PRD"'
v="$(hat_json_get "$REG/team.json" '.goal.achieve')"
if [ "$v" = "做出 PRD" ]; then
  pass "registry：hat_json_set 對巢狀路徑（.goal.achieve）也能寫入"
else
  bad "registry：讀回 '$v'"
fi

mkdir -p "$REG/workers" "$REG/inbox"
printf '{}' > "$REG/workers/w3n-backend.json"
hat_json_set "$REG/workers/w3n-backend.json" '.role' '"backend"'
v="$(jq -r '.role' "$REG/workers/w3n-backend.json")"
if [ "$v" = "backend" ]; then
  pass "registry：hat_json_set 認得 workers/*.json 白名單"
else
  bad "registry：workers 白名單路由失敗，讀回 '$v'"
fi

printf '{}' > "$REG/inbox/1-w3n-backend.json"
hat_json_set "$REG/inbox/1-w3n-backend.json" '.token' '"ack"'
v="$(jq -r '.token' "$REG/inbox/1-w3n-backend.json")"
if [ "$v" = "ack" ]; then
  pass "registry：hat_json_set 認得 inbox/*.json 白名單"
else
  bad "registry：inbox 白名單路由失敗，讀回 '$v'"
fi

printf '{}' > "$REG/workers/w3n-ux.json"
out="$(hat_worker_list | sort | tr '\n' ' ')"
case "$out" in
  *w3n-backend*w3n-ux*) pass "registry：hat_worker_list 列出所有 worker" ;;
  *) bad "registry：hat_worker_list 輸出不如預期：$out" ;;
esac

# ===== 斷言數下限：走到結尾但少跑了，也要看得出來 =====
# EXIT trap 抓的是「沒走到結尾」，這一條抓的是另一半：走到了結尾，但
# 某個段落被跳過、斷言數比預期少。新增斷言時要把這個數字一起改大——
# 這是刻意的成本：一個會隨新增斷言自動放寬的下限抓不到任何東西。數字
# 不含本條斷言自己。
HAT_EXPECTED_ASSERTIONS=29
if [ "$assert_count" -ge "$HAT_EXPECTED_ASSERTIONS" ]; then
  pass "斷言數達到下限（跑了 $assert_count 條，下限 $HAT_EXPECTED_ASSERTIONS）"
else
  bad "斷言數只有 $assert_count 條，低於下限 $HAT_EXPECTED_ASSERTIONS：有段落被整段跳過，不要把「0 FAIL」讀成全綠"
fi

# 走到這一行才算跑完整份套件，見檔頭 _hat_suite_on_exit 的說明。
HAT_SUITE_REACHED_END=1
exit "$fail"
