#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO/skills/herdr-agent-team/scripts/lib/common.sh"
SCRIPTS="$REPO/skills/herdr-agent-team/scripts"
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
# sha256sum／basename／cut／ln／mv／flock／find／wc／sort／date）都是唯
# 讀或副作用侷限在測試自己的暫存目錄內、零成本，已查證全部位於
# /usr/bin，跑真的完全安全（Task 2 新增 mv／flock／find／wc／sort 五
# 項，用於 hat_json_set 的加鎖讀改寫與 hat_worker_list／測試斷言本身，
# 已在本任務底下用受限 PATH（僅 /usr/bin:/bin，不含任何樁目錄）重新查
# 證過五者皆解析到 /usr/bin，不會落到別處；Task 4 新增 date 一項，用於
# set-goal.sh 替 goal_history 每筆紀錄蓋時間戳，同樣以受限 PATH 查證過
# 解析到 /usr/bin）。整份套件的 PATH 一律是「樁目錄＋
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

# ---- hat_registry_init：七個子目錄與空 team.json（本任務自行補的覆
#      蓋率缺口，見任務報告）----
# 任務簡報 Produces 有列 hat_registry_init，但 Step 1-6 沒有安排任何測
# 試步驟驗證它本身；hat_json_get／hat_worker_list 也是同樣情形。已用
# 關鍵字搜過全部 15 份 task brief，這三者從頭到尾沒有被排定由任何地方
# 驗證。比照 Task 1 對 hat_project_tmp／hat_assert_workspace 同類缺口
# 的處理方式：不是排定由後續任務驗證的，就在本任務自行補最小斷言。
for d in workers inbox details replies briefings peer-log handoff; do
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

# 幂等：team.json 已存在時重跑不得清空既有內容。用跟七個子目錄／欄位
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

# ---- Important 修復（審查回合 1）：合法的 false／空字串不得被誤判成
#      缺漏 ----
# 根因是舊寫法用 `jq -r "$jq_path // empty"` 取值、再看輸出是否為空字
# 串來判斷缺漏，而 `// empty` 把 JSON false 也當假值換成空字串。
# team.json 的 .goal_confirmed、workers/<name>.json 的 .held 兩個白名
# 單欄位初值就是合法的 false，被誤判成缺漏會在完全正常的狀態下觸發
# hat_die 5（真正的 exit，把整個呼叫端帶走），而不是讓呼叫端能分支處
# 理的結束碼。同一根因也會把合法的空字串值一併誤判成缺漏。
#
# 這兩條刻意不用裸陳述句 `v="$(hat_json_get ...)"` 擷取：套件開頭有
# errexit，如果修法又壞掉、hat_json_get 對合法值誤判缺漏而 die 5，裸
# 陳述句會在讀到 rc 之前就把整個套件行程帶走（跟本檔其餘擷取可能失敗
# 之呼叫的既有慣例同一個理由），因此改用「先把 rc 設成 0，再用 or 接
# 上讀取」的安全寫法。
hat_json_set "$REG/team.json" '.goal_confirmed' 'false'
rc=0; v="$(hat_json_get "$REG/team.json" '.goal_confirmed')" || rc=$?
if [ "$rc" -eq 0 ] && [ "$v" = "false" ]; then
  pass "registry：hat_json_get 對合法的 false 值不誤判成缺漏"
else
  bad "registry：得到 rc=$rc v='$v'（false 被誤判成缺漏是本輪審查要修的 Important 缺陷）"
fi

hat_json_set "$REG/team.json" '.thin_command_source' '""'
rc=0; v="$(hat_json_get "$REG/team.json" '.thin_command_source')" || rc=$?
if [ "$rc" -eq 0 ] && [ "$v" = "" ]; then
  pass "registry：hat_json_get 對合法的空字串值不誤判成缺漏"
else
  bad "registry：得到 rc=$rc v='$v'"
fi

# 修法沒有連帶改壞「路徑真的缺漏」的行為：換一個從未被任何測試寫過的
# 巢狀路徑（跟上面兩條分屬不同欄位、不同層級），確認它仍以 5 結束。
rc=0; ( hat_json_get "$REG/team.json" '.goal.success' ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "registry：hat_json_get 對真的缺漏的巢狀路徑仍以 5 結束（沒有被 false／空字串的修法連帶改壞）"
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

# ===== team-init.sh：.tmp 建立規則（本任務同時是 hat_project_tmp／
#       hat_registry_root 的行為驗證，Task 1 只實作、未測）=====
# 沿用上面「registry 讀寫」小節已匯出的 AGENT_TEAM_HOME=$T/teamhome、
# HOME=$T/fakehome。team-init.sh 的自我命名步驟需要 HERDR_PANE_ID／能
# 回應的 herdr 樁，這裡先用一個通用成功樁與固定 pane id 頂著，讓這兩條
# 只關心 .tmp 行為的斷言不被自我命名這一步連累；記錄 rename 引數的專用
# 樁留到下面「自我命名」小節才需要。
TEAM_HOME="$T/teamhome"
export AGENT_TEAM_HOME="$TEAM_HOME" HOME="$T/fakehome" HERDR_PANE_ID=w3N:p1
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"result":{}}'
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" team-init-tmp

rc=0; bash "$SCRIPTS/team-init.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init：首次執行以 0 結束"; else bad "team-init：得到 rc=$rc"; fi

if [ -L "$TEAM_HOME/.tmp" ]; then
  pass ".tmp 是 symlink"
else
  bad ".tmp 不是 symlink（規則禁止實體目錄）"
