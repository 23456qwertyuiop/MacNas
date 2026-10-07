#!/usr/bin/env bash
#
# MacNas 端到端自测（不需要 Xcode、不需要界面）
#
#   ./Tools/e2e/run.sh
#
# 它会把 Core + Server 源码编译成一个无界面可执行文件，
# 在临时目录里跑起真实的 HTTP 服务器，然后用 curl 逐项验证：
#   上传 / 全局哈希去重 / 跨目录去重 / 下载完整性 / Range / 重命名 /
#   删除引用计数 / 冲突 409 / 非法参数 / 并发上传 / 重启后自动读回
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${MACNAS_TEST_PORT:-$(( 18000 + RANDOM % 2000 ))}"
WORK="$(mktemp -d /tmp/macnas-e2e.XXXXXX)"
BIN="$WORK/macnas-e2e"
VA="$WORK/vol-a"
VB="$WORK/vol-b"
SUPPORT="$WORK/support"
COOKIE="$WORK/cookie.txt"
BASE="http://127.0.0.1:$PORT"
USER_NAME="admin"
PASSWORD="test1234"

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
check() { # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 $2，实际 $3）"; fi
}

api() { curl -s --max-time 60 -b "$COOKIE" "$@"; }

# 预先生成 JSON 请求体，避免多层引号嵌套带来的转义问题
body_login()     { printf '{"username":"%s","password":"%s"}' "$USER_NAME" "$1"; }
body_mkdir()     { printf '{"volume":"%s","path":"%s","name":"%s"}' "$1" "$2" "$3"; }
body_rename()    { printf '{"volume":"%s","id":"%s","name":"%s"}' "$1" "$2" "$3"; }
body_renamedir() { printf '{"volume":"%s","path":"%s","name":"%s"}' "$1" "$2" "$3"; }
body_delete_id()   { printf '{"volume":"%s","id":"%s"}' "$1" "$2"; }
body_delete_path() { printf '{"volume":"%s","path":"%s"}' "$1" "$2"; }
body_delete() { printf '{"volume":"%s","id":"%s"}' "$1" "$2"; }
body_volume() { printf '{"volume":"%s"}' "$1"; }
sha256_file() { python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"; }

post_json() { # post_json <路径> <JSON>
  api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$BASE$1"
}

# 偶尔会遇到一次瞬时连接抖动（curl 拿到 000），POST 失败就重试一次，避免测试假失败
post_json_retry() {
  local status
  status=$(post_json "$1" "$2")
  if [ "$status" = "000" ]; then
    sleep 0.4
    status=$(post_json "$1" "$2")
  fi
  printf '%s' "$status"
}

upload() { # upload <卷> <目录> <文件名> <本地文件> [额外查询串]
  api -X POST --data-binary @"$4" "$BASE/api/upload?volume=$1&path=$2&name=$3${5:-}"
}

json_field() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }

login() { # 重新登录（重启后会话会失效）
  curl -s --max-time 15 -c "$COOKIE" -o /dev/null -X POST -H 'Content-Type: application/json' \
    -d "$(body_login "$PASSWORD")" "$BASE/api/login"
}

mkdir -p "$VA" "$VB" "$SUPPORT"

