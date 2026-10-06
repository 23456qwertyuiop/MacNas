#!/usr/bin/env bash
#
# MacNas 磁盘格式稳定性自测
#
#   ./Tools/e2e/stability.sh
#
# 验证“后续更新也不改变系统结构”的几条硬保证：
#   1. 目录结构冻结：卷根目录永远只有 document 与 info
#   2. 未知字段原样保留（老版本不会抹掉新版本写入的信息）
#   3. 新版本格式 → 只读打开，一个字节都不改写
#   4. index.json 损坏 → 自动回退到 index.json.bak
#   5. index.json 彻底丢失 → 按内容哈希从 document/blobs 重建并正常下载
#   6. 卷身份 id 跨重启稳定，formatVersion 正确写出
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${MACNAS_TEST_PORT:-$(( 20000 + RANDOM % 2000 ))}"
WORK="$(mktemp -d /tmp/macnas-stab.XXXXXX)"
BIN="$WORK/macnas-e2e"
VA="$WORK/vol-a"
SUPPORT="$WORK/support"
COOKIE="$WORK/cookie.txt"
BASE="http://127.0.0.1:$PORT"
USER_NAME="admin"
PASSWORD="test1234"
INDEX="$VA/info/index.json"
BACKUP="$VA/info/index.json.bak"
MARKER="$VA/info/volume.json"

PASS=0
FAIL=0
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

say()   { printf '\n\033[1;34m== %s\033[0m\n' "$1"; }
ok()    { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $2，实际 $3）"; fi; }

api() { curl -s --max-time 60 -b "$COOKIE" "$@"; }
body_login() { printf '{"username":"%s","password":"%s"}' "$USER_NAME" "$PASSWORD"; }
body_mkdir() { printf '{"volume":"%s","path":"%s","name":"%s"}' "$1" "$2" "$3"; }
sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }
jget() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2]))" "$1" "$2"; }

mkdir -p "$VA" "$SUPPORT"