fi
tgt="$(readlink "$TEAM_HOME/.tmp")"
case "$tgt" in
  /*) pass ".tmp symlink 目標是絕對路徑" ;;
  *)  bad ".tmp symlink 目標不是絕對路徑：$tgt" ;;
esac
hash8="$(printf '%s' "$TEAM_HOME" | sha256sum | cut -c1-8)"
case "$tgt" in
  *"teamhome-$hash8") pass ".tmp 目標命名符合 basename-hash8 規則" ;;
  *) bad ".tmp 目標命名不符：$tgt（期望結尾 teamhome-$hash8）" ;;
esac

# ---- Step 8（任務簡報）：連跑兩次都必須以 0 結束 ----
# 這裡緊接著、不動任何狀態地再跑一次，直接驗證「已經命名過／registry
# 已經存在」時的幂等性；跟下面「dangling symlink 重建」那一次刻意先破
# 壞狀態再重跑是兩件不同的事，分開測。
rc=0; bash "$SCRIPTS/team-init.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init：緊接著重跑（幂等）仍以 0 結束"; else bad "team-init：得到 rc=$rc"; fi

# ---- dangling symlink 的重建 ----
# 刪的是 $HOME/.tmp（team home 底下 .tmp symlink 指向的目標所在的家目
# 錄），不是 $TEAM_HOME/.tmp 本身：這樣才會讓既有 symlink 變成目標不存
# 在的 dangling symlink，而不是直接把 symlink 本身砍掉重練。
rm -rf "$T/fakehome/.tmp"
rc=0; bash "$SCRIPTS/team-init.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init：dangling symlink 重建後仍以 0 結束"; else bad "team-init：得到 rc=$rc"; fi
if [ -d "$TEAM_HOME/.tmp/" ]; then
  pass "dangling symlink 被重建"
else
  bad "dangling symlink 沒有被重建"
fi

# ===== team-init.sh：自我命名 =====
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "agent" ] && [ "\$2" = "rename" ]; then
  printf '%s %s\n' "\$3" "\$4" > "$T/rename-args"
  printf '{"result":{}}'; exit 0
fi
printf '{"result":{}}'; exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" team-init-naming
export HERDR_PANE_ID=w3N:p1 HERDR_WORKSPACE_ID=w3N

rc=0; bash "$SCRIPTS/team-init.sh" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init：自我命名執行以 0 結束"; else bad "team-init：得到 rc=$rc"; fi

read -r tgt nm < "$T/rename-args"
if [ "$tgt" = "w3N:p1" ]; then pass "rename 目標用 pane id"; else bad "rename 目標是 '$tgt'"; fi
if [ "$nm" = "w3n-orchestrator" ]; then pass "orchestrator 名稱已正規化"; else bad "名稱是 '$nm'"; fi

# ===== team-init.sh --recover：收回殘留持有旗標＋回報待補送清單 =====
mkdir -p "$REG/workers"
printf '{"held":true,"pending_resend":[{"text":"x"}]}' > "$REG/workers/w3n-backend.json"
printf '{"held":true,"pending_resend":[]}'             > "$REG/workers/w3n-ux.json"

HERDR_CALL_LOG="$T/herdr-call-log"
: > "$HERDR_CALL_LOG"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HERDR_CALL_LOG"
printf '{"result":{}}'
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" team-init-recover

rc=0; out="$(bash "$SCRIPTS/team-init.sh" --recover 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init --recover：執行以 0 結束"; else bad "team-init --recover：得到 rc=$rc"; fi

if [ "$(jq -r '.held' "$REG/workers/w3n-backend.json")" = "false" ]; then
  pass "recover：收回殘留持有旗標"
else
  bad "recover：旗標仍卡在 true（watchdog 會永久跳過它）"
fi
if [ "$(jq -r '.held' "$REG/workers/w3n-ux.json")" = "false" ]; then
  pass "recover：所有 worker 的旗標都收回"
else
  bad "recover：只收回了一部分"
fi
case "$out" in
  *"pending-resend worker=w3n-backend count=1"*) pass "recover：印出待補送清單" ;;
  *) bad "recover：沒有印出待補送清單：$out" ;;
esac
case "$out" in
  *"pending-resend worker=w3n-ux"*) bad "recover：把沒有待補送的 worker 也列出來了" ;;
  *) pass "recover：只列出真的有待補送的 worker" ;;
esac

# ===== team-init.sh --recover：絕對不自行補送 =====
# 補送必須由 orchestrator 依清單逐一呼叫 instruct.sh，順序才控制得
# 住；順序顛倒（--recover 自己先補送）會讓補送設下的新旗標被 watchdog
# 補發事件的處理流程當成「上一輪沒收回的殘留」而收掉。
: > "$HERDR_CALL_LOG"
printf '{"held":true,"pending_resend":[{"text":"goal 更新"}]}' > "$REG/workers/w3n-backend.json"
rc=0; bash "$SCRIPTS/team-init.sh" --recover >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then pass "team-init --recover（第二輪）：執行以 0 結束"; else bad "team-init --recover：得到 rc=$rc"; fi

if grep -q 'agent prompt' "$HERDR_CALL_LOG"; then
  bad "recover：自行補送了（順序會失控，補送設下的旗標會被 watchdog 當殘留收掉）"
else
  pass "recover：不自行補送，只回報清單"
fi
if [ "$(jq -r '.pending_resend | length' "$REG/workers/w3n-backend.json")" = "1" ]; then
  pass "recover：待補送清單保持原樣"
else
  bad "recover：清單被清掉了"
fi

# ===== set-goal.sh：四項必填 =====
rc=0; bash "$SCRIPTS/set-goal.sh" --achieve a --success b --not-doing c >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "goal：缺 --assumption 以 2 結束"
else
  bad "goal：得到 rc=$rc"
fi

# ===== set-goal.sh：開工閘門 =====
bash "$SCRIPTS/set-goal.sh" --achieve a --success b --not-doing c --assumption d >/dev/null 2>&1
rc=0; ( hat_require_goal_confirmed ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "閘門：未確認時擋住"
else
  bad "閘門：未確認卻放行（rc=$rc）"
fi

bash "$SCRIPTS/set-goal.sh" --achieve a --success b --not-doing c --assumption d --confirmed >/dev/null 2>&1
rc=0; ( hat_require_goal_confirmed ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "閘門：確認後放行"
else
  bad "閘門：確認後仍擋（rc=$rc）"
fi

# ===== set-goal.sh：版本遞增與成功定義變動通知 =====
v1="$(jq -r '.goal_version' "$REG/team.json")"
out="$(bash "$SCRIPTS/set-goal.sh" --achieve a --success 'b2 改過的成功定義' --not-doing c --assumption d --changed-by worker-report --rationale '前提被推翻')"
v2="$(jq -r '.goal_version' "$REG/team.json")"
if [ "$v2" -gt "$v1" ]; then
  pass "goal：版本遞增"
else
  bad "goal：版本沒動（$v1 → $v2）"
fi
case "$out" in
  *GOAL-SUCCESS-CHANGED*) pass "goal：成功定義變動有顯著標記" ;;
  *) bad "goal：成功定義變了卻沒有標記" ;;
esac
n="$(jq -r '.goal_history | length' "$REG/team.json")"
if [ "$n" -ge 2 ]; then
  pass "goal：變更紀錄有累積"
else
  bad "goal：goal_history 只有 $n 筆"
fi

# ---- 本任務自行補上：--confirmed 不在時不得翻旗標（行為要求 3，簡報
#      Step 1-3 沒有安排任何測試步驟覆蓋它）----
# 上一步的呼叫沒有帶 --confirmed，若實作誤把 goal_confirmed 寫回
# false，會讓 orchestrator 自決階段的每一次目標調整都重新鎖上已經通過
# 的開工閘門，而且不會有任何錯誤訊息——這正是規格 §9 定案「第一版由人
# 類確認，之後每一次變更由 orchestrator 自決」要保護的狀態。
confirmed_after="$(jq -r '.goal_confirmed' "$REG/team.json")"
if [ "$confirmed_after" = "true" ]; then
  pass "goal：--confirmed 不在時不翻動 goal_confirmed（維持既有的 true）"
else
  bad "goal：goal_confirmed 被改成 '$confirmed_after'（--confirmed 不在時不該碰這個欄位）"
fi

# ---- 本任務自行補上：goal_history 單筆紀錄的實際內容（行為要求 2 明
#      訂要有新舊四項、changed_by、rationale、時間戳，簡報 Step 3 只驗
#      證了筆數成長，沒有驗證內容本身）----
last_entry="$(jq -c '.goal_history[-1]' "$REG/team.json")"
changed_by_recorded="$(printf '%s' "$last_entry" | jq -r '.changed_by')"
rationale_recorded="$(printf '%s' "$last_entry" | jq -r '.rationale')"
if [ "$changed_by_recorded" = "worker-report" ] && [ "$rationale_recorded" = "前提被推翻" ]; then
  pass "goal：goal_history 記錄 changed_by 與 rationale"
else
  bad "goal：changed_by='$changed_by_recorded' rationale='$rationale_recorded'"
fi

old_success_recorded="$(printf '%s' "$last_entry" | jq -r '.old.success')"
new_success_recorded="$(printf '%s' "$last_entry" | jq -r '.new.success')"
if [ "$old_success_recorded" = "b" ] && [ "$new_success_recorded" = "b2 改過的成功定義" ]; then
  pass "goal：goal_history 記錄變更前後的成功定義"
else
  bad "goal：old='$old_success_recorded' new='$new_success_recorded'"
fi

changed_at_recorded="$(printf '%s' "$last_entry" | jq -r '.changed_at // empty')"
if [ -n "$changed_at_recorded" ]; then
  pass "goal：goal_history 記錄時間戳"
else
  bad "goal：goal_history 缺時間戳"
fi

# ===== provider 驅動表：kind 白名單 =====
# 這幾條斷言改寫成 if/then/else/fi，不是任務簡報原始給的
# `(...) && pass ... || bad ...` 串接：理由與上面「命名正規化」小節說
# 明的 SC2015 成因相同，判斷式與訊息完全不變。
for k in claude codex agy opencode; do
  if ( hat_assert_supported_kind "$k" ) >/dev/null 2>&1; then
    pass "kind 白名單：$k 放行"
  else
    bad "kind 白名單：$k 被誤拒"
  fi
done

for k in gemini cursor omp mastracode pi; do
  rc=0
  ( hat_assert_supported_kind "$k" ) >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 4 ]; then
    pass "kind 白名單：$k 以 4 拒絕"
  else
    bad "kind 白名單：$k 沒被拒（rc=$rc）"
  fi
done

msg="$( ( hat_assert_supported_kind gemini ) 2>&1 || true )"
case "$msg" in
  *claude*codex*agy*opencode*) pass "kind 白名單：錯誤訊息點名支援清單" ;;
  *) bad "kind 白名單：錯誤訊息沒有點名清單：$msg" ;;
esac

# ===== provider 驅動表：保真度分級與啟動框允許清單 =====
if [ "$(hat_kind_fidelity agy)" = "low" ]; then
  pass "保真度：agy 低"
else
  bad "保真度：agy 判錯"
fi

if [ "$(hat_kind_fidelity claude)" = "high" ]; then
  pass "保真度：claude 高"
else
  bad "保真度：claude 判錯"
fi

k="$(hat_approval_allowlist startup_update)"
if [ "$k" = "2" ]; then
  pass "允許清單：startup_update 按 2"
else
  bad "允許清單：得到 '$k'"
fi

rc=0
( hat_approval_allowlist some_unknown_rule ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "允許清單：未知規則名不放行"
else
  bad "允許清單：未知規則名被放行（這會按下沒見過的鍵）"
fi

# ===== launch-worker.sh：八步啟動序列 =====
# 沿用既有已匯出的 AGENT_TEAM_HOME=$T/teamhome、HOME=$T/fakehome、
# HERDR_WORKSPACE_ID=w3N；$REG 沿用「registry 讀寫」小節算出的值，路
# 徑推導不變。
BRIEF="$T/briefing.md"
printf '啟動包初始內容（測試用，實際內容在下面「啟動包複製」測試會被換掉）\n' > "$BRIEF"

# 清掉可能殘留自「registry 讀寫」小節的 inbox/1-w3n-backend.json（那筆
# 記錄只有 .token 沒有 .worker）。就算不清也不會被誤判成這個 worker
# 的 ack（下面 ACK 輪詢比對 .worker 時，缺席的 .worker 恆不等於任何真
# 實名稱），這裡純粹是讓本節的前置狀態一開始就乾淨、不必靠這層推理。
rm -f "$REG"/inbox/*-w3n-backend.json

# ---- 八步序列第 1 步：開工閘門（任務簡報 Step 1 逐字）----
jq '.goal_confirmed = false' "$REG/team.json" > "$T/t" && mv "$T/t" "$REG/team.json"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "launch：goal 未確認時擋住"
else
  bad "launch：未確認卻放行（rc=$rc）"
fi
# 還原：後面每一步都假設 goal 已確認，否則全部會卡在這一關。
hat_json_set "$REG/team.json" '.goal_confirmed' 'true'

# ---- 本任務自行補上：team.json 沒有 orchestrator_name 時以 5 結束
#      （任務簡報第 1 步文字明訂「沒有以 5 結束」，但 Step 1-7 沒有排
#      定測試步驟覆蓋這一半）----
saved_team_json="$(cat "$REG/team.json")"
jq 'del(.orchestrator_name)' "$REG/team.json" > "$T/t" && mv "$T/t" "$REG/team.json"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "launch：team.json 沒有 orchestrator_name 時以 5 結束"
else
  bad "launch：得到 rc=$rc"
fi
printf '%s' "$saved_team_json" > "$REG/team.json"

# ---- 本任務自行補上：呼叫端用錯的三個防呆（Produces 有列出完整介
#      面，Step 1-7 沒有排定測試步驟覆蓋）----
rc=0; bash "$SCRIPTS/launch-worker.sh" --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "launch：缺 --role 以 2 結束"
else
  bad "launch：得到 rc=$rc"
fi

rc=0; bash "$SCRIPTS/launch-worker.sh" --role argtest --kind gemini --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "launch：不支援的 kind 以 4 結束"
else
  bad "launch：得到 rc=$rc"
fi

rc=0; bash "$SCRIPTS/launch-worker.sh" --role argtest --kind claude --cwd . --briefing-file "$T/no-such-briefing.md" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "launch：--briefing-file 指向不存在的檔案以 2 結束"
else
  bad "launch：得到 rc=$rc"
fi

# ---- Step 2（任務簡報逐字）：tab create 取不到識別碼就不寫 registry ----
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "tab create" ] && { printf '{"result":{}}'; exit 0; }
printf '{"result":{}}'; exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-bad-identifiers

before="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
after="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
if [ "$rc" -eq 6 ]; then
  pass "launch：識別碼取不到以 6 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ "$before" = "$after" ]; then
  pass "launch：識別碼取不到時沒有寫 registry"
else
  bad "launch：寫出了孤兒記錄"
fi

# ---- 本任務自行補上（審查回合 1 覆蓋度缺口）：字面字串 "null" 那個
#      分支要真的被觸發過，不能只靠「空結果物件」永遠只測到空字串那
#      一半 ----
# `jq -r '... // empty'` 對「路徑缺席」與「值真的是 JSON null」都會印
# 出空字串，上面那組斷言測的正是這一半；但若酬載裡的值本身是「字串型
# 別的 null」（值是 "null" 這四個字元組成的字串，不是 JSON null 型
# 別），`// empty` 不會攔下它——只有 JSON null／false 才會被換成
# empty，非空字串（即使內容剛好是 "null"）對 `//` 而言是真值，會原樣
# 印出 "null" 文字。這是另一半分支，任務簡報明講兩種情況各要測一次，
# 已用真實 jq 1.8.2 對三種資料形狀分別實測過此行為。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create") printf '{"result":{"tab":{"tab_id":"null"},"root_pane":{"pane_id":"w3N:p9"}}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-string-null

before="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role nulltest --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
after="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
if [ "$rc" -eq 6 ]; then
  pass "launch：識別碼是字面字串 null 時以 6 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ "$before" = "$after" ]; then
  pass "launch：字面字串 null 的識別碼也沒有寫 registry"
else
  bad "launch：寫出了孤兒記錄"
fi

# ---- 本任務自行補上（審查回合 1 Important）：重試迴圈疊加「識別碼
#      取不到」時，不得留下指向已死 tab 的孤兒記錄，rc=6 的訊息也必
#      須照實反映「這是重試路徑、上一筆記錄已清除」----
# 樁用計數器檔案分辨這是第幾次 tab create：第一次回合法識別碼（讓第 2
# 步通過、第 3 步真的把座標寫進 registry）；agent start 一律失敗（觸
# 發重試，見規格 §6 的重試規則）；第二次 tab create 回一個空的結果物
# 件（重演「重試之後又碰上識別碼取不到」這個組合情境）。
printf '0' > "$T/retry-orphan-count"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "tab create")
    n="\$(cat "$T/retry-orphan-count")"
    n=\$((n + 1))
    printf '%s' "\$n" > "$T/retry-orphan-count"
    if [ "\$n" -eq 1 ]; then
      printf '{"result":{"tab":{"tab_id":"w3N:t9"},"root_pane":{"pane_id":"w3N:p9"}}}'
    else
      printf '{"result":{}}'
    fi
    ;;
  "agent start") exit 1 ;;
  "tab close")   printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-retry-orphan

rc=0
msg="$(bash "$SCRIPTS/launch-worker.sh" --role retryorphan --kind claude --cwd . --briefing-file "$BRIEF" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "launch：重試後第二次識別碼取不到仍以 6 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ ! -e "$REG/workers/w3n-retryorphan.json" ]; then
  pass "launch：重試疊加識別碼取不到時，上一次嘗試留下的孤兒記錄已被清除"
else
  bad "launch：registry 留下了一筆指向已死 tab 的孤兒記錄"
fi
case "$msg" in
  *"未寫入 registry"*)
    bad "launch：這是重試路徑卻仍宣稱「未寫入 registry」，訊息與實際狀態不符"
    ;;
  *"已一併移除"*)
    pass "launch：rc=6 的訊息照實反映「重試路徑、上一筆記錄已清除」"
    ;;
  *)
    bad "launch：訊息內容不如預期：$msg"
    ;;
esac

# ---- 本任務自行補上：入口守衛 hat_assert_workspace 真的接上（Task 15
#      要求接受 target 的八支腳本都必須呼叫它，這裡驗證的是「真的被
#      跑到且真的能擋下」，不是只有函式名出現在檔案裡）----
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create") printf '{"result":{"tab":{"tab_id":"other:t9"},"root_pane":{"pane_id":"other:p9"}}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-workspace-guard

before="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role wsguard --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
after="$(find "$REG/workers" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
if [ "$rc" -eq 4 ]; then
  pass "launch：新建座標不屬於本 workspace 時以 4 結束（入口守衛真的接上）"
else
  bad "launch：得到 rc=$rc"
fi
if [ "$before" = "$after" ]; then
  pass "launch：workspace 守衛擋下時沒有寫 registry"
else
  bad "launch：workspace 守衛擋下卻仍寫了 registry"
fi

# ---- Step 3（任務簡報逐字，測的是規格 §2.3 那個致命發現）：agent
#      start 成功但 ACK 沒到＝啟動失敗 ----
# 樁把每次呼叫的子指令追加到 $T/herdr-calls（任務簡報 Step 4 就是讀這
#個檔案），這一行是任務簡報 Step 3 給的樁沒有的，是接上 Step 4 斷言
# 的必要補丁。
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$T/herdr-calls"
case "\$1 \$2" in
  "tab create")  printf '{"result":{"tab":{"tab_id":"w3N:t9"},"root_pane":{"pane_id":"w3N:p9"}}}' ;;
  "agent start") printf '{"result":{}}' ;;
  "agent get")   printf '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent prompt") printf '{"result":{}}' ;;
  "tab close")   printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-ack-timeout

: > "$T/herdr-calls"
rc=0; bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" --ack-timeout 2 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 8 ]; then
  pass "launch：agent start 成功但無 ACK 仍判失敗"
else
  bad "launch：把假就緒當成功（rc=$rc）"
fi

# ---- Step 4（任務簡報逐字）：啟動失敗會關掉 tab 並重試一次 ----
# 讀的是上面 Step 3 那次呼叫留下的 $T/herdr-calls：一次呼叫內部重試兩
# 次，`tab close` 理應出現兩次。`grep -c` 在零命中時結束碼是 1，套件
# 開頭有 `set -euo pipefail`，裸賦值會觸發 errexit；用 `|| true` 讓賦
# 值本身不受命令本身結束碼影響（`-c` 不論命中與否都會印出數字），沿用
# 檔頭「安全寫法」的既有慣例。
n="$(grep -c 'tab close' "$T/herdr-calls")" || true
if [ "$n" -ge 2 ]; then
  pass "launch：失敗後關 tab 並重試一次"
else
  bad "launch：tab close 只出現 $n 次（應為 2，重試前後各一）"
fi

# ---- Step 5（任務簡報逐字）：blocked 檢查存在 ----
# 樁額外把完整引數追加到 $HERDR_FULL_ARGS（下面 Step 7 要讀），任務簡
# 報 Step 5 的樁沒有這一行，是接上 Step 7 斷言的必要補丁。
HERDR_FULL_ARGS="$T/herdr-full-args"
: > "$HERDR_FULL_ARGS"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$HERDR_CALL_LOG"
printf '%s\n' "\$*" >> "$HERDR_FULL_ARGS"
case "\$1 \$2" in
  "tab create")  printf '{"result":{"tab":{"tab_id":"w3N:t9"},"root_pane":{"pane_id":"w3N:p9"}}}' ;;
  "agent get")   printf '{"result":{"agent":{"agent_status":"blocked"}}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-blocked

: > "$HERDR_CALL_LOG"
# 任務簡報這裡給的原始寫法是裸陳述句（沒有 `|| true`）：這次呼叫必然
# 以非 0 結束（blocked 重試一次仍 blocked，最終 8），套件開頭的
# `set -euo pipefail` 會讓裸陳述句觸發 errexit、整份套件行程被帶走。
# 補上 `|| true`，跟本檔「命令替換/指令之後不得裸讀結束碼」同一條強制
# 寫法背後的理由一致：不guard 過的非 0 結束碼底下藏著 errexit。
bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" --ack-timeout 2 >/dev/null 2>&1 || true
if grep -q 'agent get' "$HERDR_CALL_LOG"; then
  pass "launch：送啟動包前有查狀態"
else
  bad "launch：跳過了 blocked 檢查"
fi
if grep -q 'agent prompt' "$HERDR_CALL_LOG"; then
  bad "launch：blocked 狀態下仍送出啟動包（第一則會被框吃掉）"
else
  pass "launch：blocked 狀態下不送啟動包"
fi

# ---- Step 6（任務簡報逐字）：啟動包被複製進 registry ----
# 沿用上面 Step 5 裝好的 blocked 樁：這個情境下第 3 步（寫 registry＋
# 複製啟動包）本來就排在第 5 步（blocked 檢查）之前，所以同一個會走到
# blocked 失敗的樁，仍然足以驗證複製有沒有發生。
printf '這是啟動包全文_BRIEFING_MARKER\n' > "$BRIEF"
bash "$SCRIPTS/launch-worker.sh" --role backend --kind claude --cwd . --briefing-file "$BRIEF" --ack-timeout 2 >/dev/null 2>&1 || true
if [ -f "$REG/briefings/w3n-backend.md" ]; then
  pass "launch：啟動包複製進 registry"
else
  bad "launch：啟動包沒有落進 registry（中斷後無法重建派工脈絡）"
fi
if grep -q 'BRIEFING_MARKER' "$REG/briefings/w3n-backend.md" 2>/dev/null; then
  pass "launch：複製的是內容不是路徑"
else
  bad "launch：briefings 檔內容不是啟動包全文"
fi

# ---- Step 7（任務簡報逐字）：--env 五個變數都注入 ----
args="$(grep -m1 'tab create' "$HERDR_FULL_ARGS")" || true
for v in AGENT_TEAM_STATE_DIR AGENT_TEAM_ORCHESTRATOR AGENT_TEAM_SELF AGENT_TEAM_ROLE AGENT_TEAM_SCRIPTS; do
  case "$args" in
    *"$v="*) pass "launch：注入 $v" ;;
    *) bad "launch：沒有注入 $v" ;;
  esac
done

# ---- 本任務自行補上：完整成功路徑（八步全部走完，Step 1-7 完全沒有
#      測到這條唯一會走到 rc=0 的路徑）與 ack_reconciliation 對帳欄位
#      的內容，含 --arg 原生引數直通 ----
# ack 的摘要格式（`worker_id=<id> cwd=<路徑> model=<名稱>`）是本次實作
# 定義的介面，見 launch-worker.sh 檔頭「ACK 摘要格式」一節——規格只說
# ack 要帶這三項，沒有規定怎麼從 report.sh 唯一保證送達的 --summary
# 欄位搭載過來，回報這個落差、由編排端決定要不要回填進 Task 7／
# Task 13 的任務簡報，見任務報告。這裡驗證的是「照這個格式送，對帳邏
# 輯真的解析得出來」，不是驗證 report.sh 本身（那是 Task 7 的職責）。
HERDR_FULL_ARGS="$T/herdr-full-args-success"
: > "$HERDR_FULL_ARGS"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HERDR_FULL_ARGS"
case "\$1 \$2" in
  "tab create")  printf '{"result":{"tab":{"tab_id":"w3N:t7"},"root_pane":{"pane_id":"w3N:p7"}}}' ;;
  "agent start") printf '{"result":{}}' ;;
  "agent get")   printf '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent prompt")
    printf '{"token":"ack","worker":"w3n-success","summary":"worker_id=w3n-success cwd=$REG model=claude-3-test"}' > "$REG/inbox/9-w3n-success.json"
    printf '{"result":{}}'
    ;;
  "tab close")   printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-success

rc=0
out="$(bash "$SCRIPTS/launch-worker.sh" --role success --kind claude --cwd "$REG" --briefing-file "$BRIEF" --ack-timeout 5 --arg --model --arg test-model 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "launch：八步全部走完以 0 結束"
else
  bad "launch：得到 rc=$rc"
fi

expected_out="worker=w3n-success pane=w3N:p7 tab=w3N:t7 ack=ok"
if [ "$out" = "$expected_out" ]; then
  pass "launch：成功輸出格式正確"
else
  bad "launch：輸出格式不如預期：$out（預期：$expected_out）"
fi

held_after="$(jq -r '.held' "$REG/workers/w3n-success.json")"
if [ "$held_after" = "false" ]; then
  pass "launch：成功啟動後持有旗標初值為 false"
else
  bad "launch：held='$held_after'"
fi

wid_match="$(jq -r '.ack_reconciliation.worker_id_match' "$REG/workers/w3n-success.json")"
cwd_match="$(jq -r '.ack_reconciliation.cwd_match' "$REG/workers/w3n-success.json")"
model_reported="$(jq -r '.ack_reconciliation.model_reported' "$REG/workers/w3n-success.json")"
if [ "$wid_match" = "true" ] && [ "$cwd_match" = "true" ] && [ "$model_reported" = "claude-3-test" ]; then
  pass "launch：ack_reconciliation 正確對帳 worker-id／cwd／model"
else
  bad "launch：ack_reconciliation 內容不如預期（worker_id_match=$wid_match cwd_match=$cwd_match model_reported=$model_reported）"
fi

line="$(grep -m1 'agent start' "$HERDR_FULL_ARGS")" || true
case "$line" in
  *"-- --model test-model"*) pass "launch：--arg 原生引數直通到 agent start" ;;
  *) bad "launch：--arg 沒有正確直通：$line" ;;
esac

# ---- 本任務自行補上（審查回合 2 裁決）：兩次都失敗、終局以 8 結束
#      時，不得留下該 worker 的狀態記錄——與審查回合 1「重試疊加識別
#      碼取不到」那條路徑採一致的語意。三種失敗成因（啟動指令失敗、
#      查到被阻擋狀態、等不到 worker 回報而逾時）各測一次，每條都斷言
#      最終以 8 結束、且狀態目錄裡沒有留下該 worker 的記錄。訊息內容
#      （「狀態記錄已移除」與「該名稱仍可用於讀畫面與送按鍵、處理完之
#      後重跑本腳本」兩句話都要在）只在第一條（啟動指令失敗）驗證一
#      次：三種成因共用同一句 hat_die 8 訊息模板，驗證一次即可代表全
#      部三種成因的訊息內容，不必逐條重複驗證同一件事。

# 成因一：agent start 一律失敗（herdr 拒絕，結束碼 1）。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create")  printf '{"result":{"tab":{"tab_id":"w3N:t5"},"root_pane":{"pane_id":"w3N:p5"}}}' ;;
  "agent start") exit 1 ;;
  "tab close")   printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-final-fail-agentstart

rc=0
msg="$(bash "$SCRIPTS/launch-worker.sh" --role startfail --kind claude --cwd . --briefing-file "$BRIEF" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 8 ]; then
  pass "launch：agent start 一律失敗、兩次都失敗後以 8 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ ! -e "$REG/workers/w3n-startfail.json" ]; then
  pass "launch：agent start 終局失敗後，狀態記錄已移除"
else
  bad "launch：終局失敗卻留下了指向已死 tab 的狀態記錄"
fi
case "$msg" in
  *"狀態記錄已移除"*) pass "launch：rc=8 訊息明講狀態記錄已移除" ;;
  *) bad "launch：rc=8 訊息沒有明講狀態記錄已移除：$msg" ;;
esac
case "$msg" in
  *"herdr agent read"*"herdr agent send-keys"*"重跑本腳本"*)
    pass "launch：rc=8 訊息仍保留名稱可用於讀畫面／送按鍵／重跑的指引"
    ;;
  *)
    bad "launch：rc=8 訊息漏了名稱可用於讀畫面／送按鍵／重跑的指引：$msg"
    ;;
esac

# 成因二：查到被阻擋狀態（agent_status=blocked）。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create") printf '{"result":{"tab":{"tab_id":"w3N:t6"},"root_pane":{"pane_id":"w3N:p6"}}}' ;;
  "agent get")  printf '{"result":{"agent":{"agent_status":"blocked"}}}' ;;
  "tab close")  printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-final-fail-blocked

rc=0; bash "$SCRIPTS/launch-worker.sh" --role blockedfinal --kind claude --cwd . --briefing-file "$BRIEF" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 8 ]; then
  pass "launch：blocked 兩次都撞上後以 8 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ ! -e "$REG/workers/w3n-blockedfinal.json" ]; then
  pass "launch：blocked 終局失敗後，狀態記錄已移除"
else
  bad "launch：終局失敗卻留下了指向已死 tab 的狀態記錄"
fi

# 成因三：等不到 worker 回報而逾時（agent start／blocked 檢查都過，
# 送出啟動包後 inbox 裡永遠沒有出現這個 worker 的 ack）。
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "tab create")   printf '{"result":{"tab":{"tab_id":"w3N:t8"},"root_pane":{"pane_id":"w3N:p8"}}}' ;;
  "agent start")  printf '{"result":{}}' ;;
  "agent get")    printf '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "agent prompt") printf '{"result":{}}' ;;
  "tab close")    printf '{"result":{}}' ;;
  *) printf '{"result":{}}' ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" launch-final-fail-acktimeout

rc=0; bash "$SCRIPTS/launch-worker.sh" --role acktimeoutfinal --kind claude --cwd . --briefing-file "$BRIEF" --ack-timeout 2 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 8 ]; then
  pass "launch：ACK 逾時兩次都發生後以 8 結束"
else
  bad "launch：得到 rc=$rc"
fi
if [ ! -e "$REG/workers/w3n-acktimeoutfinal.json" ]; then
  pass "launch：ACK 逾時終局失敗後，狀態記錄已移除"
else
  bad "launch：終局失敗卻留下了指向已死 tab 的狀態記錄"
fi

# ===== report.sh：worker 上行 =====
# 沿用既有已匯出的 AGENT_TEAM_HOME=$T/teamhome、HOME=$T/fakehome、
# HERDR_WORKSPACE_ID=w3N；$REG 沿用「registry 讀寫」小節算出的值。額外
# 匯出 report.sh 專屬需要的三個環境變數：AGENT_TEAM_STATE_DIR 直接給
# $REG（report.sh 不呼叫 hat_registry_root，見腳本檔頭「序號配發」一
# 節的說明，因此不能靠 AGENT_TEAM_HOME／HERDR_WORKSPACE_ID 間接推導，
# 必須直接給同一個目錄）、AGENT_TEAM_SELF 是這個 worker 的名稱、
# AGENT_TEAM_ORCHESTRATOR 是收件人名稱（樁不檢查這個值，任意取一個）。
export AGENT_TEAM_STATE_DIR="$REG" AGENT_TEAM_SELF="w3n-reporter" AGENT_TEAM_ORCHESTRATOR="w3n-orchestrator"

# 清空 inbox／details／replies 三個目錄：讓本節從乾淨、可預期的狀態開
# 始，與其他小節（registry 讀寫、launch-worker 等）各自在自己開頭清場
# 的既有慣例一致，避免前面小節留下的檔案干擾本節的斷言。
rm -rf "$REG/inbox" "$REG/details" "$REG/replies"
mkdir -p "$REG/inbox" "$REG/details" "$REG/replies"

# hat_last_seq_for_worker <worker>
# 印出 $REG/inbox 底下屬於 <worker> 的所有記錄裡，seq 數值最大的那一
# 個。本節後面幾個「本任務自行補上」的斷言需要「找出我剛剛那次呼叫寫
# 出的是哪一筆」，用數值排序：若改用字典排序（例如 `ls | tail -1`），
# seq 跨過個位數（例如 9 之後到 10）就會失真，"10" 會排在 "2" 前面。本
# 節目前的真實寫入次數還在個位數以內，兩種排序法結果相同，但把「找我
# 自己那一筆」這件事寫成不依賴這個巧合，之後這裡再插入新的斷言也不會
# 悄悄壞掉。修正迴圈第一輪之後，Step 5 本身已經改用 team.json 的
# next_seq 直接預測序號（見下方），不再用 `ls | tail -1`；本函式只給
# 本節自行補上的其餘斷言使用。
hat_last_seq_for_worker() {
  local worker="$1" f base num best=""
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    num="${base%%-*}"
    if [ -z "$best" ] || [ "$num" -gt "$best" ]; then
      best="$num"
    fi
  done < <(find "$REG/inbox" -maxdepth 1 -type f -name "*-$worker.json" -print0 2>/dev/null)
  printf '%s\n' "$best"
}

HERDR_CALL_LOG="$T/herdr-call-log-report"
HERDR_FULL_ARGS="$T/herdr-full-args-report"
: > "$HERDR_CALL_LOG"
: > "$HERDR_FULL_ARGS"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1 \$2" >> "$HERDR_CALL_LOG"
printf '%s\n' "\$*" >> "$HERDR_FULL_ARGS"
printf '{"result":{}}'
exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" report-uplink

# ---- Step 1（任務簡報逐字；&&/|| 鏈改寫成 if/then/else/fi）：token 白
#      名單與環境缺席 ----
rc=0; ( unset AGENT_TEAM_STATE_DIR; bash "$SCRIPTS/report.sh" --token fyi --summary x ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  pass "report：狀態目錄缺席時失敗"
else
  bad "report：環境缺席卻成功"
fi

msg="$( ( unset AGENT_TEAM_STATE_DIR; bash "$SCRIPTS/report.sh" --token fyi --summary x ) 2>&1 || true )"
case "$msg" in
  *--state-dir*) pass "report：錯誤訊息提示備援參數" ;;
  *) bad "report：沒有提示 --state-dir" ;;
esac

rc=0; bash "$SCRIPTS/report.sh" --token 沒事 --summary x >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "report：token 白名單外以 2 拒絕"
else
  bad "report：接受了不存在的 token"
fi

# ---- 本任務自行補上：AGENT_TEAM_SELF／AGENT_TEAM_ORCHESTRATOR 缺席
#      （任務簡報 Interfaces 明講從環境讀這兩個變數，Step 1-5 只排了
#      AGENT_TEAM_STATE_DIR 缺席的測試，沒有排這兩個）----
rc=0; ( unset AGENT_TEAM_SELF; bash "$SCRIPTS/report.sh" --token fyi --summary x ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "report：AGENT_TEAM_SELF 缺席時以 4 結束"
else
  bad "report：得到 rc=$rc"
fi

rc=0; ( unset AGENT_TEAM_ORCHESTRATOR; bash "$SCRIPTS/report.sh" --token fyi --summary x ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "report：AGENT_TEAM_ORCHESTRATOR 缺席時以 4 結束"
else
  bad "report：得到 rc=$rc"
fi

# ---- 本任務自行補上：--state-dir 在環境變數缺席時仍可運作（Produces
#      有列這個參數，Step 1-5 只測了「兩者都沒給」失敗的那一半，沒有測
#      「有給 --state-dir 就能成功」這一半）----
rc=0; ( unset AGENT_TEAM_STATE_DIR; bash "$SCRIPTS/report.sh" --token fyi --summary x --state-dir "$REG" ) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "report：--state-dir 覆寫在環境變數缺席時仍可運作"
else
  bad "report：得到 rc=$rc"
fi

# ---- 本任務自行補上，審查回合二 Critical 1 回歸測試：只給
#      launch-worker.sh 實際會注入的那五個變數（AGENT_TEAM_STATE_DIR／
#      AGENT_TEAM_ORCHESTRATOR／AGENT_TEAM_SELF／AGENT_TEAM_ROLE／
#      AGENT_TEAM_SCRIPTS），完全不設 AGENT_TEAM_HOME，且 cwd 換到跟
#      registry 根無關的目錄，完整跑一次回報流程 ----
# 這條斷言存在的理由，就是防止測試再度靠全域 export 意外對齊：本節開
# 頭到現在，AGENT_TEAM_HOME 一直是「registry 讀寫」小節匯出的
# $T/teamhome，而 $REG 本身也是拿同一個 AGENT_TEAM_HOME 算出來的，兩
# 邊自然對齊——這個對齊只在測試裡成立，真實 worker 環境從來不會有
# AGENT_TEAM_HOME。子殼裡刻意 unset 它、把 cwd 換成 $T 底下一個新目
# 錄，模擬真實 worker 執行時的環境形狀。
diff_cwd="$T/report-diff-cwd"
mkdir -p "$diff_cwd"
rc=0
(
  unset AGENT_TEAM_HOME
  export AGENT_TEAM_ROLE="backend" AGENT_TEAM_SCRIPTS="$SCRIPTS"
  cd "$diff_cwd" || exit 1
  bash "$SCRIPTS/report.sh" --token fyi --summary '只有五個變數也要能完整回報'
) >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "report：只有五個注入變數、cwd 與 registry 根不同時仍成功回報"
else
  bad "report：得到 rc=$rc（Critical 1 回歸：共用寫入函式又重算了 registry 根）"
fi
five_var_seq="$(hat_last_seq_for_worker w3n-reporter)"
five_var_worker="$(jq -r '.worker' "$REG/inbox/${five_var_seq}-w3n-reporter.json" 2>/dev/null)" || five_var_worker=""
if [ "$five_var_worker" = "w3n-reporter" ]; then
  pass "report：五變數情境下，inbox 記錄六個欄位真的寫進去了（不是裸空物件）"
else
  bad "report：inbox 記錄沒有正確寫入（worker='$five_var_worker'），可能又是裸的 {}"
fi

# ===== Step 2（任務簡報逐字；&&/|| 鏈改寫成 if/then/else/fi）：working
#      只落檔不投遞 =====
: > "$HERDR_CALL_LOG"
bash "$SCRIPTS/report.sh" --token working --summary '這回合沒事' >/dev/null 2>&1
# shellcheck disable=SC2012 # 任務簡報逐字；檔名全由本測試套件自己控制（十進位 seq 加正規化過的 worker 名），不含 ls 處理不了的特殊字元
if [ "$(ls "$REG/inbox" | wc -l)" -ge 1 ]; then
  pass "report：working 有落檔"
else
  bad "report：working 沒落檔"
fi
if grep -q 'agent prompt' "$HERDR_CALL_LOG"; then
  bad "report：working 被投遞上去了（這會淹掉 orchestrator）"
else
  pass "report：working 不投遞"
fi

# ===== Step 3（任務簡報逐字；grep -m1 補上 `|| true`，理由與
#      launch-worker 那節既有的同型寫法相同：找不到相符行時 grep 回非
#      0，裸賦值會被 errexit 帶走整個套件）：投遞不帶握手選項 =====
: > "$HERDR_FULL_ARGS"
bash "$SCRIPTS/report.sh" --token fyi --summary '一則說一聲' >/dev/null 2>&1
line="$(grep -m1 'agent prompt' "$HERDR_FULL_ARGS")" || true
case "$line" in
  *--wait*|*--until*|*--timeout*) bad "report：投遞帶了握手選項，會引入 agent_prompt_stalled 歧義" ;;
  *) pass "report：投遞不帶握手選項" ;;
esac

# ---- 本任務自行補上：正面驗證真的投遞成功（上面那條斷言只驗證「沒
#      有出現壞的選項」，若樁根本沒被叫到，$line 會是空字串，一樣落進
#      「沒有壞選項」那個分支而誤判成功——本節在證明 PATH guard 那段時
#      已經實測到這個弱點：樁真的缺席時，這條字面斷言仍然會判成通過。
#      補這一條，用 .delivery 欄位正面確認樁真的被呼叫且回報成功，讓
#      這個弱點不再是唯一的防線）----
fyi_seq="$(hat_last_seq_for_worker w3n-reporter)"
delivered_status="$(jq -r '.delivery' "$REG/inbox/${fyi_seq}-w3n-reporter.json")"
if [ "$delivered_status" = "delivered" ]; then
  pass "report：fyi 正常投遞成功時，delivery 標成 delivered"
else
  bad "report：delivery 欄位是 '$delivered_status'，投遞可能根本沒有真的執行"
fi

# ===== Step 4（任務簡報逐字；&&/|| 鏈改寫成 if/then/else/fi；
#      prev_count 由本任務補上初值——任務簡報這裡引用了這個變數卻沒有
#      先賦值，見任務報告）：摘要超長拒絕 =====
# shellcheck disable=SC2012 # 理由同上一個 ls | wc -l：檔名全由本測試套件自己控制
prev_count="$(ls "$REG/inbox" | wc -l)"
long="$(printf 'x%.0s' {1..600})"
rc=0; out="$(bash "$SCRIPTS/report.sh" --token fyi --summary "$long" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "report：超長摘要以 2 拒絕"
else
  bad "report：超長摘要沒被拒（rc=$rc）"
fi
case "$out" in
  *--detail-file*) pass "report：錯誤訊息教人用 detail 欄位" ;;
  *) bad "report：錯誤訊息沒有教下一步" ;;
esac
# shellcheck disable=SC2012 # 理由同上：檔名全由本測試套件自己控制
if [ "$(ls "$REG/inbox" | wc -l)" = "$prev_count" ]; then
  pass "report：拒絕時不落檔"
else
  bad "report：拒絕了卻還是落了檔"
fi

# ---- 本任務自行補上，審查回合二 Critical 2 要求加強：ack 一律豁免摘
#      要長度上限，用一個真的超過 500 字元的合法格式字串驗證，不是只
#      測一個本來就在上限內、就算沒有豁免也會通過的短字串（審查者用
#      575 字元的真實案例撞到這個洞：worktree 慣例下的深路徑就會把固
#      定格式推過 500，被拒絕時完全不落檔，比截斷更嚴重）----
long_cwd="/$(printf 'x%.0s' {1..520})"
ack_summary="worker_id=w3n-reporter cwd=$long_cwd model=claude-3-test"
if [ "${#ack_summary}" -le 500 ]; then
  bad "report：測試前提不成立，ack_summary 只有 ${#ack_summary} 字元，沒有真的超過 500"
else
  pass "report：測試前提成立，ack_summary 有 ${#ack_summary} 字元，確實超過 500"
fi
rc=0; bash "$SCRIPTS/report.sh" --token ack --summary "$ack_summary" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "report：超過 500 字元的 ack 摘要仍被接受（一律豁免，不是提高上限）"
else
  bad "report：ack 摘要被擋下（rc=$rc），對帳會靜默失效"
fi
ack_seq="$(hat_last_seq_for_worker w3n-reporter)"
recorded_ack_summary="$(jq -r '.summary' "$REG/inbox/${ack_seq}-w3n-reporter.json")"
if [ "$recorded_ack_summary" = "$ack_summary" ]; then
  pass "report：超長 ack 摘要正常落檔，內容完整未被截斷"
else
  bad "report：落檔的摘要與原文不符，可能被截斷或寫壞"
fi

# ===== Step 5（修正迴圈第一輪重新產生的簡報逐字；&&/|| 鏈改寫成
#      if/then/else/fi；成功那次呼叫的 out 賦值補上 `|| true`，理由同
#      Step 3）：need-you 阻塞、逾時退場、只認自己這次的 seq =====
start=$(date +%s)
rc=0; bash "$SCRIPTS/report.sh" --token need-you --summary '要定案' --wait-timeout 3 >/dev/null 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))
if [ "$rc" -eq 7 ]; then
  pass "report：need-you 逾時以 7 結束（非失敗）"
else
  bad "report：得到 rc=$rc"
fi
if [ "$elapsed" -ge 3 ]; then
  pass "report：need-you 真的有阻塞等待"
else
  bad "report：沒有等待就返回"
fi

# 回覆放在「本次呼叫配到的那個 seq」底下才算數。
# 先預測下一個序號（team.json 的 next_seq），把回覆先放好，再發問。
next="$(jq -r '.next_seq' "$REG/team.json")"
mkdir -p "$REG/replies/$AGENT_TEAM_SELF"
printf '{"decision":"照 A 案做"}' > "$REG/replies/$AGENT_TEAM_SELF/$next.json"
out="$(bash "$SCRIPTS/report.sh" --token need-you --summary '再問一次' --wait-timeout 5 2>/dev/null)" || true
case "$out" in
  *照\ A\ 案做*) pass "report：取回本次 seq 的定案內容並印出" ;;
  *) bad "report：沒有印出定案內容" ;;
esac

# 舊 seq 底下的回覆不得滿足新的一次發問——這條是防「第二個問題收到第一
# 個問題的答案」的回歸測試（修正迴圈第一輪的核心裁決）。
stale="$(jq -r '.next_seq' "$REG/team.json")"
printf '{"decision":"這是上一題的答案"}' > "$REG/replies/$AGENT_TEAM_SELF/$stale.json"
bash "$SCRIPTS/report.sh" --token need-you --summary '第一題' --wait-timeout 3 >/dev/null 2>&1 || true
rc=0; out2="$(bash "$SCRIPTS/report.sh" --token need-you --summary '第二題' --wait-timeout 3 2>/dev/null)" || rc=$?
if [ "$rc" -eq 7 ]; then
  pass "report：舊 seq 的回覆不會被新的一次發問取走"
else
  bad "report：第二題收到了上一題的答案（rc=$rc out='$out2'）"
fi

# ---- 本任務自行補上：--detail-file 落檔進 details/、inbox 記錄的
#      detail_path 指向該檔（任務簡報 Produces 明講「落檔到 inbox/ 與
#      details/」，Step 1-5 沒有排測試涵蓋 details/ 這一半）----
detail_src="$T/report-detail.txt"
printf '完整細節內容_DETAIL_MARKER\n' > "$detail_src"
bash "$SCRIPTS/report.sh" --token fyi --summary '含細節的一則' --detail-file "$detail_src" >/dev/null 2>&1
detail_seq="$(hat_last_seq_for_worker w3n-reporter)"
detail_dest="$REG/details/${detail_seq}-w3n-reporter.txt"
if grep -q 'DETAIL_MARKER' "$detail_dest" 2>/dev/null; then
  pass "report：--detail-file 落檔進 details/"
else
  bad "report：details/ 底下找不到細節內容"
fi
recorded_detail_path="$(jq -r '.detail_path' "$REG/inbox/${detail_seq}-w3n-reporter.json")"
if [ "$recorded_detail_path" = "$detail_dest" ]; then
  pass "report：inbox 記錄的 detail_path 指向該檔"
else
  bad "report：detail_path 記錄的是 '$recorded_detail_path'，預期 '$detail_dest'"
fi

# ---- 本任務自行補上：--locator 寫進 inbox 記錄（任務簡報 Produces 有
#      列這個參數，Step 1-5 沒有排測試涵蓋）----
bash "$SCRIPTS/report.sh" --token delivered --summary '產物可以拿去用了' --locator "https://example.invalid/pr/1" >/dev/null 2>&1
locator_seq="$(hat_last_seq_for_worker w3n-reporter)"
recorded_locator="$(jq -r '.locator' "$REG/inbox/${locator_seq}-w3n-reporter.json")"
if [ "$recorded_locator" = "https://example.invalid/pr/1" ]; then
  pass "report：--locator 寫進 inbox 記錄"
else
  bad "report：locator 記錄的是 '$recorded_locator'"
fi

# ---- 本任務自行補上：投遞被 agent_blocked 拒絕時不是本腳本的失敗
#      （這個判斷已由編排端在修正迴圈第一輪裁決採納，並加了一項要
#      求：必須在 stdout 印一行「已記錄、投遞延後」，見下方第三條斷
#      言。任務簡報的 5 個測試步驟沒有排這個分支，補上避免它完全沒有
#      自動化斷言盯著）----
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_blocked","message":"blocked"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" report-blocked-delivery

rc=0; out="$(bash "$SCRIPTS/report.sh" --token fyi --summary '對方卡住時的一則' 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "report：投遞被 agent_blocked 拒絕時，仍以 0 結束（不是本腳本的失敗）"
else
  bad "report：得到 rc=$rc"
fi
blocked_seq="$(hat_last_seq_for_worker w3n-reporter)"
delivery_status="$(jq -r '.delivery' "$REG/inbox/${blocked_seq}-w3n-reporter.json")"
if [ "$delivery_status" = "blocked" ]; then
  pass "report：投遞被拒絕時，inbox 記錄的 delivery 標成 blocked"
else
  bad "report：delivery 欄位是 '$delivery_status'"
fi
case "$out" in
  *已記錄*投遞延後*) pass "report：投遞延後時 stdout 印出提示，不完全靜默" ;;
  *) bad "report：投遞延後卻沒有印出提示，worker 會誤以為已送達：'$out'" ;;
esac

# ===== instruct.sh：下行、持有旗標、待補送 =====
# 沿用既有已匯出的 AGENT_TEAM_HOME=$T/teamhome、HOME=$T/fakehome、
# HERDR_WORKSPACE_ID=w3N；$REG 沿用「registry 讀寫」小節算出的值，路徑
# 推導不變。report.sh 小節匯出的 AGENT_TEAM_STATE_DIR／AGENT_TEAM_SELF／
# AGENT_TEAM_ORCHESTRATOR 三個環境變數留著不影響本節：instruct.sh 是
# orchestrator 端腳本，只靠 AGENT_TEAM_HOME／HERDR_WORKSPACE_ID 推導路
# 徑，不讀那三個 worker 端專屬的變數。
#
# ---- 本任務自行補上的前置設定 ----
# $REG/workers/w3n-backend.json 在「launch-worker.sh：八步啟動序列」小
# 節最後一次呼叫（role=backend，兩次嘗試皆 blocked）已被該腳本自己移除
# （見 launch-worker.sh「兩次都失敗，終局升級給人：不留下這筆狀態記
# 錄」一節）。這裡重新建一份最小可用的 worker 記錄：pane_id 給一個屬於
# 本 workspace 的座標（w3N:p2，格式沿用「workspace 守衛」小節已驗證過
# 的真實格式），held 給初值 false，模擬 launch-worker.sh 正常啟動完成
# 後的狀態。
printf '{"pane_id":"w3N:p2","held":false}' > "$REG/workers/w3n-backend.json"

HERDR_FULL_ARGS="$T/herdr-full-args-instruct"
: > "$HERDR_FULL_ARGS"
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HERDR_FULL_ARGS"
printf '{"result":{}}'; exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" instruct-hold-flag

# ---- Step 1（任務簡報逐字；&&/|| 鏈改寫成 if/then/else/fi，理由同前
#      面各節「命名正規化」小節開頭的說明）：送完放掉持有旗標 ----
bash "$SCRIPTS/instruct.sh" --to w3n-backend --text '繼續' >/dev/null 2>&1
if [ "$(jq -r '.held' "$REG/workers/w3n-backend.json")" = "false" ]; then
  pass "instruct：送完放掉持有旗標"
else
  bad "instruct：持有旗標沒放掉"
fi

# ---- Step 2（任務簡報逐字；grep -m1 補上 `|| true`，理由同 report.sh
#      「投遞不帶握手選項」一節同型寫法）：不帶握手選項 ----
line="$(grep -m1 'agent prompt' "$HERDR_FULL_ARGS")" || true
case "$line" in
  *--wait* | *--until*) bad "instruct：帶了握手選項（對做事中的對象必然逾時誤判）" ;;
  *) pass "instruct：不帶握手選項" ;;
esac

# ---- 本任務自行補上：正面驗證真的投遞成功且內容正確（上面那條斷言只
#      驗證「沒有出現壞的選項」，若樁根本沒被叫到，$line 會是空字串，
#      一樣落進「沒有壞選項」那個分支而誤判成功——report.sh「投遞不帶握
#      手選項」旁已經記錄過這個弱點，這裡補同一種正面確認）----
case "$line" in
  *"w3n-backend"*"繼續"*) pass "instruct：投遞目標與文字內容正確" ;;
  *) bad "instruct：投遞內容不如預期：$line" ;;
esac

# ---- Step 3（任務簡報逐字；&&/|| 鏈改寫成 if/then/else/fi）：blocked
#      時進待補送清單 ----
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_blocked","message":"blocked"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" instruct-blocked

rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text 'goal 更新' --kind goal-update >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 7 ]; then
  pass "instruct：blocked 以 7 結束（待補送，非失敗）"
else
  bad "instruct：得到 rc=$rc"
fi
n="$(jq -r '.pending_resend | length' "$REG/workers/w3n-backend.json")"
if [ "$n" -ge 1 ]; then
  pass "instruct：blocked 的訊息進了待補送清單"
else
  bad "instruct：待補送清單是空的（這則會永遠消失）"
fi
if [ "$(jq -r '.held' "$REG/workers/w3n-backend.json")" = "false" ]; then
  pass "instruct：blocked 時也放掉持有旗標"
else
  bad "instruct：持有旗標卡在 true"
fi

# ---- 本任務自行補上：待補送清單的內容真的可用（上面只驗證了筆數，
#      Task 12 的看門狗要靠這筆記錄的 .text／.kind 兩個欄位補投，筆數
#      對但內容是空物件一樣沒用）----
entry="$(jq -c '.pending_resend[-1]' "$REG/workers/w3n-backend.json")"
entry_text="$(printf '%s' "$entry" | jq -r '.text')"
entry_kind="$(printf '%s' "$entry" | jq -r '.kind')"
if [ "$entry_text" = "goal 更新" ] && [ "$entry_kind" = "goal-update" ]; then
  pass "instruct：待補送清單記錄 text 與 kind，供 Task 12 補投使用"
else
  bad "instruct：待補送記錄內容不對，text='$entry_text' kind='$entry_kind'"
fi

# ---- 本任務自行補上：--to／--text／--text-file／--kind 的基本用錯與白
#      名單（Produces 有列這幾個參數，Step 1-4 只涵蓋成功與 blocked 兩
#      條路徑，缺 --to、text/text-file 擇一、kind 白名單三類用錯完全沒
#      有測試涵蓋）----
rc=0; bash "$SCRIPTS/instruct.sh" --text x >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "instruct：缺 --to 以 2 結束"
else
  bad "instruct：得到 rc=$rc"
fi

rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "instruct：--text／--text-file 都沒給以 2 結束"
else
  bad "instruct：得到 rc=$rc"
fi

text_file_src="$T/instruct-text-file.txt"
printf '照 B 案' > "$text_file_src"
rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text x --text-file "$text_file_src" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "instruct：--text／--text-file 同時給以 2 結束"
else
  bad "instruct：得到 rc=$rc"
fi

rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text x --kind no-such-kind >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "instruct：--kind 白名單外以 2 拒絕"
else
  bad "instruct：接受了不存在的 kind（rc=$rc）"
fi

# ---- 本任務自行補上：--text-file 真的讀取檔案內容送出（成功路徑，
#      Step 1-4 只用過 --text，沒有排過 --text-file）----
cat > "$STUB_BIN/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HERDR_FULL_ARGS"
printf '{"result":{}}'; exit 0
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" instruct-text-file

: > "$HERDR_FULL_ARGS"
bash "$SCRIPTS/instruct.sh" --to w3n-backend --text-file "$text_file_src" >/dev/null 2>&1
line="$(grep -m1 'agent prompt' "$HERDR_FULL_ARGS")" || true
case "$line" in
  *"照 B 案"*) pass "instruct：--text-file 讀取檔案內容送出" ;;
  *) bad "instruct：--text-file 內容沒有送出：$line" ;;
esac

# ---- 本任務自行補上：--kind 不給時有預設值，仍可正常運作（Produces
#      把 --kind 列成選填，預設值本身沒有任何步驟涵蓋）----
rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text '不給 kind 也要能送' >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "instruct：--kind 不給時仍以預設值成功送出"
else
  bad "instruct：得到 rc=$rc"
fi

# ---- 本任務自行補上：入口守衛 hat_assert_workspace 真的接上（Task 15
#      要求本腳本是需要這道守衛的八支之一；比照 launch-worker.sh 該節
#      同型斷言的既有做法，驗證「真的被跑到且真的能擋下」，不是只有函
#      式名出現在檔案裡）----
printf '{"pane_id":"other:p9","held":false}' > "$REG/workers/w3n-otherws.json"
: > "$HERDR_FULL_ARGS"
rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-otherws --text x >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
  pass "instruct：workspace 守衛擋下不屬於本 workspace 的 worker"
else
  bad "instruct：得到 rc=$rc"
fi
if [ -s "$HERDR_FULL_ARGS" ]; then
  bad "instruct：workspace 守衛擋下時仍送出了訊息"
else
  pass "instruct：workspace 守衛擋下時確認沒有送出任何訊息"
fi

# ---- Step 4（任務簡報逐字）：--reply-to 同時寫回覆與標記已處理 ----
# 本任務自行補上的前置設定：--reply-to 指名的 inbox 記錄必須已存在（模
# 擬 w3n-backend 稍早用 report.sh --token need-you 送出過 seq=7 那一
# 則，處於尚未處理狀態），否則沒有東西可標記——任務簡報這一步沒有安排
# 建立這筆記錄，見任務報告。
mkdir -p "$REG/inbox"
printf '{"token":"need-you","worker":"w3n-backend","summary":"要不要照 A 案","processed_at":null}' \
  > "$REG/inbox/7-w3n-backend.json"

bash "$SCRIPTS/instruct.sh" --to w3n-backend --text '照 A 案' --reply-to 7 >/dev/null 2>&1
if [ -f "$REG/replies/w3n-backend/7.json" ]; then
  pass "instruct：寫出定案回覆"
else
  bad "instruct：沒有寫回覆檔"
fi
p="$(jq -r '.processed_at' "$REG"/inbox/7-*.json)"
if [ "$p" != "null" ]; then
  pass "instruct：順手標記該則已處理"
else
  bad "instruct：inbox 那則沒被標記（中斷恢復會重複處理）"
fi

# ---- 本任務自行補上：回覆檔的內容真的是這次送出的文字，以及
#      --reply-to 指名不存在的 inbox 記錄時以 5 結束（registry 缺漏）----
recorded_decision="$(jq -r '.decision' "$REG/replies/w3n-backend/7.json")"
if [ "$recorded_decision" = "照 A 案" ]; then
  pass "instruct：回覆檔內容是這次送出的文字"
else
  bad "instruct：回覆檔內容是 '$recorded_decision'"
fi

rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text x --reply-to 999 >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 5 ]; then
  pass "instruct：--reply-to 指名不存在的 inbox 記錄以 5 結束"
else
  bad "instruct：得到 rc=$rc"
fi

# ---- 本任務自行補上：agent_blocked 以外的其他 herdr 拒絕，也要放掉持
#      有旗標，但不得進待補送清單（見 instruct.sh 檔頭「blocked 是待補
#      送」一節：只有 agent_blocked 才是待補送，其餘拒絕是真正的失敗，
#      進待補送清單只會讓看門狗永遠補投一個根本送不到的目標）----
cat > "$STUB_BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '{"error":{"code":"agent_not_found","message":"no such agent"}}' >&2
exit 1
STUB
chmod +x "$STUB_BIN/herdr"
hat_assert_herdr_stubbed "$STUB_BIN" instruct-other-rejection

prev_pending="$(jq -r '.pending_resend | length' "$REG/workers/w3n-backend.json")"
rc=0; bash "$SCRIPTS/instruct.sh" --to w3n-backend --text x >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 6 ]; then
  pass "instruct：agent_blocked 以外的 herdr 拒絕以 6 結束"
else
  bad "instruct：得到 rc=$rc"
fi
if [ "$(jq -r '.held' "$REG/workers/w3n-backend.json")" = "false" ]; then
  pass "instruct：非 blocked 拒絕時也放掉持有旗標"
else
  bad "instruct：持有旗標卡在 true"
fi
new_pending="$(jq -r '.pending_resend | length' "$REG/workers/w3n-backend.json")"
if [ "$new_pending" = "$prev_pending" ]; then
  pass "instruct：非 blocked 拒絕不進待補送清單（那個目標可能根本不存在，補投永遠不會成功）"
else
  bad "instruct：待補送清單被非 blocked 的拒絕污染了（$prev_pending → $new_pending）"
fi

# ===== 斷言數下限：走到結尾但少跑了，也要看得出來 =====
# EXIT trap 抓的是「沒走到結尾」，這一條抓的是另一半：走到了結尾，但
# 某個段落被跳過、斷言數比預期少。新增斷言時要把這個數字一起改大——
# 這是刻意的成本：一個會隨新增斷言自動放寬的下限抓不到任何東西。數字
# 不含本條斷言自己。
HAT_EXPECTED_ASSERTIONS=163
if [ "$assert_count" -ge "$HAT_EXPECTED_ASSERTIONS" ]; then
  pass "斷言數達到下限（跑了 $assert_count 條，下限 $HAT_EXPECTED_ASSERTIONS）"
else
  bad "斷言數只有 $assert_count 條，低於下限 $HAT_EXPECTED_ASSERTIONS：有段落被整段跳過，不要把「0 FAIL」讀成全綠"
fi

# 走到這一行才算跑完整份套件，見檔頭 _hat_suite_on_exit 的說明。
HAT_SUITE_REACHED_END=1
exit "$fail"