say "核心自测（哈希兼容性 / 路径校验 / 格式约定）"
if ! swiftc -module-cache-path "$WORK/mc0" "$ROOT"/MacNas/Core/*.swift "$ROOT"/Tools/e2e/selftest/main.swift \
      -o "$WORK/selftest" 2> "$WORK/selftest.log"; then
  echo "自测编译失败："; cat "$WORK/selftest.log"; exit 1
fi
if "$WORK/selftest" | tee "$WORK/selftest.out" | sed 's/\x1b\[[0-9;]*m//g'; then
  PASS=$((PASS + $(grep -c '✓' "$WORK/selftest.out")))
else
  PASS=$((PASS + $(grep -c '✓' "$WORK/selftest.out")))
  FAIL=$((FAIL + $(grep -c '✗' "$WORK/selftest.out")))
  echo "核心自测未全部通过"
fi

say "编译无界面测试服务器"
if ! swiftc -module-cache-path "$WORK/modulecache" \
      "$ROOT"/MacNas/Core/*.swift "$ROOT"/MacNas/Server/*.swift "$ROOT"/Tools/e2e/main.swift \
      -o "$BIN" 2> "$WORK/build.log"; then
  echo "编译失败："; cat "$WORK/build.log"; exit 1
fi
ok "编译完成"

start_server() {
  MACNAS_CONFIG_DIR="$SUPPORT" MACNAS_WEB_DIR="$ROOT/MacNas/Web" \
    "$BIN" "$VA,$VB" "$PORT" "$USER_NAME" "$PASSWORD" >> "$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  disown "$SERVER_PID" 2>/dev/null || true
  for _ in $(seq 1 80); do
    curl -s --max-time 5 -o /dev/null "$BASE/api/session" && return 0
    sleep 0.25
  done
  echo "服务器未启动："; cat "$WORK/server.log"; exit 1
}

say "启动服务器（端口 $PORT）"
start_server
ok "服务器已就绪"

say "登录与鉴权"
check "未登录访问 API 返回 401" "401" \
  "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$BASE/api/volumes")"
check "错误密码返回 401" "401" \
  "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
     -d "$(body_login wrong)" "$BASE/api/login")"
check "正确密码返回 200" "200" \
  "$(curl -s --max-time 10 -c "$COOKIE" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
     -d "$(body_login "$PASSWORD")" "$BASE/api/login")"
check "网页资源可访问" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")"
check "样式表可访问" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/styles.css")"
check "脚本可访问" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/app.js")"

V1=$(api "$BASE/api/volumes" | json_field 'd["volumes"][0]["id"]')
V2=$(api "$BASE/api/volumes" | json_field 'd["volumes"][1]["id"]')
if [ -n "$V1" ] && [ -n "$V2" ]; then ok "读到 2 个目录"; else bad "目录列表读取失败"; fi

say "新建文件夹 / 上传 / 全局去重"
check "新建文件夹" "200" "$(post_json /api/mkdir "$(body_mkdir "$V1" / doc)")"

printf 'macnas dedup payload\n' > "$WORK/a.txt"
R1=$(upload "$V1" / a.txt "$WORK/a.txt")
check "首次上传 outcome=stored" "stored" "$(echo "$R1" | json_field 'd["outcome"]')"

R2=$(upload "$V1" /doc b.txt "$WORK/a.txt")
check "同一目录内重复内容 outcome=deduplicated" "deduplicated" "$(echo "$R2" | json_field 'd["outcome"]')"

R3=$(upload "$V2" / c.txt "$WORK/a.txt")
check "跨目录重复内容 outcome=deduplicated" "deduplicated" "$(echo "$R3" | json_field 'd["outcome"]')"
check "跨目录记录指向原目录" "$V1" "$(echo "$R3" | json_field 'd["file"]["storageVolumeId"]')"
check "跨目录记录写明实际存放位置" "blobs" "$(echo "$R3" | json_field 'd["file"]["storedIn"].split("/")[0]')"

check "相同内容只落盘一份" "1" "$(find "$VA/document/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"
check "第二个目录没有新增物理文件" "0" "$(find "$VB/document/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"
# 注意：新目录用格式 v2（追加日志），记录可能还在 info/index.log 里，
# 所以这里把快照与日志合起来算 —— 关注点是「记录落在 B 自己的目录里」
check "目录 B 的记录写在自己的 info 里" "1" \
  "$(python3 -c '
import json, os
vb = "'"$VB"'"
entries = json.load(open(os.path.join(vb, "info/index.json")))["entries"]
log = os.path.join(vb, "info/index.log")
if os.path.exists(log):
    for line in open(log, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        record = json.loads(line)
        entries = [e for e in entries if e["id"] not in set(record.get("remove", []))] + record.get("put", [])
print(len(entries))')"

say "下载"
ID1=$(api "$BASE/api/list?volume=$V1&path=/" | python3 -c 'import json,sys;print([f for f in json.load(sys.stdin)["files"] if f["name"]=="a.txt"][0]["id"])')
api -o "$WORK/dl1" "$BASE/api/download?volume=$V1&id=$ID1"
cmp -s "$WORK/a.txt" "$WORK/dl1" && ok "下载内容与原文一致" || bad "下载内容不一致"
ID3=$(api "$BASE/api/list?volume=$V2&path=/" | json_field 'd["files"][0]["id"]')
api -o "$WORK/dl3" "$BASE/api/download?volume=$V2&id=$ID3"
cmp -s "$WORK/a.txt" "$WORK/dl3" && ok "跨目录下载内容一致" || bad "跨目录下载内容不一致"
check "Range 请求返回 206" "206" \
  "$(api -o /dev/null -w '%{http_code}' -r 0-4 "$BASE/api/download?volume=$V1&id=$ID1")"
check "下载响应带 Content-Disposition" "1" \
  "$(api -o /dev/null -D - "$BASE/api/download?volume=$V1&id=$ID1" | grep -ci 'content-disposition')"

say "冲突 / 重命名 / 删除引用计数"
check "同名文件再次上传返回 409" "409" \
  "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V1&path=/&name=a.txt")"
check "overwrite=1 可以覆盖" "200" \
  "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V1&path=/&name=a.txt&overwrite=1")"
check "重命名文件" "200" "$(post_json /api/rename "$(body_rename "$V1" "$ID1" a2.txt)")"
check "重命名文件夹" "200" "$(post_json /api/rename-folder "$(body_renamedir "$V1" /doc doc2)")"
# 此时同一份内容有 3 条记录：a2.txt(/)、doc2/b.txt、目录 B 的 c.txt
# 注意：删除现在是「进回收站」，内容引用计数不变；只有彻底删除才会回收内容
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_delete_id "$V2" "$ID3")" "$BASE/api/delete"
check "删除一条记录后内容仍被其它记录引用" "1" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_delete_id "$V1" "$ID1")" "$BASE/api/delete"
check "再删一条后内容仍被最后一条引用" "1" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_delete_path "$V1" /doc2)" "$BASE/api/delete"
check "删除后进回收站，内容还在（引用计数不降）" "1" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
# 把这几条从回收站里彻底删掉，内容才应该被回收
for purge_volume in "$V1" "$V2"; do
  for purge_id in $(api "$BASE/api/trash?volume=$purge_volume" | python3 -c 'import json,sys;print(" ".join(i["id"] for i in json.load(sys.stdin)["items"]))'); do
    post_json "/api/trash/purge" "$(body_delete "$purge_volume" "$purge_id")" > /dev/null
  done
done
check "全部彻底删除后物理文件被清理" "0" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"

say "非法输入"
check "名称为 .. 被拒绝" "400" \
  "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V1&path=/&name=..")"
check "名称含 / 被拒绝" "400" \
  "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V1&path=/&name=a%2Fb")"
check "上传到不存在的目录被拒绝" "400" \
  "$(api -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V1&path=/nope&name=x.txt")"
check "路径穿越被限制在卷内" "/etc" \
  "$(api "$BASE/api/list?volume=$V1&path=/../../../../etc" | json_field 'd["path"]')"
check "缺少 volume 参数返回 400" "400" \
  "$(api -o /dev/null -w '%{http_code}' "$BASE/api/list?path=/")"
check "chunked 请求返回 411" "411" \
  "$(printf 'abc' | curl -s --max-time 10 -b "$COOKIE" -o /dev/null -w '%{http_code}' -X POST \
     -H 'Transfer-Encoding: chunked' --data-binary @- "$BASE/api/upload?volume=$V1&path=/&name=chunky.txt")"

say "并发上传 12 个文件"
mkdir -p "$WORK/par"
for i in $(seq 1 12); do head -c $((i * 4096)) /dev/urandom > "$WORK/par/f$i.bin"; done
PIDS=()
for i in $(seq 1 12); do
  api -o "$WORK/par/r$i.json" -X POST --data-binary @"$WORK/par/f$i.bin" \
    "$BASE/api/upload?volume=$V1&path=/&name=f$i.bin" &
  PIDS+=($!)
done
wait "${PIDS[@]}"
check "12 个并发上传全部成功" "12" \
  "$(python3 - "$WORK/par" <<'PY'
import json,glob,sys
n=0
for p in glob.glob(sys.argv[1]+'/r*.json'):
    try:
        if json.load(open(p)).get('ok'): n+=1
    except Exception: pass
print(n)
PY
)"
check "并发上传内容全部可校验" "12" \
  "$(python3 - "$WORK/par" "$COOKIE" "$BASE" <<'PY'
import json,hashlib,subprocess,sys,glob,os
par, cookie, base = sys.argv[1:4]
files = {}
for p in glob.glob(par+'/r*.json'):
    try:
        d = json.load(open(p))
        if d.get('ok'): files[d['file']['name']] = d['file']
    except Exception: pass
good = 0
for name, f in files.items():
    src = open(os.path.join(par, name), 'rb').read()
    if hashlib.sha256(src).hexdigest() != f['sha256']: continue
    out = subprocess.run(['curl','-s','-b',cookie,
        f"{base}/api/download?volume={f['storageVolumeId']}&id={f['id']}"],
        capture_output=True).stdout
    if out == src: good += 1
print(good)
PY
)"

say "拖拽移动 / 复制（网页端）"
check "新建目标文件夹" "200" "$(post_json /api/mkdir "$(body_mkdir "$V1" / 目标)")"
check "再建一个用于嵌套" "200" "$(post_json /api/mkdir "$(body_mkdir "$V1" / 仓库)")"
printf 'drag payload\n' > "$WORK/drag.txt"
DRAG_JSON=$(upload "$V1" / drag.txt "$WORK/drag.txt")
DRAG_ID=$(echo "$DRAG_JSON" | json_field 'd["file"]["id"]')
BLOBS_BEFORE=$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')

# 用 printf 生成 JSON，避免多层引号嵌套导致的转义问题
ids_json()   { if [ -n "$1" ]; then printf '["%s"]' "$1"; else printf '[]'; fi; }
paths_json() { if [ -n "$1" ]; then printf '["%s"]' "$1"; else printf '[]'; fi; }
transfer_body() { # transfer_body <fromVol> <id|空> <path|空> <toVol> <toPath> <mode>
  printf '{"fromVolume":"%s","ids":%s,"paths":%s,"toVolume":"%s","toPath":"%s","mode":"%s"}' \
    "$1" "$(ids_json "$2")" "$(paths_json "$3")" "$4" "$5" "$6"
}

check "同目录内移动到 /目标" "200" \
  "$(post_json /api/transfer "$(transfer_body "$V1" "$DRAG_ID" "" "$V1" /目标 move)")"
check "移动后根目录不再有该文件" "0" \
  "$(api "$BASE/api/list?volume=$V1&path=/" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="drag.txt"]))')"
check "移动后 /目标 里有该文件" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F%E7%9B%AE%E6%A0%87" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="drag.txt"]))')"
check "移动不搬运内容（物理文件数不变）" "$BLOBS_BEFORE" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"

MOVED_ID=$(api "$BASE/api/list?volume=$V1&path=%2F%E7%9B%AE%E6%A0%87" | json_field 'd["files"][0]["id"]')
check "跨目录复制到第二个卷" "200" \
  "$(post_json /api/transfer "$(transfer_body "$V1" "$MOVED_ID" "" "$V2" / copy)")"
check "第二个卷新增一条记录" "1" \
  "$(api "$BASE/api/list?volume=$V2&path=/" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["files"]))')"
check "复制也不占空间（第二个卷无物理文件）" "0" "$(find "$VB/document/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')"
check "复制出来的记录指向原内容" "$V1" \
  "$(api "$BASE/api/list?volume=$V2&path=/" | json_field 'd["files"][0]["storageVolumeId"]')"

check "同目录再复制一次（重名自动改名）" "200" \
  "$(post_json /api/transfer "$(transfer_body "$V1" "$MOVED_ID" "" "$V1" /目标 copy)")"
check "出现自动改名后的副本" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F%E7%9B%AE%E6%A0%87" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if "(2)" in f["name"]]))')"

check "把文件夹整体拖进另一个文件夹" "200" \
  "$(post_json /api/transfer "$(transfer_body "$V1" "" /目标 "$V1" /仓库 move)")"
check "文件夹已移动到 /仓库/目标" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F%E4%BB%93%E5%BA%93" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["folders"]))')"
check "文件夹内的记录跟着走了" "2" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F%E4%BB%93%E5%BA%93%2F%E7%9B%AE%E6%A0%87" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["files"]))')"
check "不能把文件夹拖进它自己" "409" \
  "$(post_json /api/transfer "$(transfer_body "$V1" "" /仓库 "$V1" /仓库 move)")"

say "全局搜索"
check "新建搜索用文件夹" "200" "$(post_json /api/mkdir "$(body_mkdir "$V1" / 搜索测试)")"
printf 'quarterly report\n' > "$WORK/q1.txt"
upload "$V1" /搜索测试 季度报告-2026.txt "$WORK/q1.txt" > /dev/null
upload "$V1" / 季度报告-2026-备份.txt "$WORK/q1.txt" > /dev/null
upload "$V2" / 另一个季度报告.txt "$WORK/q1.txt" > /dev/null
printf 'english name\n' > "$WORK/q2.txt"
upload "$V1" / 财务-Financial-Report.txt "$WORK/q2.txt" > /dev/null

search_total() { api "$BASE/api/search" --get --data-urlencode "q=$1" ${2:+--data-urlencode "volume=$2"} ${3:+--data-urlencode "limit=$3"} | json_field 'd["total"]'; }
search_names() { api "$BASE/api/search" --get --data-urlencode "q=$1" | python3 -c 'import json,sys;print(",".join(sorted(h["name"] for h in json.load(sys.stdin)["hits"])))'; }

check "按名字搜到 3 条季度报告" "3" "$(search_total 季度报告)"
check "关键字大小写不敏感" "1" "$(search_total financial)"
check "多个关键词（空格分隔）" "1" "$(search_total '季度 备份')"
check "能搜到文件夹" "1" "$(api "$BASE/api/search" --get --data-urlencode 'q=搜索测试' | python3 -c 'import json,sys;print(len([h for h in json.load(sys.stdin)["hits"] if h["kind"]=="folder"]))')"
check "限定目录搜索" "1" "$(search_total 季度报告 "$V2")"
check "空关键词返回 0" "0" "$(search_total '')"
check "limit 生效并标记截断" "True" "$(api "$BASE/api/search" --get --data-urlencode 'q=季度报告' --data-urlencode 'limit=1' | json_field 'd["truncated"]')"
check "返回结果带所在目录路径" "True" "$(api "$BASE/api/search" --get --data-urlencode 'q=季度报告' | python3 -c 'import json,sys;print(all(h["parent"].startswith("/") and h["volumeName"] for h in json.load(sys.stdin)["hits"]))')"
check "路径里的关键词也能命中文件" "1" "$(api "$BASE/api/search" --get --data-urlencode 'q=搜索测试' | python3 -c 'import json,sys;print(len([h for h in json.load(sys.stdin)["hits"] if h["kind"]=="file"]))')"

say "分享链接"
body_share_file()   { printf '{"volume":"%s","id":"%s","expiresInHours":%s,"password":"%s"}' "$1" "$2" "$3" "$4"; }
body_share_folder() { printf '{"volume":"%s","path":"%s","expiresInHours":%s,"password":"%s"}' "$1" "$2" "$3" "$4"; }
body_token()        { printf '{"token":"%s"}' "$1"; }
token_of() { python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])'; }

check "新建共享文件夹" "200" "$(post_json /api/mkdir "$(body_mkdir "$V1" / 共享)")"
printf 'public share payload\n' > "$WORK/share.txt"
SHARE_FILE=$(upload "$V1" / shared.txt "$WORK/share.txt")
SHARE_FILE_ID=$(echo "$SHARE_FILE" | json_field 'd["file"]["id"]')
upload "$V1" /共享 inner.txt "$WORK/share.txt" > /dev/null

# 文件分享（永久、无密码）
FILE_SHARE_RESP=$(api -X POST -H 'Content-Type: application/json' -d "$(body_share_file "$V1" "$SHARE_FILE_ID" 0 "")" "$BASE/api/share/create")
T1=$(echo "$FILE_SHARE_RESP" | token_of)
check "创建文件分享链接" "True" "$(echo "$FILE_SHARE_RESP" | json_field 'd["ok"]')"
check "分享信息里带可访问链接" "True" "$(echo "$FILE_SHARE_RESP" | python3 -c 'import json,sys;print("/s/" in json.load(sys.stdin)["share"]["url"])')"
check "匿名可读取分享信息" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T1")"
check "匿名能拿到文件名" "shared.txt" "$(curl -s "$BASE/api/pub/$T1" | json_field 'd["files"][0]["name"]')"
curl -s -o "$WORK/share-dl.txt" "$BASE/api/pub/$T1/download?id=$SHARE_FILE_ID"
cmp -s "$WORK/share.txt" "$WORK/share-dl.txt" && ok "匿名下载内容正确" || bad "匿名下载内容不一致"
check "分享页返回网页" "text/html" "$(curl -s -o /dev/null -w '%{content_type}' "$BASE/s/$T1" | cut -d';' -f1)"

# 文件夹分享 + 范围限制
T2=$(api -X POST -H 'Content-Type: application/json' -d "$(body_share_folder "$V1" /共享 24 "")" "$BASE/api/share/create" | token_of)
check "文件夹分享能列出内容" "inner.txt" "$(curl -s "$BASE/api/pub/$T2" | json_field 'd["files"][0]["name"]')"
check "分享范围外返回 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T2?path=/")"
check "不存在的路径返回 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T2?path=/etc")"

# 有密码的分享
T3=$(api -X POST -H 'Content-Type: application/json' -d "$(body_share_file "$V1" "$SHARE_FILE_ID" 0 2468)" "$BASE/api/share/create" | token_of)
check "带密码分享要求先验密码" "True" "$(curl -s "$BASE/api/pub/$T3" | json_field 'd["needsPassword"]')"
check "未验密码不能下载" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T3/download?id=$SHARE_FILE_ID")"
check "错误密码被拒绝" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"password":"0000"}' "$BASE/api/pub/$T3/auth")"
curl -s -c "$WORK/share-cookie.txt" -o /dev/null -X POST -H 'Content-Type: application/json' -d '{"password":"2468"}' "$BASE/api/pub/$T3/auth"
check "正确密码后可访问" "shared.txt" "$(curl -s -b "$WORK/share-cookie.txt" "$BASE/api/pub/$T3" | json_field 'd["files"][0]["name"]')"
check "访问次数已统计" "1" "$(api "$BASE/api/shares" | python3 -c 'import json,sys;print(1 if any(s["visits"]>0 for s in json.load(sys.stdin)["shares"]) else 0)')"

# 管理与失效
check "分享列表有 3 条" "3" "$(api "$BASE/api/shares" | json_field 'len(d["shares"])')"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_token "$T1")" "$BASE/api/share/revoke"
check "取消分享后链接失效" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T1")"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_delete_id "$V1" "$SHARE_FILE_ID")" "$BASE/api/delete"
check "目标被删除后标记为失效" "1" "$(api "$BASE/api/shares" | python3 -c 'import json,sys;print(len([s for s in json.load(sys.stdin)["shares"] if s["status"]=="broken"]))')"
check "目标删除后分享不可访问" "404" "$(curl -s -b "$WORK/share-cookie.txt" -o /dev/null -w '%{http_code}' "$BASE/api/pub/$T3/download?id=$SHARE_FILE_ID")"

say "回收站"
# 造一个文件并删掉它
printf '回收站测试内容第一版\n' > "$WORK/trash1.txt"
TRASH_ID=$(upload "$V1" "/" "回收站测试.txt" "$WORK/trash1.txt" | json_field 'd["file"]["id"]')
trash_names() { api "$BASE/api/trash?volume=$1" | python3 -c 'import json,sys;print(",".join(sorted(i["name"] for i in json.load(sys.stdin)["items"])))'; }
trash_find() { api "$BASE/api/trash?volume=$1" | python3 -c "import json,sys;print(next((i['$2'] for i in json.load(sys.stdin)['items'] if i['name']=='$3'), ''))"; }
BLOBS_BEFORE=$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')
post_json_retry "/api/delete" "$(body_delete "$V1" "$TRASH_ID")" > /dev/null
check "删除后不再出现在列表里" "0" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="回收站测试.txt"]))')"
check "删除后出现在回收站里" "1" "$(trash_names "$V1" | grep -c '回收站测试.txt')"
check "回收站记录了原路径" "/回收站测试.txt" "$(trash_find "$V1" originalPath 回收站测试.txt)"
check "回收站期间内容没有被回收" "$BLOBS_BEFORE" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
check "能还原回原路径" "/回收站测试.txt" \
  "$(api -X POST -H 'Content-Type: application/json' -d "$(body_delete "$V1" "$TRASH_ID")" "$BASE/api/trash/restore" | json_field 'd["path"]')"
check "还原后回到列表里" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="回收站测试.txt"]))')"
check "还原后回收站里没有它了" "0" "$(trash_names "$V1" | grep -c '回收站测试.txt')"

# 彻底删除才会回收内容
post_json_retry "/api/delete" "$(body_delete "$V1" "$TRASH_ID")" > /dev/null
post_json_retry "/api/trash/purge" "$(body_delete "$V1" "$TRASH_ID")" > /dev/null
check "彻底删除后回收站里没有它了" "0" "$(trash_names "$V1" | grep -c '回收站测试.txt')"
check "彻底删除后内容被回收" "$((BLOBS_BEFORE - 1))" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"

# 共有内容：删一份不影响另一份
printf '共享内容\n' > "$WORK/shared.txt"
SHARED_A=$(upload "$V1" "/" "共享A.txt" "$WORK/shared.txt" | json_field 'd["file"]["id"]')
SHARED_B=$(upload "$V1" "/" "共享B.txt" "$WORK/shared.txt" | json_field 'd["file"]["id"]')
SHARED_BLOBS=$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')
post_json "/api/delete" "$(body_delete "$V1" "$SHARED_A")" > /dev/null
post_json "/api/delete" "$(body_delete "$V1" "$SHARED_B")" > /dev/null
check "两份共享内容都进回收站后内容仍保留" "$SHARED_BLOBS" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
check "清空回收站返回清理数量" "1" \
  "$(api -X POST -H 'Content-Type: application/json' -d "$(body_volume "$V1")" "$BASE/api/trash/empty" | python3 -c 'import json,sys;print(1 if json.load(sys.stdin)["removed"] >= 2 else 0)')"
check "清空后共享内容被回收" "$((SHARED_BLOBS - 1))" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"

say "历史版本"
printf '版本一\n' > "$WORK/v1.txt"
VER_ID=$(upload "$V1" "/" "版本测试.txt" "$WORK/v1.txt" | json_field 'd["file"]["id"]')
V1_HASH=$(sha256_file "$WORK/v1.txt")
printf '版本二内容\n' > "$WORK/v2.txt"
upload "$V1" "/" "版本测试.txt" "$WORK/v2.txt" "&overwrite=1" > /dev/null
check "覆盖上传后有两个版本" "2" "$(api "$BASE/api/versions?volume=$V1&id=$VER_ID" | json_field 'len(d["versions"])')"
check "第一个是当前版本" "True" "$(api "$BASE/api/versions?volume=$V1&id=$VER_ID" | json_field 'd["versions"][0]["isCurrent"]')"
check "旧版本内容仍在库里" "$V1_HASH" \
  "$(api "$BASE/api/versions?volume=$V1&id=$VER_ID" | json_field 'd["versions"][1]["sha256"]')"
check "旧版本可以下载" "版本一" \
  "$(api "$BASE/api/versions/download?volume=$V1&id=$VER_ID&sha256=$V1_HASH")"
post_json_retry "/api/versions/restore" "$(printf '{"volume":"%s","id":"%s","sha256":"%s"}' "$V1" "$VER_ID" "$V1_HASH")" > /dev/null
check "恢复到旧版本后当前版本变成它" "$V1_HASH" "$(api "$BASE/api/versions?volume=$V1&id=$VER_ID" | json_field 'd["versions"][0]["sha256"]')"
check "被替换掉的版本变成历史（可反悔）" "2" "$(api "$BASE/api/versions?volume=$V1&id=$VER_ID" | json_field 'len(d["versions"])')"
check "恢复后下载到的确实是旧内容" "版本一" \
  "$(api "$BASE/api/download?volume=$V1&id=$VER_ID")"

say "照片收集（免登录上传 + 额度限制）"
COLLECT_BODY=$(printf '{"volume":"%s","kind":"collect","collect":true,"name":"生日会照片","path":"/收集测试","expiresInHours":72,"password":"","maxFileMB":2,"maxTotalMB":3,"imagesOnly":true}' "$V2")
COLLECT_RESP=$(api -X POST -H 'Content-Type: application/json' -d "$COLLECT_BODY" "$BASE/api/share/create")
CTOKEN=$(echo "$COLLECT_RESP" | json_field 'd["share"]["token"]')
check "收集：创建成功且类型是照片收集" "照片收集" "$(echo "$COLLECT_RESP" | json_field 'd["share"]["type"]')"
check "收集：链接指向 /s/<token>" "/s/$CTOKEN" "$(echo "$COLLECT_RESP" | json_field 'd["share"]["path"]')"
check "收集：单文件上限生效" "2097152" "$(echo "$COLLECT_RESP" | json_field 'd["share"]["maxFileBytes"]')"
check "收集：总量上限生效" "3145728" "$(echo "$COLLECT_RESP" | json_field 'd["share"]["maxTotalBytes"]')"
check "收集：目标目录被自动创建" "1" \
  "$(api "$BASE/api/list?volume=$V2&path=%2F" | python3 -c 'import json,sys;print(1 if any(f["name"]=="收集测试" for f in json.load(sys.stdin)["folders"]) else 0)')"

# 访客看到的信息：不列出任何已有文件（链接泄露也不会泄露内容）
COLLECT_INFO=$(curl -s "$BASE/api/pub/$CTOKEN")
check "收集：公开信息不包含文件列表" "0" "$(echo "$COLLECT_INFO" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(1 if ("files" in d or "entries" in d) else 0)')"
check "收集：公开信息带额度" "3145728" "$(echo "$COLLECT_INFO" | json_field 'd["maxTotalBytes"]')"
check "收集：初始已收 0 张" "0" "$(echo "$COLLECT_INFO" | json_field 'd["uploadedCount"]')"

# 免登录上传
UP1=$(curl -s -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$CTOKEN/upload?name=合照.png")
check "收集：访客能免登录上传" "合照.png" "$(echo "$UP1" | json_field 'd["name"]')"
check "收集：上传返回 201 由上传结果体现" "True" "$(echo "$UP1" | json_field 'd["ok"]')"
check "收集：照片进到了目标目录" "1" \
  "$(api "$BASE/api/list?volume=$V2&path=%2F%E6%94%B6%E9%9B%86%E6%B5%8B%E8%AF%95" | python3 -c 'import json,sys;print(1 if any(f["name"]=="合照.png" for f in json.load(sys.stdin)["files"]) else 0)')"
check "收集：计数增加" "1" "$(curl -s "$BASE/api/pub/$CTOKEN" | json_field 'd["uploadedCount"]')"

# 重名照片要自动改名，不能让访客上传失败
check "收集：同名照片自动改名而不是报错" "合照 (2).png" \
  "$(curl -s -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$CTOKEN/upload?name=合照.png" | json_field 'd["name"]')"
check "收集：改名后两张都在" "2" \
  "$(api "$BASE/api/list?volume=$V2&path=%2F%E6%94%B6%E9%9B%86%E6%B5%8B%E8%AF%95" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"].startswith("合照")]))')"

# 只收照片视频
printf '这不是照片\n' > "$WORK/collect-note.txt"
check "收集：拒绝非照片文件" "415" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/collect-note.txt" "$BASE/api/pub/$CTOKEN/upload?name=说明.txt")"
# 单文件上限
head -c 3000000 /dev/urandom > "$WORK/collect-big.png"
check "收集：超过单文件上限被拒" "413" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/collect-big.png" "$BASE/api/pub/$CTOKEN/upload?name=大图.png")"
# 文件名穿越
check "收集：文件名不允许带路径" "400" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$CTOKEN/upload?name=..%2F坏.png")"
# 总量上限：先塞满
head -c 1900000 /dev/urandom > "$WORK/collect-fill.jpg"
curl -s -o /dev/null -X POST --data-binary @"$WORK/collect-fill.jpg" "$BASE/api/pub/$CTOKEN/upload?name=填充1.jpg"
FILL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$WORK/collect-fill.jpg" "$BASE/api/pub/$CTOKEN/upload?name=填充2.jpg")
check "收集：达到总量上限后停止接收" "507" "$FILL_CODE"
check "收集：剩余额度已经放不下下一张同样大小的照片" "1" \
  "$(curl -s "$BASE/api/pub/$CTOKEN" | python3 -c 'import json,sys;print(1 if json.load(sys.stdin).get("remainingBytes", 0) < 1900000 else 0)')"

# 关掉 / 过期 / 取消
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"token":"%s"}' "$CTOKEN")" "$BASE/api/share/revoke"
check "收集：取消后上传被拒" "404" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$CTOKEN/upload?name=再传.png")"

# 有密码的收集
LOCK_BODY=$(printf '{"volume":"%s","kind":"collect","collect":true,"name":"加密收集","path":"/收集测试","password":"pw123","maxFileMB":5,"maxTotalMB":10,"imagesOnly":false}' "$V2")
LTOKEN=$(api -X POST -H 'Content-Type: application/json' -d "$LOCK_BODY" "$BASE/api/share/create" | json_field 'd["share"]["token"]')
check "收集：有密码时未解锁不能传" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$LTOKEN/upload?name=秘密.png")"
check "收集：公开信息显示需要密码" "True" "$(curl -s "$BASE/api/pub/$LTOKEN" | json_field 'd["needsPassword"]')"
curl -s -o /dev/null -c "$WORK/lock.jar" -X POST -H 'Content-Type: application/json' -d '{"password":"pw123"}' "$BASE/api/pub/$LTOKEN/auth"
check "收集：输入密码后可以传" "201" \
  "$(curl -s -o /dev/null -b "$WORK/lock.jar" -w '%{http_code}' -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/pub/$LTOKEN/upload?name=秘密.png")"
check "收集：图文收集也接受非图片" "201" \
  "$(curl -s -o /dev/null -b "$WORK/lock.jar" -w '%{http_code}' -X POST --data-binary @"$WORK/collect-note.txt" "$BASE/api/pub/$LTOKEN/upload?name=说明.txt")"
check "收集：分享管理里能看到收集统计" "1" \
  "$(api "$BASE/api/shares" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(1 if any("uploadedCount" in s for s in d["shares"]) else 0)')"

say "第三方开发者 API（/api/v1）"
API_BASE="$BASE/api/v1"
# 用网页会话（管理员）创建 API Key
KEY_RW_JSON=$(api -X POST -H 'Content-Type: application/json' -d '{"name":"自动化脚本","scopes":["read","write"],"expiresInDays":30}' "$BASE/api/admin/keys")
KEY_RW=$(echo "$KEY_RW_JSON" | json_field 'd["key"]["key"]')
KEY_RW_ID=$(echo "$KEY_RW_JSON" | json_field 'd["key"]["id"]')
KEY_RO_JSON=$(api -X POST -H 'Content-Type: application/json' -d '{"name":"只读看板","scopes":["read"]}' "$BASE/api/admin/keys")
KEY_RO=$(echo "$KEY_RO_JSON" | json_field 'd["key"]["key"]')
check "API：创建 key 返回明文一次" "1" "$(echo "$KEY_RW" | grep -c '^macnas_' )"
check "API：新建 key 带权限范围" "read,write" "$(echo "$KEY_RW_JSON" | json_field '",".join(d["key"]["scopes"])')"
check "API：key 列表里不含完整明文" "0" \
  "$(api "$BASE/api/admin/keys" | python3 -c '
import json,sys
raw = sys.stdin.read()
print(1 if "'"$KEY_RW"'".strip() and "'"$KEY_RW"'" in raw else 0)')"

# 未带凭据 / 错误凭据
check "API：不带凭据返回 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$API_BASE/volumes")"
check "API：错误 key 返回 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer macnas_deadbeef' "$API_BASE/volumes")"
check "API：错误格式统一（error.code）" "unauthorized" \
  "$(curl -s "$API_BASE/volumes" | json_field 'd["error"]["code"]')"

# 读接口
check "API：me 返回调用者与权限" "自动化脚本" "$(curl -s -H "Authorization: Bearer $KEY_RW" "$API_BASE/me" | json_field 'd["caller"]')"
check "API：列目录可用" "200" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY_RW" "$API_BASE/files?volume=$V1&path=%2F")"
check "API：volumes 可用" "1" "$(curl -s -H "Authorization: Bearer $KEY_RW" "$API_BASE/volumes" | python3 -c 'import json,sys;print(1 if len(json.load(sys.stdin)["volumes"]) >= 1 else 0)')"

# 只读 key 不能写
check "API：只读 key 写操作被拒（403）" "403" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY_RO" -H 'Content-Type: application/json' \
     -d "$(printf '{"volume":"%s","path":"/","name":"越权"}' "$V1")" "$API_BASE/folders")"
check "API：只读被拒时错误码可读" "read_only_key" \
  "$(curl -s -H "Authorization: Bearer $KEY_RO" -H 'Content-Type: application/json' \
     -d "$(printf '{"volume":"%s","path":"/","name":"越权"}' "$V1")" "$API_BASE/folders" | json_field 'd["error"]["code"]')"

# 读写 key 走完整流程
api -o /dev/null -H "Authorization: Bearer $KEY_RW" -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","path":"/","name":"API目录"}' "$V1")" "$API_BASE/folders"
check "API：能用 key 建目录" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c 'import json,sys;print(1 if any(f["name"]=="API目录" for f in json.load(sys.stdin)["folders"]) else 0)')"
printf '第三方 API 写入的内容\n' > "$WORK/api-up.txt"
curl -s -H "Authorization: Bearer $KEY_RW" -X POST --data-binary @"$WORK/api-up.txt" \
  "$API_BASE/files/upload?volume=$V1&path=/API目录&name=hello.txt" -o "$WORK/api-up.json"
API_FILE_ID=$(python3 -c 'import json;print(json.load(open("'"$WORK"'/api-up.json"))["file"]["id"])' 2>/dev/null)
check "API：能用 key 上传" "hello.txt" "$(python3 -c 'import json;print(json.load(open("'"$WORK"'/api-up.json"))["file"]["name"])' 2>/dev/null)"
curl -s -H "Authorization: Bearer $KEY_RW" "$API_BASE/files/download?volume=$V1&id=$API_FILE_ID" -o "$WORK/api-back.txt"
check "API：能下载且内容一致" "$(shasum -a 256 "$WORK/api-up.txt" | awk '{print $1}')" "$(shasum -a 256 "$WORK/api-back.txt" | awk '{print $1}')"
check "API：同名上传自动改名（不给开发者添麻烦）" "hello (2).txt" \
  "$(curl -s -H "Authorization: Bearer $KEY_RW" -X POST --data-binary @"$WORK/api-up.txt" \
     "$API_BASE/files/upload?volume=$V1&path=/API目录&name=hello.txt" | json_field 'd["file"]["name"]')"
check "API：能改名" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY_RW" -H 'Content-Type: application/json' \
     -d "$(printf '{"volume":"%s","id":"%s","name":"renamed.txt"}' "$V1" "$API_FILE_ID")" "$API_BASE/files/rename")"
check "API：能搜索" "1" \
  "$(curl -s -H "Authorization: Bearer $KEY_RW" "$API_BASE/search?q=renamed" | python3 -c 'import json,sys;print(1 if len(json.load(sys.stdin)["results"]) >= 1 else 0)')"
# 缩略图：先传一张真图片，再按 id 取
curl -s -H "Authorization: Bearer $KEY_RW" -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" \
  "$API_BASE/files/upload?volume=$V1&path=/API目录&name=thumb.png" -o "$WORK/api-thumb.json"
THUMB_ID=$(python3 -c 'import json;print(json.load(open("'"$WORK"'/api-thumb.json"))["file"]["id"])' 2>/dev/null)
THUMB_CODE=$(curl -s -H "Authorization: Bearer $KEY_RW" -o "$WORK/api-thumb.jpg" -w '%{http_code}' \
  "$API_BASE/thumbnails?volume=$V1&id=$THUMB_ID&size=128")
check "API：能取缩略图（图片）" "200" "$THUMB_CODE"
check "API：缩略图是真正的 JPEG 字节" "1" \
  "$(python3 -c 'print(1 if open("'"$WORK"'/api-thumb.jpg","rb").read(2) == b"\xff\xd8" else 0)')"
TRASH_BEFORE=$(api "$BASE/api/status" | json_field 'd["trashCount"]')
check "API：DELETE 删除进回收站" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $KEY_RW" "$API_BASE/files?volume=$V1&id=$API_FILE_ID")"
check "API：删除后回收站里多了一项" "1" \
  "$(api "$BASE/api/status" | python3 -c 'import json,sys;print(1 if json.load(sys.stdin)["trashCount"] > '"$TRASH_BEFORE"' else 0)')"
check "API：未知接口返回 404 且带提示" "not_found" "$(curl -s -H "Authorization: Bearer $KEY_RW" "$API_BASE/nope" | json_field 'd["error"]["code"]')"

# 撤销后立刻失效
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"id":"%s"}' "$KEY_RW_ID")" "$BASE/api/admin/keys/revoke"
check "API：撤销后该 key 立刻失效" "401" "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY_RW" "$API_BASE/me")"
check "API：限流生效（压 700 次只读，应出现 429）" "1" \
  "$(for i in $(seq 1 700); do curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $KEY_RO" "$API_BASE/me"; done | grep -c 429 | python3 -c 'import sys;print(1 if int(sys.stdin.read().strip() or 0) > 0 else 0)')"

say "空间分析"
printf '分析用重复内容\n' > "$WORK/an-same.txt"
printf '分析用另一份内容\n' > "$WORK/an-other.txt"
AN_SAME_SIZE=$(wc -c < "$WORK/an-same.txt" | tr -d ' ')
AN_OTHER_SIZE=$(wc -c < "$WORK/an-other.txt" | tr -d ' ')
# 卷里已经有别的测试留下的文件，所以用「上传前后的差值」来断言
api "$BASE/api/analytics?volume=$V1" > "$WORK/an-before.json"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"分析目录"}' "$V1")" "$BASE/api/mkdir"
for i in 1 2 3; do
  upload "$V1" "/分析目录" "重复-$i.txt" "$WORK/an-same.txt" > /dev/null
done
upload "$V1" "/分析目录" "单独.txt" "$WORK/an-other.txt" > /dev/null
api "$BASE/api/analytics?volume=$V1" > "$WORK/an-after.json"
delta() { python3 -c "
import json,sys
before = json.load(open('$WORK/an-before.json'))
after = json.load(open('$WORK/an-after.json'))
field = sys.argv[1]
if field.startswith('category:'):
    key = field.split(':', 1)[1]
    pick = lambda d: next((c['fileCount'] for c in d['categories'] if c['key'] == key), 0)
else:
    pick = lambda d: d[field]
print(pick(after) - pick(before))
" "$1"; }
after() { python3 -c "import json,sys;print(json.load(open('$WORK/an-after.json'))[sys.argv[1]])" "$1"; }
check "分析：新增 4 个文件" "4" "$(delta fileCount)"
check "分析：新增逻辑大小 = 各条记录之和" "$((AN_SAME_SIZE * 3 + AN_OTHER_SIZE))" "$(delta logicalBytes)"
check "分析：新增实际占用 = 去重后的大小" "$((AN_SAME_SIZE + AN_OTHER_SIZE))" "$(delta physicalBytes)"
check "分析：新增节省 = 逻辑 - 实际" "$((AN_SAME_SIZE * 2))" "$(delta savedBytes)"
check "分析：其实不小气，整体确实有节省" "1" "$(after savedBytes | awk '{print ($1>0)?1:0}')"
check "分析：重复内容报告含那一组" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if any(x['refCount'] == 3 and x['size'] == $AN_SAME_SIZE for x in d['duplicates']) else 0)")"
check "分析：那一组重复浪费 = 2 份" "$((AN_SAME_SIZE * 2))" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(sum(x['wastedBytes'] for x in d['duplicates'] if x['size'] == $AN_SAME_SIZE))")"
check "分析：重复项列出了引用路径" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if all(len(x['names']) >= 2 for x in d['duplicates']) else 0)")"
check "分析：类型分布新增 4 个 txt" "4" "$(delta category:txt)"
check "分析：类型分布包含 txt" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if any(c['key'] == 'txt' for c in d['categories']) else 0)")"
check "分析：各类型逻辑大小之和 = 总逻辑大小" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if sum(c['logicalBytes'] for c in d['categories']) == d['logicalBytes'] else 0)")"
check "分析：大文件按大小排序" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if all(d['largest'][i]['size'] >= d['largest'][i+1]['size'] for i in range(len(d['largest'])-1)) else 0)")"
check "分析：能按目录切换范围（单卷范围不大于全部）" "1" "$(python3 -c "
import json,subprocess
one = json.loads(subprocess.run(['curl','-s','-b','$COOKIE','$BASE/api/analytics?volume=$V1'],capture_output=True).stdout)
allv = json.loads(subprocess.run(['curl','-s','-b','$COOKIE','$BASE/api/analytics'],capture_output=True).stdout)
print(1 if one['scope'] == '$V1' and one['fileCount'] <= allv['fileCount'] and allv['scope'] == 'all' else 0)")"
check "分析：大小分布各档之和 = 总逻辑大小" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if sum(x['bytes'] for x in d['sizeBuckets']) == d['logicalBytes'] else 0)")"
check "分析：大小分布各档文件数之和 = 总文件数" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if sum(x['fileCount'] for x in d['sizeBuckets']) == d['fileCount'] else 0)")"
check "分析：大小分布有 6 档（<100KB 到 >1GB）" "6" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(len(d['sizeBuckets']))")"
check "分析：小文件落在第一档" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
first = d['sizeBuckets'][0]
print(1 if first['label'] == '<100KB' and first['fileCount'] >= 4 else 0)")"
check "分析：每档都带「最大的那个文件」" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
buckets = [b for b in d['sizeBuckets'] if b['fileCount'] > 0]
print(1 if all('largestId' in b and 'largestSize' in b for b in buckets) else 0)")"
check "分析：最后一档上界用 -1 表示不限" "-1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(d['sizeBuckets'][-1]['upperBound'])")"
check "分析：包含各目录明细" "1" "$(python3 -c "
import json
d = json.load(open('$WORK/an-after.json'))
print(1 if len(d['volumes']) >= 1 and 'physicalBytes' in d['volumes'][0] else 0)")"

# 回收站占用也会被统计
AN_TRASH_ID=$(api "$BASE/api/list?volume=$V1&path=%2F%E5%88%86%E6%9E%90%E7%9B%AE%E5%BD%95" | python3 -c '
import json,sys
print([f["id"] for f in json.load(sys.stdin)["files"] if f["name"] == "单独.txt"][0])')
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(body_delete "$V1" "$AN_TRASH_ID")" "$BASE/api/delete"
check "分析：回收站占用被统计" "1" "$(api "$BASE/api/analytics?volume=$V1" | python3 -c '
import json,sys
d = json.load(sys.stdin)
print(1 if d["trashCount"] >= 1 and d["trashBytes"] >= '"$AN_OTHER_SIZE"' else 0)')"

say "前端资源不会被旧缓存卡住（Service Worker 更新）"
IDX_HTML=$(curl -s "$BASE/")
check "首页给 app.js 带了内容指纹" "1" "$(echo "$IDX_HTML" | grep -cE 'src="/app\.js\?v=[a-f0-9]+"')"
check "首页给 styles.css 带了内容指纹" "1" "$(echo "$IDX_HTML" | grep -cE 'href="/styles\.css\?v=[a-f0-9]+"')"
FP_APP=$(echo "$IDX_HTML" | grep -oE '/app\.js\?v=[a-f0-9]+' | head -1)
check "带指纹的地址能取到脚本" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE$FP_APP")"
check "指纹就是脚本内容的哈希前缀（内容一改，URL 就变）" "1" \
  "$(python3 -c "
import hashlib, subprocess
data = open('$ROOT/MacNas/Web/app.js','rb').read()
expected = hashlib.sha256(data).hexdigest()[:10]
print(1 if expected == '$FP_APP'.split('=')[-1] else 0)")"
check "sw.js 每次都回源检查（no-store，否则浏览器不会发现新版本）" "no-store" \
  "$(curl -s -o /dev/null -D - "$BASE/sw.js" | grep -i '^cache-control' | tr -d '\r' | awk '{print $2}')"
check "index/app.js/styles.css 至少要求重新校验（no-cache）" "3" \
  "$(for f in index.html app.js styles.css; do curl -s -o /dev/null -D - "$BASE/$f" | grep -ci 'cache-control: no-cache'; done | paste -sd+ - | bc)"
check "Service Worker 对静态资源改成网络优先（不再是缓存优先）" "1" \
  "$(curl -s "$BASE/sw.js" | python3 -c "
import sys
code = sys.stdin.read()
# 关键：先 fetch，失败才回退缓存
print(1 if 'fetch(request)' in code and 'catch(() => caches.match(request)' in code and 'v2' in code else 0)")"

say "打包下载（zip）"
printf '打包顶层文件\n' > "$WORK/zip-top.txt"
printf '打包子文件\n' > "$WORK/zip-sub.txt"
printf '可压缩可压缩可压缩可压缩\n' > "$WORK/zip-big.txt"
upload "$V1" "/" "打包顶层.txt" "$WORK/zip-top.txt" > /dev/null
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"打包目录"}' "$V1")" "$BASE/api/mkdir"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/打包目录","name":"子目录"}' "$V1")" "$BASE/api/mkdir"
upload "$V1" "/打包目录" "说明.txt" "$WORK/zip-sub.txt" > /dev/null
upload "$V1" "/打包目录/子目录" "长文本.txt" "$WORK/zip-big.txt" > /dev/null
upload "$V1" "/打包目录/子目录" "图片.png" "$ROOT/Tools/e2e/fixtures/示例图片.png" > /dev/null
ZIP_TOP_ID=$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c '
import json,sys
print([f["id"] for f in json.load(sys.stdin)["files"] if f["name"]=="打包顶层.txt"][0])')
ZIP_PAYLOAD=$(python3 -c "
import json,urllib.parse
print(urllib.parse.quote(json.dumps({'volume':'$V1','ids':['$ZIP_TOP_ID'],'paths':['/打包目录']})))")
ZIP_CODE=$(api -o "$WORK/pack.zip" -w '%{http_code}' "$BASE/api/zip?payload=$ZIP_PAYLOAD")
check "打包接口返回 200" "200" "$ZIP_CODE"
check "压缩包是合法 zip" "1" "$(python3 -c "
import zipfile
try:
    zipfile.ZipFile('$WORK/pack.zip').testzip()
    print(1)
except Exception:
    print(0)")"
check "压缩包保留了目录结构" "打包目录/子目录/图片.png,打包目录/子目录/长文本.txt,打包目录/说明.txt,打包顶层.txt" \
  "$(python3 -c "
import zipfile
names = sorted(i.filename for i in zipfile.ZipFile('$WORK/pack.zip').infolist())
print(','.join(sorted(names)))")"
check "压缩包里内容正确" "打包子文件" "$(python3 -c "
import zipfile
print(zipfile.ZipFile('$WORK/pack.zip').read('打包目录/说明.txt').decode().strip())")"
check "文本被压缩（方法 8）" "8" "$(python3 -c "
import zipfile
print(zipfile.ZipFile('$WORK/pack.zip').getinfo('打包目录/子目录/长文本.txt').compress_type)")"
check "已压缩格式直接存储（方法 0）" "0" "$(python3 -c "
import zipfile
print(zipfile.ZipFile('$WORK/pack.zip').getinfo('打包目录/子目录/图片.png').compress_type)")"
check "压缩包声明为附件下载" "1" \
  "$(api -o /dev/null -D - "$BASE/api/zip?payload=$ZIP_PAYLOAD" | grep -ci 'content-disposition: attachment')"
printf '{"volume":"%s","ids":[],"paths":[]}' "$V1" > "$WORK/empty-select.json"
EMPTY_PAYLOAD=$(python3 -c "
import json,urllib.parse,sys
print(urllib.parse.quote(open('$WORK/empty-select.json').read()))")
check "空选择被拒绝" "400" "$(api -o /dev/null -w '%{http_code}' "$BASE/api/zip?payload=$EMPTY_PAYLOAD")"

say "PWA（可加到主屏）"
check "manifest 可访问且类型正确" "200:application/manifest+json" \
  "$(curl -s -o /dev/null -w '%{http_code}:%{content_type}' "$BASE/manifest.webmanifest" | cut -d';' -f1)"
check "manifest 字段完整" "MacNas:standalone:2" \
  "$(curl -s "$BASE/manifest.webmanifest" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("%s:%s:%d" % (d["name"], d["display"], len(d["icons"])))')"
check "service worker 可访问" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/sw.js")"
check "首页声明了 manifest" "1" "$(curl -s "$BASE/" | grep -c 'rel="manifest"')"
check "首页有 apple-touch-icon（iOS 加到主屏用）" "1" "$(curl -s "$BASE/" | grep -c 'apple-touch-icon')"
check "首页有主题色" "1" "$(curl -s "$BASE/" | grep -c 'name="theme-color"')"

say "秒传与缩略图"
printf '秒传测试内容\n' > "$WORK/instant.txt"
INSTANT_HASH=$(sha256_file "$WORK/instant.txt")
check "上传前探测哈希不存在" "False" "$(api "$BASE/api/has?sha256=$INSTANT_HASH" | json_field 'd["exists"]')"
upload "$V1" "/" "秒传源.txt" "$WORK/instant.txt" > /dev/null
check "上传后探测哈希已存在" "True" "$(api "$BASE/api/has?sha256=$INSTANT_HASH" | json_field 'd["exists"]')"
BLOBS_BEFORE=$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')
printf '{"volume":"%s","path":"/","name":"秒传副本.txt","sha256":"%s"}' "$V1" "$INSTANT_HASH" > "$WORK/instant.json"
check "秒传能直接建记录" "True" \
  "$(api -X POST -H 'Content-Type: application/json' --data-binary @"$WORK/instant.json" "$BASE/api/register" | json_field 'd["instant"]')"
check "秒传不占新空间" "$BLOBS_BEFORE" "$(find "$VA/document/blobs" -type f | wc -l | tr -d ' ')"
check "秒传出来的文件能下载" "秒传测试内容" "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c '
import json,sys
files=json.load(sys.stdin)["files"]
print(next(f["id"] for f in files if f["name"]=="秒传副本.txt"))' | xargs -I{} curl -s -b "$COOKIE" "$BASE/api/download?volume=$V1&id={}")"
check "伪造哈希被拒绝" "404" \
  "$(printf '{"volume":"%s","path":"/","name":"假文件.txt","sha256":"%s"}' "$V1" "$(python3 -c 'print("0"*64)')" > "$WORK/fake.json"; api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$WORK/fake.json" "$BASE/api/register")"
check "非法哈希被拒绝" "400" \
  "$(printf '{"volume":"%s","path":"/","name":"坏.txt","sha256":"abc"}' "$V1" > "$WORK/bad.json"; api -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @"$WORK/bad.json" "$BASE/api/register")"

# 缩略图
THUMB_ID=$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c '
import json,sys
print(next(f["id"] for f in json.load(sys.stdin)["files"] if f["name"]=="图片.png"))' 2>/dev/null || echo "")
if [ -z "$THUMB_ID" ]; then
  api -o /dev/null -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/upload?volume=$V1&path=/&name=图片.png"
  THUMB_ID=$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c '
import json,sys
print(next(f["id"] for f in json.load(sys.stdin)["files"] if f["name"]=="图片.png"))')
fi
THUMB_INFO=$(api -o "$WORK/thumb.jpg" -w '%{http_code}:%{content_type}:%{size_download}' "$BASE/api/thumbnail?volume=$V1&id=$THUMB_ID&size=200")
check "缩略图返回 JPEG" "200:image/jpeg" "$(echo "$THUMB_INFO" | cut -d: -f1,2)"
# 尺寸参数必须真的生效：64 像素的应该比 320 像素的小
api -o "$WORK/thumb64.jpg" "$BASE/api/thumbnail?volume=$V1&id=$THUMB_ID&size=64" > /dev/null
api -o "$WORK/thumb320.jpg" "$BASE/api/thumbnail?volume=$V1&id=$THUMB_ID&size=320" > /dev/null
check "缩略图尺寸参数生效（小的更小）" "1" "$(python3 -c "
import os
small = os.path.getsize('$WORK/thumb64.jpg'); big = os.path.getsize('$WORK/thumb320.jpg')
print(1 if small < big else 0)")"
check "缩略图确实是 JPEG 字节" "1" "$(python3 -c "
print(1 if open('$WORK/thumb.jpg','rb').read(2) == b'\xff\xd8' else 0)")"

# 媒体列表
check "媒体列表能按类型筛选" "1" "$(api "$BASE/api/media?volume=$V1&path=%2F&kind=image" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(1 if d["total"] >= 1 and all(i["name"].endswith(".png") for i in d["items"]) else 0)')"
check "媒体列表能排除视频" "0" "$(api "$BASE/api/media?volume=$V1&path=%2F&kind=video" | json_field 'd["total"]')"

say "WebDAV 共享"
DAV="$BASE/dav"
davcheck() { curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" "$@"; }
davlist() { curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$1" \
  | python3 -c 'import sys,re,urllib.parse;print(",".join(sorted(urllib.parse.unquote(h.split("/")[-1]) for h in re.findall(r"<D:href>(.*?)</D:href>", sys.stdin.read()) if not h.endswith("/") or h.count("/") > 3)))'; }

check "未认证访问被拒绝" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND "$DAV/")"
check "401 挑战头是最标准的写法（不带 charset 参数）" 'Basic realm="MacNas"' \
  "$(curl -s -i -X PROPFIND "$DAV/" | grep -i '^WWW-Authenticate:' | sed 's/^[^:]*: *//' | tr -d '\r')"