say "编译无界面测试服务器"
if ! swiftc -module-cache-path "$WORK/modulecache" \
      "$ROOT"/MacNas/Core/*.swift "$ROOT"/MacNas/Server/*.swift "$ROOT"/Tools/e2e/main.swift \
      -o "$BIN" 2> "$WORK/build.log"; then
  echo "编译失败："; cat "$WORK/build.log"; exit 1
fi
ok "编译完成"

start_server() {
  MACNAS_CONFIG_DIR="$SUPPORT" MACNAS_WEB_DIR="$ROOT/MacNas/Web" \
    "$BIN" "$VA" "$PORT" "$USER_NAME" "$PASSWORD" >> "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  disown "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 80); do
    curl -s --max-time 5 -o /dev/null "$BASE/api/session" && return 0
    sleep 0.25
  done
  echo "服务器未启动："; tail -20 "$WORK/server.log"; exit 1
}

stop_server() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  for _ in $(seq 1 40); do
    curl -s --max-time 2 -o /dev/null "$BASE/api/session" || break
    sleep 0.25
  done
  SERVER_PID=""
}

login() {
  curl -s --max-time 15 -c "$COOKIE" -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d "$(body_login)" "$BASE/api/login"
}

# ---------- 准备：一个卷 + 一个文件 ----------
start_server
login
V=$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["id"])')
printf 'stability payload v1\n' > "$WORK/orig.txt"
api -o /dev/null -X POST --data-binary @"$WORK/orig.txt" "$BASE/api/upload?volume=$V&path=/&name=keep.txt"
ORIG_HASH=$(sha_of "$WORK/orig.txt")
# 新目录用格式 v2（追加日志）：先整理一次，把记录压回 index.json。
# 下面这些检查针对的是「快照文件」上的契约 —— 那正是其它版本会读到的那份。
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s"}' "$V")" "$BASE/api/volume/compact"
stop_server

say "1. 目录结构冻结"
TOP_LEVEL=$(find "$VA" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')
check "卷根目录只有 document 与 info" "document info " "$TOP_LEVEL"
check "document 下只有 blobs" "blobs" "$(find "$VA/document" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')"
# v2 起 info 里会多一个 index.log（追加日志），这是契约里允许的「新增文件」
INFO_FILES=$(find "$VA/info" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')
ALLOWED_INFO=$(printf '%s\n' "$INFO_FILES" | tr ' ' '\n' | grep -vE '^(index\.json|index\.json\.bak|index\.log|volume\.json)$' | tr '\n' ' ')
check "info 下只有约定的记录文件（含 v2 的 index.log）" "" "$ALLOWED_INFO"
check "index.json 声明格式版本（v1 或 v2）" "1" \
  "$(jget "$INDEX" '1 if d["formatVersion"] in (1, 2) else 0')"
check "volume.json 声明格式版本（v1 或 v2）" "1" \
  "$(jget "$MARKER" '1 if d["formatVersion"] in (1, 2) else 0')"
check "记录里带内容哈希" "$ORIG_HASH" "$(jget "$INDEX" 'd["entries"][0]["sha256"]')"
VID_BEFORE=$(jget "$MARKER" 'd["id"]')

say "2. 未知字段原样保留（模拟“新版本写入、老版本继续运行”）"
python3 - "$INDEX" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
data['futureTopLevel'] = {'enabled': True, 'note': 'written by a newer MacNas'}
data['futureArray'] = [1, 2, 3]
data['entries'][0]['futureEntryField'] = 'keep-me'
data['entries'][0]['futureNested'] = {'x': 1}
json.dump(data, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
start_server
login
check "含未知字段的索引仍能正常装载" "200" "$(api -o /dev/null -w '%{http_code}' "$BASE/api/list?volume=$V&path=/")"
check "写入一次（新建文件夹）后仍然可用" "200" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(body_mkdir "$V" / after-upgrade)" "$BASE/api/mkdir")"
stop_server
check "顶层未知字段被保留" "True" "$(jget "$INDEX" 'd["futureTopLevel"]["enabled"]')"
check "顶层未知数组被保留" "[1, 2, 3]" "$(jget "$INDEX" 'd["futureArray"]')"
check "记录级未知字段被保留" "keep-me" "$(jget "$INDEX" 'd["entries"][0]["futureEntryField"]')"
check "记录级嵌套未知字段被保留" "1" "$(jget "$INDEX" 'd["entries"][0]["futureNested"]["x"]')"
check "已知字段没有被破坏" "$V" "$(jget "$INDEX" 'd["volumeId"]')"

say "3. 新版本格式 → 只读打开，绝不改写"
python3 - "$INDEX" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
data['formatVersion'] = 99
data['futureOnlyField'] = 'must-survive'
json.dump(data, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
INDEX_SUM=$(sha_of "$INDEX")
MARKER_SUM=$(sha_of "$MARKER")
start_server
login
check "只读卷仍可列出文件" "200" "$(api -o /dev/null -w '%{http_code}' "$BASE/api/list?volume=$V&path=/")"
check "只读卷仍可下载" "200" "$(api -o /dev/null -w '%{http_code}' "$BASE/api/download?volume=$V&id=$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print([f for f in json.load(sys.stdin)["files"] if f["name"]=="keep.txt"][0]["id"])')")"
# 所有写接口都必须被拒绝（且不能“假装成功”）
check "只读卷拒绝上传（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/orig.txt" "$BASE/api/upload?volume=$V&path=/&name=nope.txt")"
check "只读卷拒绝新建文件夹（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(body_mkdir "$V" / nope)" "$BASE/api/mkdir")"
KEEP_ID=$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print([f for f in json.load(sys.stdin)["files"] if f["name"]=="keep.txt"][0]["id"])')
check "只读卷拒绝重命名（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","id":"%s","name":"zz.txt"}' "$V" "$KEEP_ID")" "$BASE/api/rename")"
check "只读卷拒绝重命名文件夹（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","path":"/","name":"zz"}' "$V")" "$BASE/api/rename-folder")"
check "只读卷拒绝删除（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","id":"%s"}' "$V" "$KEEP_ID")" "$BASE/api/delete")"
check "只读卷拒绝拖拽搬运（409）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"fromVolume":"%s","ids":["%s"],"paths":[],"toVolume":"%s","toPath":"/","mode":"move"}' "$V" "$KEEP_ID" "$V")" "$BASE/api/transfer")"
check "只读卷拒绝批量删除（409，不能假装成功）" "409" "$(api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","ids":["%s"]}' "$V" "$KEEP_ID")" "$BASE/api/delete-batch")"
check "只读卷的记录一条都没少" "1" \
  "$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["files"]))')"
check "volumes 接口标注 readOnly" "True" \
  "$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["readOnly"])')"
stop_server
check "index.json 一个字节都没改" "$INDEX_SUM" "$(sha_of "$INDEX")"
check "volume.json 一个字节都没改" "$MARKER_SUM" "$(sha_of "$MARKER")"
check "新版本的未知字段仍在" "must-survive" "$(jget "$INDEX" 'd["futureOnlyField"]')"

say "4. index.json 损坏 → 回退到 index.json.bak"
python3 - "$INDEX" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
data['formatVersion'] = 1
json.dump(data, open(path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PY
start_server
login
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_mkdir "$V" / b1)" "$BASE/api/mkdir"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_mkdir "$V" / b2)" "$BASE/api/mkdir"
stop_server
if [ -f "$BACKUP" ]; then ok "写入过程中生成了 index.json.bak"; else bad "没有生成 index.json.bak"; fi
printf 'this is not json at all\n' > "$INDEX"
start_server
login
check "损坏后依然能列出原文件" "1" \
  "$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="keep.txt"]))')"
stop_server
check "index.json 已被修复成合法 JSON" "1" "$(jget "$INDEX" '1 if d["formatVersion"] in (1, 2) else 0')"

say "5. index.json 彻底丢失 → 按哈希从 document/blobs 重建"
rm -f "$INDEX" "$BACKUP"
start_server
login
LISTING=$(api "$BASE/api/list?volume=$V&path=/")
check "重建出的记录数为 1" "1" "$(echo "$LISTING" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["files"]))')"
check "卷被标记为已重建" "True" \
  "$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["rebuilt"])')"
NAME=$(echo "$LISTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["files"][0]["name"])')
ID=$(echo "$LISTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["files"][0]["id"])')
case "$NAME" in recovered-*) ok "恢复出的文件按 recovered-<哈希前8位> 命名（$NAME）";; *) bad "恢复命名不符合约定：$NAME";; esac
api -o "$WORK/recovered.bin" "$BASE/api/download?volume=$V&id=$ID"
check "恢复出的内容哈希与原文件一致" "$ORIG_HASH" "$(sha_of "$WORK/recovered.bin")"
stop_server
check "重建后的索引已落盘" "1" "$(jget "$INDEX" '1 if d["formatVersion"] in (1, 2) else 0')"
check "重建后卷身份 id 未变" "$VID_BEFORE" "$(jget "$MARKER" 'd["id"]')"

say "6. 重新打开目录：id 与记录稳定"
start_server
login
check "再次打开后 id 仍为同一个" "$VID_BEFORE" \
  "$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["id"])')"
check "再次打开后记录仍在" "1" \
  "$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["files"]))')"
check "格式版本仍然是可读的（1 或 2）" "1" "$(jget "$INDEX" '1 if d["formatVersion"] in (1, 2) else 0')"
stop_server

printf '\n\033[1m通过 %d 项，失败 %d 项\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