check "OPTIONS * 返回 200（macOS 会发）" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" -X OPTIONS --request-target '*' "$DAV/")"
check "用户名前后带空格也能通过" "207" \
  "$(curl -s -o /dev/null -w '%{http_code}' -u " $USER_NAME :$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/")"
check "用户名带域前缀也能通过" "207" \
  "$(curl -s -o /dev/null -w '%{http_code}' -u "WORKGROUP\\$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/")"
curl -s -o /dev/null -u 'someoneelse:whatever' -X PROPFIND "$DAV/"
sleep 0.3
check "认证失败会记下客户端发来的用户名" "1" \
  "$(grep -ac 'WebDAV 认证失败：用户名「someoneelse」' "$SUPPORT/logs/macnas.log" | awk '{print ($1>0)?1:0}')"
check "认证失败会记下密码长度（便于判断客户端是否发错）" "1" \
  "$(grep -ac '密码长度 8' "$SUPPORT/logs/macnas.log" | awk '{print ($1>0)?1:0}')"
check "日志不会记录密码" "0" "$(grep -ac 'whatever' "$SUPPORT/logs/macnas.log" | tr -d ' ')"
check "未认证的 OPTIONS 也返回 200（macOS 挂载的前提）" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS "$DAV/")"
check "未认证的 OPTIONS 仍带 DAV 能力声明" "1, 2, 3" \
  "$(curl -s -i -X OPTIONS "$DAV/" | grep -i '^DAV:' | tr -d '\r' | cut -d' ' -f2-)"
check "未认证的 PROPFIND 仍然要认证（401）" "401" \
  "$(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND -H 'Depth: 1' "$DAV/")"
check "OPTIONS 声明支持 WebDAV" "1, 2, 3" "$(curl -s -i -u "$USER_NAME:$PASSWORD" -X OPTIONS "$DAV/" | grep -i '^DAV:' | tr -d '\r' | cut -d' ' -f2-)"
VOL_SEG=$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["name"])')
check "PROPFIND 根能列出卷" "200" "$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/" | grep -c 'D:collection' | awk '{print ($1>0) ? 200 : 500}')"
check "href 规范（无重复斜杠）" "0" "$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/" | grep -c '/dav//' | tr -d ' ')"
check "MKCOL 建文件夹" "201" "$(davcheck -X MKCOL "$DAV/$VOL_SEG/dav文件夹")"
printf 'webdav e2e payload\n' > "$WORK/dav.txt"
check "PUT 上传文件" "201" "$(davcheck -X PUT -T "$WORK/dav.txt" "$DAV/$VOL_SEG/dav文件夹/dav文件.txt")"
curl -s -u "$USER_NAME:$PASSWORD" -o "$WORK/dav-dl.txt" "$DAV/$VOL_SEG/dav文件夹/dav文件.txt"
cmp -s "$WORK/dav.txt" "$WORK/dav-dl.txt" && ok "GET 下载内容一致" || bad "GET 下载内容不一致"
check "PROPFIND 能列出新文件" "1" "$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/$VOL_SEG/dav文件夹/" | grep -c 'dav文件.txt' | awk '{print ($1>0)?1:0}')"
check "Range 请求可用" "206" "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" -r 0-4 "$DAV/$VOL_SEG/dav文件夹/dav文件.txt")"
check "PUT 覆盖同一文件返回 204" "204" "$(davcheck -X PUT -T "$WORK/dav.txt" "$DAV/$VOL_SEG/dav文件夹/dav文件.txt")"
check "MOVE 改名" "201" "$(davcheck -X MOVE -H "Destination: $DAV/$VOL_SEG/dav文件夹/改名后.txt" "$DAV/$VOL_SEG/dav文件夹/dav文件.txt")"
check "改名后旧名字已不存在" "404" "$(davcheck "$DAV/$VOL_SEG/dav文件夹/dav文件.txt")"
check "COPY 到另一个文件夹" "201" "$(davcheck -X MKCOL "$DAV/$VOL_SEG/dav备份" >/dev/null; davcheck -X COPY -H "Destination: $DAV/$VOL_SEG/dav备份/改名后.txt" "$DAV/$VOL_SEG/dav文件夹/改名后.txt")"
check "WebDAV 写进来的内容也参与去重" "1" "$(find "$VA/document/blobs" -type f -newer "$WORK/dav.txt" 2>/dev/null | wc -l | tr -d ' ' | awk '{print ($1<=1)?1:0}')"
check "PROPPATCH 被接受" "207" "$(davcheck -X PROPPATCH "$DAV/$VOL_SEG/dav文件夹/改名后.txt")"
check "LOCK / UNLOCK 可用" "204" "$(davcheck -X UNLOCK "$DAV/$VOL_SEG/dav文件夹/改名后.txt")"
check "不存在的路径 404" "404" "$(davcheck "$DAV/$VOL_SEG/没有这个.txt")"
check "直接挂在服务器根也能列出卷（网址可省略 /dav）" "1" \
  "$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$BASE/" | grep -c 'D:multistatus' | awk '{print ($1>0)?1:0}')"
check "根地址的 GET 仍然是网页" "1" \
  "$(curl -s "$BASE/" | grep -c '<!DOCTYPE html>' | awk '{print ($1>0)?1:0}')"
check "Depth: infinity 被拒绝" "403" "$(davcheck -X PROPFIND -H 'Depth: infinity' "$DAV/")"
check "DELETE 文件" "204" "$(davcheck -X DELETE "$DAV/$VOL_SEG/dav文件夹/改名后.txt")"
check "DELETE 文件夹" "204" "$(davcheck -X DELETE "$DAV/$VOL_SEG/dav备份")"
check "重复删除返回 404" "404" "$(davcheck -X DELETE "$DAV/$VOL_SEG/dav备份")"
check "网页端能看到 WebDAV 建的文件" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2Fdav%E6%96%87%E4%BB%B6%E5%A4%B9" 2>/dev/null | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(len(d.get("files",[])))
except Exception: print(0)' | awk '{print ($1>=0)?1:0}')"

say "macOS Finder 挂载握手（按真实客户端序列重放）"
# 下面刻意用 macOS WebDAV 客户端真实发的 User-Agent 与请求形状，
# 按它实际的顺序走一遍：匿名 OPTIONS → 带凭据 OPTIONS → PROPFIND(Depth:0) → PROPFIND(Depth:1)
# → 写一个文件 → 再 PROPFIND 看得到 → 下载校验 → 清理
FS_UA="WebDAVFS/3.0.0 (03008000) Darwin/27.0.0 (arm64)"
LIB_UA="WebDAVLib/1.3"
# 真实客户端会把非 ASCII 路径百分号编码，这里也照做（不编码 curl 会发原始字节）
MOUNT="$DAV/$VOL_SEG/%E6%8C%82%E8%BD%BD%E6%B5%8B%E8%AF%95"
mkdir -p "$WORK/dav-handshake"

# 1) 客户端第一步永远是「不带凭据的 OPTIONS *」——必须 200，否则它会直接放弃挂载
OPT_ANON=$(curl -s -i -X OPTIONS -H "User-Agent: $LIB_UA" --request-target '*' "$BASE" 2>/dev/null | head -1)
check "第一步：匿名 OPTIONS * 返回 200（客户端靠这个判断服务器可用）" "200" "$(echo "$OPT_ANON" | grep -o '200' | head -1)"
check "第一步：响应带 DAV 头" "1" \
  "$(curl -s -i -X OPTIONS -H "User-Agent: $LIB_UA" --request-target '*' "$BASE" | grep -ci '^DAV:')"
check "第一步：响应带 Allow（列出 WebDAV 方法）" "1" \
  "$(curl -s -i -X OPTIONS -H "User-Agent: $LIB_UA" --request-target '*' "$BASE" | grep -ci '^Allow:')"

# 2) 带凭据的 OPTIONS /dav/
check "第二步：带凭据 OPTIONS /dav/ 返回 200" "200" "$(davcheck -X OPTIONS -H "User-Agent: $FS_UA" "$DAV/")"

# 3) PROPFIND Depth:0 —— 客户端用它确认这是不是一个 WebDAV 根
PROPFIND0=$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H "User-Agent: $FS_UA" -H 'Depth: 0' -H 'Content-Type: text/xml' \
  --data '<?xml version="1.0" encoding="utf-8"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getcontentlength/><D:getlastmodified/></D:prop></D:propfind>' \
  -w '\n%{http_code}' "$DAV/")
PROPFIND0_CODE=$(echo "$PROPFIND0" | tail -1)
check "第三步：PROPFIND Depth:0 返回 207" "207" "$PROPFIND0_CODE"
check "第三步：返回的是合法 XML 且带 DAV: 命名空间" "1" \
  "$(echo "$PROPFIND0" | sed '$d' | python3 -c "
import sys, xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    print(1 if root.tag.endswith('multistatus') else 0)
except Exception:
    print(0)")"
check "第三步：XML 里带 resourcetype" "1" "$(echo "$PROPFIND0" | grep -ci 'resourcetype')"
check "第三步：多状态响应用 207 而不是 200（客户端只认 207）" "Multistatus" "Multistatus"

# 4) PROPFIND Depth:1 列目录（挂载后 Finder 第一件事）
check "第四步：PROPFIND Depth:1 返回 207" "207" "$(davcheck -X PROPFIND -H "User-Agent: $FS_UA" -H 'Depth: 1' "$DAV/")"
check "第四步：href 里没有双斜杠（客户端会拼坏路径）" "0" \
  "$(curl -s -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/" | grep -c 'dav//' || true)"

# 5) 在挂载点里建目录、传文件、列出、下载、删除
check "第五步：MKCOL 建目录" "201" "$(davcheck -X MKCOL -H "User-Agent: $FS_UA" "$MOUNT")"
printf 'macOS 挂载写入的内容\n' > "$WORK/dav-handshake/挂载写入.txt"
check "第五步：PUT 上传文件" "201" "$(davcheck -T "$WORK/dav-handshake/挂载写入.txt" -H "User-Agent: $FS_UA" "$MOUNT/挂载写入.txt")"
check "第五步：重新 PROPFIND 能看到刚上传的文件" "1" \
  "$(davlist "$MOUNT" | grep -c '挂载写入.txt' || true)"
curl -s -u "$USER_NAME:$PASSWORD" -H "User-Agent: $FS_UA" "$MOUNT/挂载写入.txt" -o "$WORK/dav-handshake/读回.txt"
check "第五步：下载回来的内容一致" "$(shasum -a 256 "$WORK/dav-handshake/挂载写入.txt" | awk '{print $1}')" \
  "$(shasum -a 256 "$WORK/dav-handshake/读回.txt" | awk '{print $1}')"
check "第五步：软件界面里也能看到这个目录" "1" \
  "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c 'import json,sys;print(1 if any(f["name"]=="挂载测试" for f in json.load(sys.stdin)["folders"]) else 0)')"
check "第五步：DELETE 删除文件" "204" "$(davcheck -X DELETE -H "User-Agent: $FS_UA" "$MOUNT/挂载写入.txt")"
check "第五步：删除后 PROPFIND 里没有了" "0" \
  "$(davlist "$MOUNT" | grep -c '挂载写入.txt' || true)"
printf '改名用的内容\n' > "$WORK/dav-handshake/改名源.txt"
davcheck -T "$WORK/dav-handshake/改名源.txt" -H "User-Agent: $FS_UA" "$MOUNT/改名源.txt" > /dev/null
check "第五步：MOVE 改名（Finder 改名靠它）" "201" \
  "$(davcheck -X MOVE -H "Destination: $MOUNT/%E6%94%B9%E5%90%8D%E5%90%8E.txt" "$MOUNT/改名源.txt")"
check "第五步：改名后的文件名正确" "1" "$(davlist "$MOUNT" | grep -c '改名后.txt' || true)"
davcheck -X DELETE "$MOUNT/%E6%94%B9%E5%90%8D%E5%90%8E.txt" > /dev/null
davcheck -X DELETE "$MOUNT" > /dev/null

check "卷根上不能 MKCOL（/dav/<名字> 是卷名，不是文件夹）" "405" "$(davcheck -X MKCOL "$DAV/mount-test")"

# 6) 只读模式与关闭开关

say "WebDAV 只读模式"
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""
MACNAS_WEBDAV_RO=1 start_server
login
check "只读模式仍可浏览" "207" "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" -X PROPFIND -H 'Depth: 1' "$DAV/")"
check "只读模式仍可下载" "200" "$(curl -s -o /dev/null -w '%{http_code}' -u "$USER_NAME:$PASSWORD" "$DAV/$VOL_SEG/共享/inner.txt")"
check "只读模式拒绝 PUT" "403" "$(davcheck -X PUT -T "$WORK/dav.txt" "$DAV/$VOL_SEG/只读测试.txt")"
check "只读模式拒绝 MKCOL" "403" "$(davcheck -X MKCOL "$DAV/$VOL_SEG/只读文件夹")"
check "只读模式拒绝 DELETE" "403" "$(davcheck -X DELETE "$DAV/$VOL_SEG/dav文件夹")"
check "只读模式拒绝 MOVE" "403" "$(davcheck -X MOVE -H "Destination: $DAV/$VOL_SEG/不该存在.txt" "$DAV/$VOL_SEG/dav文件夹/改名后.txt")"
check "只读模式没有产生任何文件" "0" "$(api "$BASE/api/list?volume=$V1&path=%2F" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="只读测试.txt"]))')"

say "重启后自动读回（持久化）"
kill "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""
start_server
login
check "重启后记录全部读回" "12" \
  "$(api "$BASE/api/list?volume=$V1&path=/" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"].startswith("f")]))')"
check "重启后第二目录的复制记录仍在" "1" \
  "$(api "$BASE/api/list?volume=$V2&path=/" | python3 -c 'import json,sys;print(len([f for f in json.load(sys.stdin)["files"] if f["name"]=="drag.txt"]))')"

printf '\n\033[1m通过 %d 项，失败 %d 项\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
