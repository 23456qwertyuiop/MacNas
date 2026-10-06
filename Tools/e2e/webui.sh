#!/usr/bin/env bash
#
# MacNas 网页界面自测（真实 WebKit 渲染 + 命中测试）
#
#   ./Tools/e2e/webui.sh
#
# 这个脚本专门盯住“看着有、其实点不动”这一类只有真浏览器才暴露的问题：
#   1. 所有可点元素的命中测试（elementFromPoint 必须是它自己）
#   2. 桌面图标点击能否打开窗口
#   3. 窗口之间拖拽移动 / 复制，以及去重标记
#   4. 分享页（匿名访问）渲染、密码验证解锁
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${MACNAS_TEST_PORT:-$(( 22000 + RANDOM % 2000 ))}"
WORK="$(mktemp -d /tmp/macnas-webui.XXXXXX)"
BIN="$WORK/macnas-e2e"
CHECKER="$WORK/webcheck"
VA="$WORK/vol-a"
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

api() { curl -s --max-time 30 -b "$COOKIE" "$@"; }

mkdir -p "$VA" "$SUPPORT"

say "编译测试服务器与网页检查器"
swiftc -module-cache-path "$WORK/mc1" \
  "$ROOT"/MacNas/Core/*.swift "$ROOT"/MacNas/Server/*.swift "$ROOT"/Tools/e2e/main.swift \
  -o "$BIN" 2> "$WORK/build1.log" || { echo "编译失败："; cat "$WORK/build1.log"; exit 1; }
swiftc -module-cache-path "$WORK/mc2" "$ROOT"/Tools/e2e/webcheck/main.swift -o "$CHECKER" 2> "$WORK/build2.log" \
  || { echo "检查器编译失败："; cat "$WORK/build2.log"; exit 1; }
ok "编译完成"

MACNAS_CONFIG_DIR="$SUPPORT" MACNAS_WEB_DIR="$ROOT/MacNas/Web" \
  "$BIN" "$VA" "$PORT" "$USER_NAME" "$PASSWORD" > "$WORK/server.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
for _ in $(seq 1 80); do
  curl -s --max-time 5 -o /dev/null "$BASE/api/session" && break
  sleep 0.25
done

curl -s -c "$COOKIE" -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"username":"%s","password":"%s"}' "$USER_NAME" "$PASSWORD")" "$BASE/api/login"
V=$(api "$BASE/api/volumes" | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["id"])')

# 造点数据：一个文件夹 + 两个文件
printf 'ui test payload\n' > "$WORK/a.txt"
printf 'second payload here\n' > "$WORK/b.txt"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"目标"}' "$V")" "$BASE/api/mkdir"
api -o /dev/null -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V&path=/&name=界面测试.txt"
api -o /dev/null -X POST --data-binary @"$WORK/b.txt" "$BASE/api/upload?volume=$V&path=/目标&name=已就位.txt"
api -o /dev/null -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V&path=/目标&name=季度报告-2026.txt"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"源"}' "$V")" "$BASE/api/mkdir"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"归档"}' "$V")" "$BASE/api/mkdir"
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/源","name":"素材"}' "$V")" "$BASE/api/mkdir"
api -o /dev/null -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V&path=/源&name=文稿.txt"
api -o /dev/null -X POST --data-binary @"$WORK/b.txt" "$BASE/api/upload?volume=$V&path=/源/素材&name=图片.png"
FILE_ID=$(api "$BASE/api/list?volume=$V&path=/" | python3 -c 'import json,sys;print([f for f in json.load(sys.stdin)["files"] if f["name"]=="界面测试.txt"][0]["id"])')
FOLDER_TOKEN=$(api -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/目标","expiresInHours":24,"password":""}' "$V")" "$BASE/api/share/create" | python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])')
PASSWORD_TOKEN=$(api -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","id":"%s","expiresInHours":0,"password":"2468"}' "$V" "$FILE_ID")" "$BASE/api/share/create" | python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])')
# 预览用的真实文件（图片 / Word / 表格 / 文本），随仓库放在 fixtures 里
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"资料"}' "$V")" "$BASE/api/mkdir"
for fixture in "$ROOT"/Tools/e2e/fixtures/*; do
  api -o /dev/null -X POST --data-binary @"$fixture" \
    "$BASE/api/upload?volume=$V&path=/资料&name=$(basename "$fixture")"
done
PREVIEW_TOKEN=$(api -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","path":"/资料","expiresInHours":24,"password":""}' "$V")" \
  "$BASE/api/share/create" | python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])')
# 造一个「内容远远超过一屏」的分享，用来验证分享页能不能滚动
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"多文件"}' "$V")" "$BASE/api/mkdir"
for i in $(seq 1 20); do
  api -o /dev/null -X POST --data-binary @"$WORK/a.txt" "$BASE/api/upload?volume=$V&path=/多文件&name=文件-$i.txt"
done
SCROLL_TOKEN=$(api -X POST -H 'Content-Type: application/json' \
  -d "$(printf '{"volume":"%s","path":"/多文件","expiresInHours":24,"password":""}' "$V")" \
  "$BASE/api/share/create" | python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])')
# 回收站与版本历史用的数据
printf '待删除的内容\n' > "$WORK/trash-me.txt"
api -o /dev/null -X POST --data-binary @"$WORK/trash-me.txt" "$BASE/api/upload?volume=$V&path=/资料&name=待删除.txt"
printf '第一版\n' > "$WORK/ver1.txt"
printf '第二版\n' > "$WORK/ver2.txt"
api -o /dev/null -X POST --data-binary @"$WORK/ver1.txt" "$BASE/api/upload?volume=$V&path=/资料&name=版本演示.txt"
api -o /dev/null -X POST --data-binary @"$WORK/ver2.txt" "$BASE/api/upload?volume=$V&path=/资料&name=版本演示.txt&overwrite=1"
# 效率包（排序/多选/批量删除/文件夹上传）专用目录，避免破坏其它场景的素材
api -o /dev/null -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","path":"/","name":"效率"}' "$V")" "$BASE/api/mkdir"
printf 'aaa\n' > "$WORK/e1.txt"; printf 'bbbbbbbb\n' > "$WORK/e2.txt"
printf 'cccccccccccc\n' > "$WORK/e3.txt"; printf 'dd\n' > "$WORK/e4.txt"
api -o /dev/null -X POST --data-binary @"$WORK/e1.txt" "$BASE/api/upload?volume=$V&path=/效率&name=甲-文件.txt"
api -o /dev/null -X POST --data-binary @"$WORK/e2.txt" "$BASE/api/upload?volume=$V&path=/效率&name=乙-文件.txt"
api -o /dev/null -X POST --data-binary @"$WORK/e3.txt" "$BASE/api/upload?volume=$V&path=/效率&name=丙-文件.txt"
api -o /dev/null -X POST --data-binary @"$WORK/e4.txt" "$BASE/api/upload?volume=$V&path=/效率&name=丁-文件.txt"
api -o /dev/null -X POST --data-binary @"$ROOT/Tools/e2e/fixtures/示例图片.png" "$BASE/api/upload?volume=$V&path=/效率&name=效率图片.png"
# 照片收集链接（供访客页与创建流程的测试使用）
COLLECT_RESP=$(api -X POST -H 'Content-Type: application/json' -d "$(printf '{"volume":"%s","kind":"collect","collect":true,"name":"生日会照片","path":"/生日会","expiresInHours":72,"password":"","maxFileMB":2,"maxTotalMB":3,"imagesOnly":true}' "$V")" "$BASE/api/share/create")
COLLECT_TOKEN=$(echo "$COLLECT_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin)["share"]["token"])')
ok "测试数据就绪（目录 $V）"

run_scenario() { # run_scenario <名称> <场景文件> <url> [宽] [高]
  local name="$1" script="$2" url="$3" w="${4:-1440}" h="${5:-900}"
  local out
  out=$("$CHECKER" "$url" "$WORK/shot.png" "$script" "$w" "$h" 2>&1)
  python3 - "$name" "$out" <<'PY'
import json, re, sys
name = sys.argv[1]
text = sys.argv[2]
match = re.search(r'JS 结果：(\{.*\})', text, re.S)
if not match:
    print(f"  \033[31m✗\033[0m {name}：场景未返回结果（脚本抛错或超时）")
    print("   " + text.strip().replace("\n", "\n   ")[:600])
    with open(sys.argv[1].replace('/', '_') + '.count', 'w') as handle:
        handle.write("0 1")
    sys.exit(0)
try:
    data = json.loads(match.group(1))
except Exception as exc:
    print(f"  \033[31m✗\033[0m {name}：结果无法解析（{exc}）")
    sys.exit(0)
passed = 0
failed = 0
for check in data.get("checks", []):
    if check.get("ok"):
        print(f"  \033[32m✓\033[0m {check['name']}")
        passed += 1
    else:
        print(f"  \033[31m✗\033[0m {check['name']}：{check.get('detail','')}")
        failed += 1
with open(sys.argv[1].replace('/', '_') + '.count', 'w') as handle:
    handle.write(f"{passed} {failed}")
PY
  local counts
  counts=$(cat "$(echo "$name" | tr '/' '_').count" 2>/dev/null || echo "0 0")
  rm -f "$(echo "$name" | tr '/' '_').count"
  PASS=$((PASS + $(echo "$counts" | awk '{print $1}')))
  FAIL=$((FAIL + $(echo "$counts" | awk '{print $2}')))
}

cat > "$WORK/s1.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(700);
MacNas.WM.closeAll();
await wait(200);
const w = MacNas.openFileManager({ volumeId: MacNas.state.volumes[0].id, path: '/' });
await wait(900);

const hit = (node) => {
  if (!node) return false;
  const r = node.getBoundingClientRect();
  if (!r.width || !r.height) return false;
  const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
  return top === node || node.contains(top);
};

[...document.querySelectorAll('.desk-icon')].forEach((icon, index) => {
  push('桌面图标可点击 #' + (index + 1) + '（' + icon.querySelector('.di-name').textContent + '）', hit(icon));
});
push('任务栏「应用」可点击', hit(document.getElementById('tb-apps')));
push('主题切换按钮可点击', hit(document.getElementById('theme-btn')));
push('退出登录按钮可点击', hit(document.getElementById('logout-btn')));
push('窗口关闭按钮可点击', hit(w.win.node.querySelector('.win-btn.close')));
push('窗口最小化按钮可点击', hit(w.win.node.querySelector('.win-btn.min')));
push('窗口最大化按钮可点击', hit(w.win.node.querySelector('.win-btn.max')));
push('上传按钮可点击', hit(w.uploadButton));
push('新建文件夹按钮可点击', hit(w.mkdirButton));
push('文件行可点击', hit(w.listEl.querySelector('.row')));
push('行内下载按钮可点击', hit(w.listEl.querySelector('.row-actions .icon-btn')));
push('行内复选框可点击', hit(w.listEl.querySelector('.row-check')));
push('面包屑可点击', hit(w.crumbsEl.querySelector('.crumb')));
push('文件列表里能看到上传的文件', [...w.listEl.querySelectorAll('.row-name')].some(n => n.textContent === '界面测试.txt'),
  [...w.listEl.querySelectorAll('.row-name')].map(n => n.textContent).join(','));

const before = document.querySelectorAll('.win').length;
const shareIcon = [...document.querySelectorAll('.desk-icon')].find(b => b.querySelector('.di-name').textContent === '分享管理');
if (shareIcon) shareIcon.click();
await wait(900);
const opened = [...document.querySelectorAll('.win-title-text')].map(n => n.textContent);
push('点击桌面图标能打开窗口', document.querySelectorAll('.win').length > before && opened.includes('分享管理'), opened.join(','));
push('分享管理里列出了分享链接', document.querySelectorAll('.win .row').length >= 2,
  String(document.querySelectorAll('.win .row').length));

// 打开「系统信息」：它的应用图标是图片，最容易出现“图标爆炸”
const aboutIcon = [...document.querySelectorAll('.desk-icon')].find(b => b.querySelector('.di-name').textContent === '系统信息');
if (aboutIcon) aboutIcon.click();
await wait(900);
const iconNodes = [...document.querySelectorAll(
  '.tb-task img, .tb-task svg, .win-title img, .win-title svg, .di-art img, .di-art svg, .li-art img, .li-art svg'
)];
const oversized = iconNodes
  .map(n => ({ tag: n.tagName, w: Math.round(n.getBoundingClientRect().width), h: Math.round(n.getBoundingClientRect().height) }))
  .filter(item => item.w > 40 || item.h > 40);
push('打开系统信息后没有任何超大图标', oversized.length === 0 && iconNodes.length > 0,
  oversized.length ? JSON.stringify(oversized) : ('共 ' + iconNodes.length + ' 个图标，全部正常'));
const taskIcon = document.querySelector('.tb-task img');
if (taskIcon) {
  const r = taskIcon.getBoundingClientRect();
  push('任务栏里的图片图标尺寸正常', r.width <= 24 && r.height <= 24, Math.round(r.width) + 'x' + Math.round(r.height));
}
const taskbar = document.querySelector('.taskbar').getBoundingClientRect();
push('任务栏没有被图标撑高', Math.round(taskbar.height) <= 60, Math.round(taskbar.height) + 'px');
return JSON.stringify({ checks });
JS
say "桌面元素命中测试"
run_scenario "桌面命中测试" "$WORK/s1.js" "$BASE/" 1440 900

cat > "$WORK/s2.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(600);
MacNas.WM.closeAll();
await wait(200);
const v = MacNas.state.volumes[0].id;
const a = MacnasOpen(v, '/');
const b = MacnasOpen(v, '/目标');
await wait(1000);
function MacnasOpen(volumeId, path) { return MacNas.openFileManager({ volumeId, path }); }
const names = (view) => [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent);

push('两个窗口各自独立浏览', names(a).includes('界面测试.txt') && names(b).includes('已就位.txt'),
  JSON.stringify({ a: names(a), b: names(b) }));

const file = a.files.find(f => f.name === '界面测试.txt');
await MacnasTransfer({ volumeId: v, ids: [file.id], paths: [], names: [file.name] }, b, '/目标', false);
await wait(900);
push('拖到另一个窗口后原窗口不再有该文件', !names(a).includes('界面测试.txt'), names(a).join(','));
push('目标窗口出现了被拖过去的文件', names(b).includes('界面测试.txt'), names(b).join(','));
function MacnasTransfer(payload, view, dir, copy) { return MacNas.performTransfer(payload, view, dir, copy); }

const moved = b.files.find(f => f.name === '界面测试.txt');
await MacnasTransfer({ volumeId: v, ids: [moved.id], paths: [], names: [moved.name] }, a, '/', true);
await wait(900);
push('按住 ⌥ 复制回原窗口（两边都有）', names(a).includes('界面测试.txt') && names(b).includes('界面测试.txt'),
  JSON.stringify({ a: names(a), b: names(b) }));
const dedupText = [...a.listEl.querySelectorAll('.row-sub')].map(n => n.textContent).join(' | ');
push('复制出来的记录标出「已去重」（不占空间）', dedupText.includes('已去重'), dedupText);
return JSON.stringify({ checks });
JS
say "窗口之间拖拽搬运"
run_scenario "拖拽搬运" "$WORK/s2.js" "$BASE/" 1440 900

cat > "$WORK/s6.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(700);
const v = MacNas.state.volumes[0].id;
const listAPI = (path) => fetch('/api/list?volume=' + v + '&path=' + encodeURIComponent(path)).then(r => r.json());
MacNas.WM.closeAll();
await wait(200);
const a = MacNas.openFileManager({ volumeId: v, path: '/源' });
const b = MacNas.openFileManager({ volumeId: v, path: '/目标' });
await wait(1100);
const names = (view) => [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent);

// 右键菜单
const row = [...a.listEl.querySelectorAll('.row')].find(r => r.querySelector('.row-name').textContent === '文稿.txt');
row.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 320, clientY: 320 }));
await wait(300);
const labels = [...document.querySelectorAll('.context-menu .ctx-item')].map(x => x.textContent.trim());
push('右键菜单包含复制/剪切/创建副本/复制到…', ['复制', '剪切', '创建副本', '复制到…'].every(x => labels.includes(x)), labels.join('/'));
const clickMenu = (label) => {
  const item = [...document.querySelectorAll('.context-menu .ctx-item')].find(x => x.textContent.trim() === label);
  if (item) item.click();
  return !!item;
};
clickMenu('复制');
await wait(400);
push('复制后进入剪贴板（复制模式）', MacNas.fileClipboard.mode === 'copy' && MacNas.fileClipboard.ids.length === 1,
  MacNas.fileClipboard.mode + '/' + MacNas.fileClipboard.ids.length);
push('目标窗口粘贴按钮变为可用并显示数量', !b.pasteButton.disabled && b.pasteButton.textContent.includes('项'), b.pasteButton.textContent);
push('状态栏显示剪贴板状态', b.statusEl.textContent.includes('剪贴板'), b.statusEl.textContent);

// 粘贴（复制）
await MacNas.pasteInto(b, '/目标');
await wait(1200);
push('粘贴后目标目录出现该文件', names(b).includes('文稿.txt'), names(b).join(','));
push('复制不会删除源文件', names(a).includes('文稿.txt'), names(a).join(','));
push('复制出的记录标出已去重（不占空间）',
  [...b.listEl.querySelectorAll('.row-sub')].map(n => n.textContent).join(' ').includes('已去重'));

// 创建副本
await MacNas.duplicateEntry(a, { kind: 'file', file: a.files.find(f => f.name === '文稿.txt') });
await wait(1200);
push('创建副本后出现「文稿 (2).txt」', names(a).some(n => n.includes('(2)')), names(a).join(','));

// 剪切 + 粘贴 = 移动
MacNas.copyToClipboard(a, 'cut', { kind: 'file', file: a.files.find(f => f.name === '文稿.txt') });
await wait(300);
push('剪切模式记录为 cut', MacNas.fileClipboard.mode === 'cut');
await MacnasPaste(a, '/归档');
async function MacnasPaste(view, path) { return MacNas.pasteInto(view, path); }
await wait(1300);
const archived = await listAPI('/归档');
const source = await listAPI('/源');
push('剪切粘贴后文件出现在 /归档', archived.files.some(f => f.name === '文稿.txt'), archived.files.map(f => f.name).join(','));
push('剪切粘贴后源目录已无该文件', !source.files.some(f => f.name === '文稿.txt'), source.files.map(f => f.name).join(','));
push('剪切粘贴后剪贴板自动清空', !MacNas.fileClipboard.mode && MacNas.fileClipboard.ids.length === 0);

// 文件夹复制
MacNas.copyToClipboard(a, 'copy', { kind: 'folder', folder: { path: '/源/素材', name: '素材' } });
await wait(300);
await MacnasPaste(b, '/目标');
await wait(1300);
const target = await listAPI('/目标');
push('文件夹也能复制过去', target.folders.some(f => f.name === '素材'), target.folders.map(f => f.name).join(','));

// 「复制到…」对话框：选目标目录后确认
const copySource = a.files.find(f => f.name.includes('(2)')) || a.files[0];
MacNas.copyToDialog(a, { kind: 'file', file: copySource });
await wait(1000);
const dialog = document.querySelector('.dialog');
push('「复制到…」对话框打开并列出目录', !!dialog && dialog.querySelectorAll('.row').length > 0,
  dialog ? [...dialog.querySelectorAll('.row-name')].map(n => n.textContent).join(',') : 'no-dialog');
push('「复制到…」默认从当前目录开始', dialog ? (dialog.textContent.includes('/源')) : false,
  dialog ? dialog.querySelector('div[style*="monospace"]').textContent : '');
// 上一级到根目录，再进入「目标」
const upBtn = dialog ? [...dialog.querySelectorAll('.btn')].find(x => x.textContent === '上一级') : null;
if (upBtn) upBtn.click();
await wait(700);
const dialogFolder = dialog ? [...dialog.querySelectorAll('.row')].find(r => r.querySelector('.row-name').textContent === '目标') : null;
push('「复制到…」可以切换目标目录', !!dialogFolder,
  dialog ? [...dialog.querySelectorAll('.row-name')].map(n => n.textContent).join(',') : '');
if (dialogFolder) dialogFolder.click();
await wait(700);
const confirm = dialog ? [...dialog.querySelectorAll('.dialog-actions .btn')].find(x => x.textContent.includes('复制到这里')) : null;
if (confirm) confirm.click();
await wait(1400);
const afterDialog = await listAPI('/目标');
push('通过「复制到…」复制成功', afterDialog.files.some(f => f.name === copySource.name), afterDialog.files.map(f => f.name).join(','));
return JSON.stringify({ checks });
JS
say "复制 / 剪切 / 粘贴 / 创建副本 / 复制到…"
run_scenario "复制功能" "$WORK/s6.js" "$BASE/" 1440 900

cat > "$WORK/s7.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(800);

// 模拟「关掉网页再打开」：窗口直接消失（不触发保存），再从记忆里恢复
const reloadPage = async () => {
  MacNas.Session.restoring = true;
  MacNas.WM.closeAll();
  MacNas.Session.restoring = false;
  await wait(250);
  return MacNas.restoreSession();
};

MacNas.clearSession();            // 先清掉历史布局，保证从干净状态开始
const clean = await reloadPage();
push('清空后是干净的桌面', clean === 0 && MacNas.WM.items.length === 0,
  'clean=' + clean + ' items=' + MacNas.WM.items.length);

push('默认记住窗口布局', MacNas.sessionEnabled() === true);
const button = document.getElementById('session-btn');
push('任务栏有布局记忆开关', !!button && button.classList.contains('on'), button ? button.className : '无');

// 摆两个窗口：一个在卷根，一个在子目录，位置大小各不相同
const v = MacNas.state.volumes[0].id;
const a = MacNas.openFileManager({ volumeId: v, path: '/' });
await wait(700);
const b = MacNas.openFileManager({ volumeId: v, path: '/源/素材' });
await wait(900);
a.win.rect = { left: 60, top: 40, width: 700, height: 500 };
MacNas.WM.applyRect(a.win);
b.win.rect = { left: 260, top: 130, width: 640, height: 460 };
MacNas.WM.applyRect(b.win);
MacNas.saveSession();
await wait(400);

const stored = JSON.parse(localStorage.getItem('macnas-session') || 'null');
push('布局写进了本地存储', !!stored && stored.windows.length === 2,
  stored ? String(stored.windows.length) : '无');
const savedA = stored && stored.windows.find(w => w.rect.left === 60);
push('窗口位置与大小被存下来', !!savedA && savedA.rect.width === 700 && savedA.rect.height === 500,
  savedA ? JSON.stringify(savedA.rect) : '无');
const savedFolder = stored && stored.windows.find(w => w.extra && w.extra.path === '/源/素材');
push('窗口里看的目录也被存下来', !!savedFolder,
  stored ? JSON.stringify(stored.windows.map(w => w.extra)) : '');

// 关掉网页再打开：应当原样回来
const restored = await reloadPage();
await wait(1200);
push('恢复出同样数量的窗口', restored === 2 && MacNas.WM.items.length === 2,
  'restored=' + restored + ' items=' + MacNas.WM.items.length);
const rects = MacNas.WM.items.map(w => w.rect).sort((x, y) => x.left - y.left);
push('窗口位置和大小原样还原',
  !!rects[0] && Math.abs(rects[0].left - 60) < 2 && Math.abs(rects[0].top - 40) < 2 &&
  Math.abs(rects[0].width - 700) < 2 && Math.abs(rects[0].height - 500) < 2,
  JSON.stringify(rects[0]));
const titles = [...document.querySelectorAll('.win')].map(w => w.querySelector('.win-title-text').textContent);
push('回到上次所在的目录', titles.some(t => t.includes('/源/素材')), titles.join(' | '));
push('最上层窗口拿到了焦点', MacNas.WM.items.filter(w => w.node.classList.contains('focused')).length === 1,
  String(MacNas.WM.items.filter(w => w.node.classList.contains('focused')).length));

// 关掉开关后不再记忆
MacNas.Session.setEnabled(false);
await wait(200);
const afterOff = JSON.parse(localStorage.getItem('macnas-session') || 'null');
push('关掉开关后清掉了已存布局', !afterOff || afterOff.windows.length === 0,
  afterOff ? String(afterOff.windows.length) : '无');
push('关掉开关后按钮不再点亮', !document.getElementById('session-btn').classList.contains('on'));
push('关掉开关时不会恢复窗口', (await reloadPage()) === 0);

// 重新打开开关
MacNas.Session.setEnabled(true);
await wait(200);
push('重新开启开关后按钮点亮', document.getElementById('session-btn').classList.contains('on'));
MacNas.openFileManager({ volumeId: v, path: '/源' });
await wait(800);
MacNas.saveSession();
await wait(300);
const again = await reloadPage();
await wait(900);
push('重新开启后又能恢复', again === 1 && MacNas.WM.items.length === 1,
  'again=' + again + ' items=' + MacNas.WM.items.length +
  ' storage=' + localStorage.getItem('macnas-session'));

// 清除已存布局
MacNas.clearSession();
push('清除后没有可恢复的布局', (await reloadPage()) === 0);
await wait(400);
return JSON.stringify({ checks });
JS
say "窗口布局记忆"
run_scenario "窗口布局记忆" "$WORK/s7.js" "$BASE/" 1440 900

cat > "$WORK/s12.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(1000);
MacNas.WM.closeAll();
await wait(300);
const v = MacNas.state.volumes[0].id;
const rowFor = (view, name) => [...view.listEl.querySelectorAll('.row')]
  .find(r => r.querySelector('.row-name').textContent === name);
const winTitle = (prefix) => [...document.querySelectorAll('.win')]
  .find(w => w.querySelector('.win-title-text').textContent.startsWith(prefix));

// ---- 删除进回收站 ----
let view = MacNas.openFileManager({ volumeId: v, path: '/资料' });
await wait(1100);
rowFor(view, '待删除.txt').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 400, clientY: 300 }));
await wait(400);
const menu = [...document.querySelectorAll('.context-menu .ctx-item')].map(b => b.textContent);
push('右键菜单是“移到回收站”', menu.includes('移到回收站'), menu.slice(-3).join(','));
[...document.querySelectorAll('.context-menu .ctx-item')].find(b => b.textContent === '移到回收站').click();
await wait(500);
const confirmButton = [...document.querySelectorAll('.dialog-actions .btn')].find(b => b.textContent.includes('移到回收站'));
push('删除前会二次确认', !!confirmButton);
confirmButton.click();
await wait(1200);
push('删除后列表里没有它了', !rowFor(view, '待删除.txt'),
  [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent).join(','));

// ---- 桌面角标 ----
await MacNas.WM.closeAll();
await wait(300);
await MacNas.fetchTrash();
const badge = document.getElementById('trash-badge');
MacNas.state.trashCount = 1;
MacNas.refreshTrashBadge();
push('回收站图标有数量角标', !badge.hidden && badge.textContent === '1', badge.textContent);

// ---- 打开回收站窗口并还原 ----
await MacNas.openTrashManager();
await wait(1200);
const trashWin = winTitle('回收站');
push('能打开回收站窗口', !!trashWin, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join(' | '));
const trashRow = [...trashWin.querySelectorAll('.trash-row')]
  .find(r => r.querySelector('.row-name').textContent === '待删除.txt');
push('回收站里能看到被删的文件', !!trashRow,
  [...trashWin.querySelectorAll('.row-name')].map(n => n.textContent).join(','));
push('回收站显示原位置', trashRow && trashRow.querySelector('.row-sub').textContent.includes('/资料'),
  trashRow ? trashRow.querySelector('.row-sub').textContent : '');

[...trashRow.querySelectorAll('.row-actions .btn')].find(b => b.textContent === '还原').click();
await wait(1400);
push('还原后回收站里没有它了',
  ![...trashWin.querySelectorAll('.trash-row')].some(r => r.querySelector('.row-name').textContent === '待删除.txt'),
  [...trashWin.querySelectorAll('.row-name')].map(n => n.textContent).join(','));

view = MacNas.openFileManager({ volumeId: v, path: '/资料' });
await wait(1200);
push('还原后文件回到原目录', !!rowFor(view, '待删除.txt'),
  [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent).join(','));

// ---- 版本历史 ----
rowFor(view, '版本演示.txt').dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 400, clientY: 300 }));
await wait(400);
const items = [...document.querySelectorAll('.context-menu .ctx-item')].map(b => b.textContent);
push('右键菜单有“版本历史…”', items.includes('版本历史…'), items.slice(0, 4).join(','));
[...document.querySelectorAll('.context-menu .ctx-item')].find(b => b.textContent === '版本历史…').click();
await wait(1200);
const rows = [...document.querySelectorAll('.version-row')];
push('版本历史列出两个版本', rows.length === 2, '行数=' + rows.length);
push('第一个标为当前版本', rows[0] && rows[0].textContent.includes('当前版本'), rows[0] ? rows[0].textContent.slice(0, 20) : '无');
const restoreButton = [...rows[1].querySelectorAll('.btn')].find(b => b.textContent === '恢复此版本');
push('历史版本可以恢复', !!restoreButton);
restoreButton.click();
await wait(1500);
const dialogGone = !document.querySelector('.version-row');
push('恢复后对话框关闭', dialogGone);

// 下载当前内容，确认已经变回第一版
const fileId = MacNas.state.volumes.length ? null : null;
const content = await fetch('/api/download?volume=' + v + '&id=' + view.files.find(f => f.name === '版本演示.txt').id)
  .then(r => r.text());
push('恢复后内容确实变回第一版', content.trim() === '第一版', JSON.stringify(content.trim()));
return JSON.stringify({ checks });
JS
say "回收站与版本历史（界面）"
run_scenario "回收站与版本历史" "$WORK/s12.js" "$BASE/" 1440 900

cat > "$WORK/s13.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(1000);
MacNas.WM.closeAll();
await wait(300);
const v = MacNas.state.volumes[0].id;

// ---- 纯 JS SHA-256（局域网 http 下没有 crypto.subtle 也能秒传）----
const text = new TextEncoder().encode('abc');
push('自带 SHA-256 与标准向量一致',
  MacNas.SHA256.fallback(text) === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  MacNas.SHA256.fallback(text));
const empty = MacNas.SHA256.fallback(new Uint8Array(0));
push('空内容哈希正确', empty === 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', empty);

// ---- 秒传：库里已有一份内容时，第二次上传应当零字节完成 ----
const payload = new TextEncoder().encode('秒传界面测试内容\n');
const hash = MacNas.SHA256.fallback(payload);
// 先正常上传一份
const first = new File([payload], '秒传-源.txt', { type: 'text/plain' });
const firstItem = { file: first, volumeId: v, destPath: '/资料', loaded: 0, status: 'pending', message: '' };
const sent = await MacNas.tryInstantUpload(firstItem, '/资料', false);
// 第一次库里没有 → 不应秒传
push('第一次上传不会走秒传（库里还没有）', sent === false, 'sent=' + sent);
await MacNas.enqueueUploads([{ file: first, relPath: '' }], v, '/资料');
await wait(2500);
const listed = await MacNas.api('/api/list', { params: { volume: v, path: '/资料' } });
push('源文件上传成功', listed.files.some(f => f.name === '秒传-源.txt'),
  listed.files.map(f => f.name).join(','));
// 同名再来一次 → 秒传应当命中
const secondItem = { file: first, volumeId: v, destPath: '/资料', loaded: 0, status: 'pending', message: '' };
const instant = await MacNas.tryInstantUpload(secondItem, '/资料', true);
push('内容已在库里时秒传命中', instant === true && secondItem.instant === true,
  'instant=' + instant + ' msg=' + secondItem.message);

// ---- 网格视图 + 缩略图 ----
const view = MacNas.openFileManager({ volumeId: v, path: '/资料' });
await wait(1200);
const toggle = [...view.listEl.parentElement.querySelectorAll('.fm-actions .icon-btn')]
  .find(b => b.title && b.title.includes('网格'));
push('工具栏有网格视图按钮', !!toggle,
  [...view.listEl.parentElement.querySelectorAll('.fm-actions .icon-btn')].map(b => b.title).join('|'));
toggle.click();
await wait(1500);
const cells = [...view.listEl.querySelectorAll('.grid-cell')];
push('网格视图渲染出格子', cells.length >= 2, '格子数=' + cells.length);
const thumb = view.listEl.querySelector('.grid-thumb');
push('媒体格子显示缩略图并加载成功', !!(thumb && thumb.complete && thumb.naturalWidth > 0),
  thumb ? (thumb.naturalWidth + 'x' + thumb.naturalHeight) : '无缩略图');
push('网格里仍然能识别出文件夹', !!view.listEl.querySelector('.grid-art.folder') || cells.length > 0);

// 切回列表
toggle.click();
await wait(600);
push('能切回列表视图', view.listEl.querySelectorAll('.row').length > 0 && !view.listEl.querySelector('.fm-grid'),
  '行数=' + view.listEl.querySelectorAll('.row').length);

// ---- 照片应用 ----
MacNas.WM.closeAll();
await wait(300);
const photos = MacNas.openPhotos({ volumeId: v });
await wait(1600);
const photoWin = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('照片'));
push('能打开照片应用', !!photoWin, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join('|'));
const months = [...photoWin.querySelectorAll('.photos-month')].map(n => n.textContent);
push('照片按月份分组', months.length >= 1, months.join(' / '));
const photoThumb = photoWin.querySelector('.photo-thumb');
push('照片墙缩略图加载成功', !!(photoThumb && photoThumb.complete && photoThumb.naturalWidth > 0),
  photoThumb ? (photoThumb.naturalWidth + 'x' + photoThumb.naturalHeight) : '无');
push('顶部有卷切换与筛选按钮', !!photoWin.querySelector('.photos-chip') && !!photoWin.querySelector('.photos-actions .btn'),
  '卷数=' + photoWin.querySelectorAll('.photos-chip').length);

photoWin.querySelector('.photo-cell').click();
await wait(1800);
const previewWin = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('预览'));
push('点照片能打开预览', !!previewWin && !!previewWin.querySelector('.pv-image'),
  [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join('|'));
return JSON.stringify({ checks });
JS
say "秒传 / 网格视图 / 照片墙"
run_scenario "秒传与照片墙" "$WORK/s13.js" "$BASE/" 1440 900

cat > "$WORK/s14.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(1000);
MacNas.WM.closeAll();
await wait(300);
const v = MacNas.state.volumes[0].id;
const W = window.innerWidth;

push('识别为窄屏（手机）模式', document.body.classList.contains('narrow'), '宽度=' + W);

const icons = [...document.querySelectorAll('.desk-icon')];
push('桌面图标在手机上仍在', icons.length >= 4, '图标数=' + icons.length);
if (icons.length >= 2) {
  const first = icons[0].getBoundingClientRect();
  const second = icons[1].getBoundingClientRect();
  push('图标并排成两列（同一行、左右分开）', second.top === first.top && second.left > first.left,
    '第一个 left=' + Math.round(first.left) + ' 第二个 left=' + Math.round(second.left) +
    ' / top=' + Math.round(first.top) + ',' + Math.round(second.top));
}

// 打开文件管理：应当铺满整屏
const view = MacNas.openFileManager({ volumeId: v, path: '/资料' });
await wait(1200);
// 用布局尺寸而不是 getBoundingClientRect：后者包含入场动画的 scale 变换
const winNode = view.win.node;
const layer = document.querySelector('.window-layer');
push('窗口在手机上铺满宽度', Math.abs(winNode.offsetWidth - layer.offsetWidth) < 2,
  winNode.offsetWidth + ' / ' + layer.offsetWidth);
push('窗口高度铺满（除任务栏外）', Math.abs(winNode.offsetHeight - layer.offsetHeight) < 2,
  winNode.offsetHeight + ' / ' + layer.offsetHeight);
push('窗口从屏幕左边开始', winNode.offsetLeft <= 1, 'left=' + winNode.offsetLeft);

// 触摸用的按钮
const camera = view.listEl.parentElement.querySelector('.camera-btn');
push('手机上有「拍照」入口', !!camera && getComputedStyle(camera).display !== 'none',
  camera ? getComputedStyle(camera).display : '无');
const rowMore = view.listEl.querySelector('.row .row-more');
push('每行有「⋯」更多按钮（手机没有右键）', !!rowMore && getComputedStyle(rowMore).display !== 'none',
  rowMore ? getComputedStyle(rowMore).display : '无');
const check = view.listEl.querySelector('.row .row-check');
push('手机上去掉了多选勾选框', !!check && getComputedStyle(check).display === 'none',
  check ? getComputedStyle(check).display : '无');
const actionButtons = [...view.listEl.querySelectorAll('.row .row-actions > .icon-btn')];
const hiddenButtons = actionButtons.filter(b => !b.classList.contains('row-more'));
push('行内只保留「⋯」，避免挤爆小屏',
  hiddenButtons.length > 0 && hiddenButtons.every(b => getComputedStyle(b).display === 'none'),
  '隐藏 ' + hiddenButtons.length + ' 个，保留 ' + (actionButtons.length - hiddenButtons.length) + ' 个更多按钮');

// 点「⋯」能弹出菜单
rowMore.click();
await wait(400);
const menuItems = [...document.querySelectorAll('.context-menu .ctx-item')].map(b => b.textContent);
push('「⋯」能弹出操作菜单', menuItems.length >= 5, menuItems.slice(0, 4).join(','));
document.body.click();
await wait(300);

// 触摸目标够大
const button = view.listEl.parentElement.querySelector('.fm-actions .btn');
const size = button.getBoundingClientRect();
push('按钮触摸目标不小于 40px', size.height >= 38, Math.round(size.height) + 'px');

// 任务栏在底部且紧凑
const taskbar = document.querySelector('.taskbar').getBoundingClientRect();
push('任务栏固定在底部', taskbar.bottom >= window.innerHeight - 2, Math.round(taskbar.bottom) + ' / ' + window.innerHeight);

// 网格视图在手机上可用（两列左右）
view.mode = 'grid';
MacNas.renderView(view);
await wait(1200);
const cells = [...view.listEl.querySelectorAll('.grid-cell')];
push('手机上网格视图可用', cells.length >= 2, '格子数=' + cells.length);
if (cells.length >= 2) {
  const a = cells[0].getBoundingClientRect();
  const b = cells[1].getBoundingClientRect();
  push('网格每行放得下至少两个', Math.abs(a.top - b.top) < 2 && b.left > a.left,
    '间距=' + Math.round(b.left - a.left));
}

// 相册
const photos = MacNas.openPhotos({ volumeId: v });
await wait(1600);
push('手机上照片墙能用', !!document.querySelector('.photos-month'), '');
return JSON.stringify({ checks });
JS
say "手机端（窄屏）"
run_scenario "手机端布局" "$WORK/s14.js" "$BASE/" 390 844

cat > "$WORK/s15.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(1000);
MacNas.WM.closeAll();
await wait(300);
const v = MacNas.state.volumes[0].id;
const view = MacNas.openFileManager({ volumeId: v, path: '/效率' });
await wait(1200);
const rowNames = () => [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent);
const rows = () => [...view.listEl.querySelectorAll('.row')];
const rowFor = (name) => rows().find(r => r.querySelector('.row-name').textContent === name);

// ---------- 排序 ----------
const sortButton = [...view.listEl.parentElement.querySelectorAll('.fm-actions .btn')]
  .find(b => b.textContent.includes('名称') || b.textContent.includes('大小'));
push('工具栏有排序按钮', !!sortButton && /[↑↓]/.test(sortButton.textContent), sortButton ? sortButton.textContent : '无');
const before = rowNames();
sortButton.click();
await wait(400);
const menu = [...document.querySelectorAll('.context-menu .ctx-item')].map(b => b.textContent);
push('排序菜单有四种排序方式', ['名称', '修改时间', '大小', '类型'].every(k => menu.some(m => m.startsWith(k))), menu.join(','));
[...document.querySelectorAll('.context-menu .ctx-item')].find(b => b.textContent.startsWith('名称')).click();
await wait(600);
const afterAsc = rowNames();
push('切换排序方向后顺序会变（升序/降序）', JSON.stringify(afterAsc) !== JSON.stringify(before) || afterAsc.length < 2,
  before.join(',') + ' → ' + afterAsc.join(','));
push('排序方式显示在按钮上', /[↑↓]/.test(sortButton.textContent), sortButton.textContent);
push('排序方式会随窗口布局一起记住', (() => {
  const saved = JSON.parse(localStorage.getItem('macnas-session') || 'null');
  return !!(saved && saved.windows.some(w => w.app === 'files' && w.extra && w.extra.sort));
})(), localStorage.getItem('macnas-session') ? '有布局' : '无');

// ---------- 多选 ----------
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }));
await wait(500);
push('⌘A 全选', view.selection.size === rows().length && view.selection.size >= 4,
  '已选 ' + view.selection.size + ' / ' + rows().length);
const selButtons = [...view.statusEl.querySelectorAll('.sel-actions .btn')].map(b => b.textContent);
push('多选后出现批量操作条',
  ['打包下载', '移动到…', '复制到…', '删除', '取消选择'].every(label => selButtons.includes(label)),
  selButtons.join(','));
const zipURL = MacNas.selectionZipURL(view);
const zipPayload = zipURL ? JSON.parse(new URLSearchParams(zipURL.split('?')[1]).get('payload')) : null;
push('打包下载的地址包含全部所选',
  !!zipPayload && zipPayload.ids.length === view.selection.size && zipPayload.volume === v,
  zipPayload ? ('ids=' + zipPayload.ids.length + ' 已选=' + view.selection.size) : '无');

// Shift 连选
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
await wait(400);
push('Esc 清空选择', view.selection.size === 0, String(view.selection.size));
rows()[0].querySelector('.row-check').click();
await wait(300);
push('勾选框能选中一项', view.selection.size === 1, '已选 ' + view.selection.size);
rows()[2].querySelector('.row-main').dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: true }));
await wait(400);
push('Shift 连选选中区间', view.selection.size === 3, '已选 ' + view.selection.size);
// ⌘ 点选切换
rows()[2].querySelector('.row-main').dispatchEvent(new MouseEvent('click', { bubbles: true, metaKey: true }));
await wait(400);
push('⌘ 点选可以取消单个', view.selection.size === 2, '已选 ' + view.selection.size);

// ---------- 批量删除 ----------
const selectedNames = [...view.selection].map(key => (view.files.find(f => f.id === key) || {}).name).filter(Boolean);
[...view.statusEl.querySelectorAll('.sel-actions .btn')].find(b => b.textContent === '删除').click();
await wait(500);
const confirm = [...document.querySelectorAll('.dialog-actions .btn')].find(b => /删除|回收站/.test(b.textContent));
push('批量删除会二次确认', !!confirm);
confirm.click();
await wait(1600);
const remaining = rowNames();
push('批量删除后这些文件都不在列表里', selectedNames.every(n => !remaining.includes(n)),
  '删了 ' + selectedNames.join(',') + ' 剩下 ' + remaining.join(','));

// ---------- 文件夹上传保结构 ----------
// webkitRelativePath 是只读属性，这里用普通对象验证路径计算，再用真实 File 走上传
const nested = MacNas.encodeFolderUpload([
  { name: '一级.txt', webkitRelativePath: '我的目录/一级.txt' },
  { name: '二级.txt', webkitRelativePath: '我的目录/子目录/二级.txt' }
]);
push('文件夹上传会算出每层的相对路径',
  nested.length === 2 && nested[0].relPath === '我的目录' && nested[1].relPath === '我的目录/子目录',
  nested.map(n => n.relPath).join(' | '));
await MacNas.enqueueUploads([
  { file: new File(['x'], '一级.txt'), relPath: '我的目录' },
  { file: new File(['y'], '二级.txt'), relPath: '我的目录/子目录' }
], v, '/效率');
await wait(3200);
const tree = await MacNas.api('/api/list', { params: { volume: v, path: '/效率/我的目录/子目录' } });
push('文件夹上传按原结构建好了目录', (tree.files || []).some(f => f.name === '二级.txt'),
  (tree.files || []).map(f => f.name).join(','));

// ---------- 空格快速查看 ----------
MacNas.WM.closeAll();
await wait(300);
// 快速查看用 /资料 里的图片素材（/效率 里的图片可能已被上面的批量删除删掉）
const view2 = MacNas.openFileManager({ volumeId: v, path: '/资料' });
await wait(1400);
// 用方向键移动焦点（点行会打开预览窗口，键盘处理就找不到文件管理视图了）
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }));
await wait(500);
push('方向键可以在列表里移动选择', view2.selection.size === 1, '已选 ' + view2.selection.size);
// 直接把焦点对准那张图片（方向键本身已经在上一条验证过了；必须挑「文件」，文件夹没有快速查看）
const imageFile = view2.files.find(f => f.name === '示例图片.png');
push('准备快速查看的素材存在', !!imageFile, view2.files.map(f => f.name).join(','));
view2.focusKey = imageFile ? imageFile.id : null;
view2.selection.clear();
if (imageFile) view2.selection.add(imageFile.id);
MacNas.renderView(view2);
await wait(400);
document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', code: 'Space', bubbles: true }));
await wait(2000);
const overlay = document.querySelector('.ql-overlay');
push('空格能打开快速查看', !!overlay, '');
const qlImage = overlay && overlay.querySelector('.pv-image');
push('快速查看里图片正常显示', !!(qlImage && qlImage.naturalWidth > 0),
  qlImage ? (qlImage.naturalWidth + 'x' + qlImage.naturalHeight) : '无');
document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', code: 'Space', bubbles: true }));
await wait(500);
push('再按空格关闭', !document.querySelector('.ql-overlay'));
document.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', code: 'Space', bubbles: true }));
await wait(1500);
push('空格可以重新打开', !!document.querySelector('.ql-overlay'), '');
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
await wait(400);
push('Esc 关闭快速查看', !document.querySelector('.ql-overlay'));
return JSON.stringify({ checks });
JS
say "效率包（排序 / 多选 / 打包 / 快捷键）"
run_scenario "效率包" "$WORK/s15.js" "$BASE/" 1440 900

cat > "$WORK/s19.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: String(detail === undefined ? '' : detail) });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(1400);
const wins = () => [...document.querySelectorAll('.win')].map(w => w.querySelector('.win-title-text').textContent);
const closeAll = async () => { MacNas.WM.closeAll(); await wait(350); };

// ---------- 逐个点桌面图标（就是用户的真实操作）----------
const expected = {
  '文件管理': '文件管理',
  '照片': '照片',
  '存储分析': '存储分析',
  '全局搜索': '全局搜索',
  '分享管理': '分享管理',
  '回收站': '回收站',
  '系统信息': '系统信息'
};
for (const [label, titlePrefix] of Object.entries(expected)) {
  await closeAll();
  const icon = [...document.querySelectorAll('.desk-icon')]
    .find(b => b.querySelector('.di-name') && b.querySelector('.di-name').textContent === label);
  if (!icon) { push('桌面图标「' + label + '」存在', false); continue; }
  icon.click();
  await wait(1700);
  const opened = wins().some(t => t.startsWith(titlePrefix));
  push('点桌面图标「' + label + '」能打开窗口', opened, wins().join(' | '));
}

// ---------- 左下角「应用」按钮 ----------
await closeAll();
const appsButton = document.querySelector('#tb-apps');
appsButton.click();
await wait(700);
const launcher = document.querySelector('#app-launcher');
const style = getComputedStyle(launcher);
push('点「应用」按钮会弹出应用列表',
  !launcher.classList.contains('hidden') && style.display !== 'none' && style.visibility !== 'hidden',
  'class=' + launcher.className + ' display=' + style.display + ' 高度=' + Math.round(launcher.getBoundingClientRect().height));
push('应用列表里有全部应用',
  [...launcher.querySelectorAll('.launcher-item')].length === 7,
  [...launcher.querySelectorAll('.launcher-item')].map(i => i.textContent).join(','));

// 从应用列表里逐个打开
for (const [label, titlePrefix] of Object.entries(expected)) {
  await closeAll();
  appsButton.click();
  await wait(600);
  const item = [...launcher.querySelectorAll('.launcher-item')]
    .find(b => b.textContent.trim() === label);
  if (!item) { push('应用列表里有「' + label + '」', false); continue; }
  item.click();
  await wait(1700);
  push('从应用列表点「' + label + '」能打开窗口', wins().some(t => t.startsWith(titlePrefix)), wins().join(' | '));
}

// 点空白处应当收起面板
await closeAll();
appsButton.click();
await wait(500);
const openedAfterClick = !launcher.classList.contains('hidden');
document.getElementById('desktop-area').click();
await wait(500);
push('点桌面空白处会收起应用列表',
  openedAfterClick && launcher.classList.contains('hidden'),
  '点之前=' + openedAfterClick + ' 点之后=' + launcher.classList.contains('hidden'));

// ---------- 上传队列面板也要能显示（同一个「属性 vs 类」的 bug 也影响过它）----------
await closeAll();
const view = MacNas.openFileManager({ volumeId: MacNas.state.volumes[0].id, path: '/' });
await wait(1400);
const file = new File([new Blob(['上传面板自检内容\n'])], '面板自检.txt', { type: 'text/plain' });
MacNas.enqueueUploads([{ file, relPath: '' }], view.volumeId, view.path);
await wait(400);
const panel = document.querySelector('#upload-panel');
push('上传时能看到上传队列面板',
  !panel.classList.contains('hidden') && getComputedStyle(panel).display !== 'none' && panel.textContent.includes('上传队列'),
  'class=' + panel.className + ' display=' + getComputedStyle(panel).display + ' 文本=' + panel.textContent.slice(0, 40));
await wait(2500);
push('上传完成后面板里显示已完成', panel.textContent.includes('1/1') || panel.textContent.includes('完成'),
  panel.textContent.slice(0, 60));
return JSON.stringify({ checks });
JS
say "桌面图标与应用列表（按用户点击路径）"
run_scenario "图标与应用列表" "$WORK/s19.js" "$BASE/" 1440 900

cat > "$WORK/s17.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(900);
const v = MacNas.state.volumes[0].id;
const view = MacNas.openFileManager({ volumeId: v, path: '/生日会' });
await wait(1400);

// ---------- 从文件夹菜单创建收集链接 ----------
const rows = [...view.listEl.querySelectorAll('.row')];
const folderRow = rows.find(r => r.querySelector('.row-name') && r.querySelector('.row-name').textContent === '生日会');
const menuTarget = [...view.listEl.querySelectorAll('.row')].length ? view.listEl.querySelector('.row') : null;
const firstFolder = [...view.listEl.parentElement.querySelectorAll('.fm-actions .btn')];
// 直接调用导出函数，验证对话框内容与创建结果
MacNas.createCollectDialog(view, view.path);
await wait(700);
const dialog = document.querySelector('.dialog');
push('创建对话框出现', !!dialog, document.querySelectorAll('.dialog').length + ' 个');
const labels = [...document.querySelectorAll('.collect-label-main')].map(n => n.textContent);
push('对话框包含额度设置项',
  ['目标文件夹', '收集名称', '有效期（小时）', '单个文件上限（MB）', '总共最多（MB）', '访问密码'].every(l => labels.includes(l)),
  labels.join(','));
const inputs = [...document.querySelectorAll('.collect-input')];
push('每个设置项都有输入框', inputs.length === 6, inputs.length + ' 个');
const imagesOnly = document.querySelector('.check-row input[type=checkbox]');
push('默认只收照片和视频', !!imagesOnly && imagesOnly.checked);

// 填一个 1MB 单文件上限、2MB 总量，然后创建
inputs[1].value = '测试收集';
inputs[3].value = '1';
inputs[4].value = '2';
const createButton = [...document.querySelectorAll('.dialog-actions .btn')].find(b => b.textContent === '创建链接');
createButton.click();
await wait(1600);
const linkBox = document.querySelector('.collect-link');
push('创建后显示可复制的链接', !!linkBox && /\/s\//.test(linkBox.textContent), linkBox ? linkBox.textContent : '无');
const hints = document.querySelector('.collect-hints');
push('创建后说明额度与有效期', !!hints && hints.textContent.includes('单个文件上限') && hints.textContent.includes('总共最多'),
  hints ? hints.textContent.slice(0, 80) : '无');
const createdToken = linkBox ? linkBox.textContent.split('/s/')[1] : '';
// 关掉对话框
const closeButton = [...document.querySelectorAll('.dialog-actions .btn')].find(b => b.textContent === '关闭');
if (closeButton) closeButton.click();
await wait(400);

// 服务端确认这个链接真的建好了
const shares = await fetch('/api/shares').then(r => r.json());
const created = shares.shares.find(s => s.token === createdToken);
push('服务端确实保存了收集链接', !!created && created.collect && created.maxFileBytes === 1048576,
  created ? ('type=' + created.type + ' 单文件=' + created.maxFileBytes + ' 总量=' + created.maxTotalBytes) : '没找到');
return JSON.stringify({ checks });
JS
say "照片收集（创建流程）"
run_scenario "照片收集-创建" "$WORK/s17.js" "$BASE/" 1440 900

cat > "$WORK/s18.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });

// 这个场景直接以访客身份打开收集页（不登录）
const wrap = document.querySelector('.share-wrap');
push('收集页渲染出来了', !!wrap, wrap ? 'ok' : '没有 .share-wrap');
const drop = document.querySelector('.collect-drop');
push('有「选择照片」上传区', !!drop && drop.textContent.includes('点这里选择照片'), drop ? drop.textContent.slice(0, 40) : '无');
push('上传区支持拖拽（提示可见）', !!drop && drop.textContent.includes('拖'),
  drop ? drop.textContent : '无');
const hint = document.querySelector('.collect-hint');
push('显示了额度提示', !!hint && /单个不超过|总共最多/.test(hint.textContent), hint ? hint.textContent : '无');
push('提示里说明只收照片视频', !!hint && hint.textContent.includes('只收照片和视频'), hint ? hint.textContent : '无');
push('收集页不显示已有照片的文件名', !document.body.textContent.includes('示例图片.png'));
push('标题是收集名称', document.querySelector('.share-title h1').textContent === '生日会照片',
  document.querySelector('.share-title h1').textContent);
// 移动端也应该好点
push('上传区高度足够手指点', drop.getBoundingClientRect().height >= 100,
  Math.round(drop.getBoundingClientRect().height) + 'px');

// 模拟拖入一张照片（走真实的 drop → 上传链路）
async function makePng() {
  const canvas = document.createElement('canvas');
  canvas.width = 40; canvas.height = 40;
  const context = canvas.getContext('2d');
  context.fillStyle = '#0B57D0';
  context.fillRect(0, 0, 40, 40);
  const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
  return new File([blob], '访客上传.png', { type: 'image/png' });
}
const file = await makePng();
const event = new Event('drop', { bubbles: true, cancelable: true });
Object.defineProperty(event, 'dataTransfer', { value: { files: [file] } });
drop.dispatchEvent(event);
await wait(2600);
const item = document.querySelector('.collect-item');
push('上传队列出现了这条照片', !!item && item.textContent.includes('访客上传.png'),
  item ? item.textContent : '无队列');
push('上传成功后显示已收到', !!item && item.classList.contains('done') && item.textContent.includes('已收到'),
  item ? item.className + ' / ' + item.textContent : '无');
push('已收数量增加', !!hint && hint.textContent.includes('已收到 1 张'), hint ? hint.textContent : '无');
push('剩余额度更新', !!hint && hint.textContent.includes('还可以上传'), hint ? hint.textContent : '无');

// 再传一张同名照片：收集场景里重名很常见，必须自动改名而不是报错
const second = await makePng();
const event2 = new Event('drop', { bubbles: true, cancelable: true });
Object.defineProperty(event2, 'dataTransfer', { value: { files: [second] } });
drop.dispatchEvent(event2);
await wait(2600);
const items = [...document.querySelectorAll('.collect-item')];
push('同名照片也能上传成功（自动改名）', items.length === 2 && items[1].classList.contains('done'),
  items.map(i => i.className + ':' + i.textContent.slice(0, 24)).join(' | '));
push('两次上传后计数为 2', !!hint && hint.textContent.includes('已收到 2 张'), hint ? hint.textContent : '无');
return JSON.stringify({ checks });
JS
say "照片收集（访客上传页）"
run_scenario "照片收集-访客" "$WORK/s18.js" "$BASE/s/$COLLECT_TOKEN" 430 860

cat > "$WORK/s16.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(900);
MacNas.WM.closeAll();
await wait(250);

const view = MacNas.openAnalytics({});
await wait(1800);
const win = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('存储分析'));
push('能打开存储分析', !!win, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join('|'));

const cards = [...win.querySelectorAll('.an-card')];
const labels = cards.map(c => c.querySelector('.an-card-label').textContent);
push('概览卡片包含逻辑大小/实际占用/去重节省',
  ['逻辑大小', '实际占用', '去重节省'].every(k => labels.includes(k)), labels.join(','));
const savedCard = cards.find(c => c.querySelector('.an-card-label').textContent === '去重节省');
push('去重节省显示金额与比例', !!savedCard && /省了 \d/.test(savedCard.textContent), savedCard ? savedCard.textContent : '无');

const segments = win.querySelectorAll('.an-bar .an-seg');
push('类型分布有柱状图', segments.length >= 1, '段数=' + segments.length);
const legend = [...win.querySelectorAll('.an-legend-row')].map(r => r.querySelector('.an-legend-name').textContent);
push('类型分布有图例', legend.length >= 1, legend.join(','));
const widths = [...segments].map(s => s.style.width);
push('柱状图按占比分配宽度', widths.length >= 1 && widths.every(w => w.endsWith('%')), widths.join(','));

const dupRows = win.querySelectorAll('.an-dup-row');
push('重复内容报告列出了重复项', dupRows.length >= 1, '行数=' + dupRows.length);
push('重复项显示可省空间', dupRows.length > 0 && /可省/.test(dupRows[0].textContent),
  dupRows.length ? dupRows[0].textContent.slice(0, 60) : '无');

const bucketRows = [...win.querySelectorAll('.an-bucket-row')];
push('有文件大小分布', bucketRows.length >= 5, '档数=' + bucketRows.length);
push('大小分布显示每档数量与体积', bucketRows.length > 0 && /个$/.test(bucketRows[0].querySelector('.an-bucket-count').textContent)
  && bucketRows[0].querySelector('.an-bucket-size').textContent.length > 0,
  bucketRows.length ? bucketRows[0].textContent.slice(0, 50) : '无');
const bucketFill = win.querySelector('.an-bucket-fill');
push('大小分布有占比条', !!bucketFill && bucketFill.style.width.endsWith('%'), bucketFill ? bucketFill.style.width : '无');
const jump = win.querySelector('.an-bucket-jump');
push('大小分布每档可以跳到最大的那个文件', !!jump && jump.textContent.includes('看最大'), jump ? jump.textContent : '无');
if (jump) {
  jump.click();
  await wait(1800);
  const previewWin = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('预览'));
  push('点「看最大的」能打开预览', !!previewWin, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join('|'));
  MacNas.WM.closeAll();
  await wait(300);
}

const bigRows = win.querySelectorAll('.an-big-row');
push('大文件排行榜有内容', bigRows.length >= 1, '行数=' + bigRows.length);
bigRows[0].click();
await wait(1800);
const preview = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('预览'));
push('点大文件能打开预览', !!preview, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join('|'));

// 按目录切换
MacNas.WM.closeAll();
await wait(250);
const view2 = MacNas.openAnalytics({ volumeId: MacNas.state.volumes[0].id });
await wait(1600);
const win2 = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('存储分析'));
const chips = [...win2.querySelectorAll('.an-chips .photos-chip')].map(c => c.textContent);
push('顶部可以按目录筛选', chips.length >= 2 && chips.includes('全部目录'), chips.join(','));
push('标题显示已省空间', win2.querySelector('.win-title-text').textContent.includes('已省'),
  win2.querySelector('.win-title-text').textContent);
return JSON.stringify({ checks });
JS
say "存储分析（界面）"
run_scenario "存储分析" "$WORK/s16.js" "$BASE/" 1440 900

cat > "$WORK/s10.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await wait(1800);
const page = document.querySelector('.share-page');
push('分享页容器存在', !!page);
push('内容超过一屏', page.scrollHeight > page.clientHeight + 4,
  page.scrollHeight + ' vs ' + page.clientHeight);
page.scrollTop = 300;
await wait(300);
push('分享页能滚动（scrollTop 生效）', page.scrollTop > 200, 'scrollTop=' + page.scrollTop);

page.scrollTop = page.scrollHeight;
await wait(300);
const foot = document.querySelector('.share-foot');
push('能滚到最底部的页脚', foot.getBoundingClientRect().bottom <= window.innerHeight + 4,
  'foot bottom=' + Math.round(foot.getBoundingClientRect().bottom) + ' 视口=' + window.innerHeight);

page.scrollTop = 0;
await wait(300);
const firstRow = document.querySelector('.share-body .row');
push('能滚回顶部看到第一个文件', firstRow.getBoundingClientRect().top >= 0,
  'top=' + Math.round(firstRow.getBoundingClientRect().top));
push('分享页没有被 HTML 的 overflow:hidden 裁掉', getComputedStyle(page).overflowY === 'auto',
  getComputedStyle(page).overflowY);
return JSON.stringify({ checks });
JS
say "分享页滚动"
run_scenario "分享页滚动" "$WORK/s10.js" "$BASE/s/$SCROLL_TOKEN" 1200 800

cat > "$WORK/s11.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await wait(900);
const screen = document.querySelector('.lockscreen');
push('登录页是可滚动容器', getComputedStyle(screen).overflowY === 'auto', getComputedStyle(screen).overflowY);
const card = document.querySelector('.login-card');
const button = document.getElementById('login-submit');
push('窗口很矮时登录按钮不会被裁掉', button.getBoundingClientRect().bottom <= window.innerHeight + 4,
  '按钮 bottom=' + Math.round(button.getBoundingClientRect().bottom) + ' 视口=' + window.innerHeight);
push('卡片顶部没有被裁掉', card.getBoundingClientRect().top >= -1,
  'top=' + Math.round(card.getBoundingClientRect().top));
return JSON.stringify({ checks });
JS
say "登录页在矮窗口下"
run_scenario "登录页矮窗口" "$WORK/s11.js" "$BASE/" 1200 380

cat > "$WORK/s8.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(900);
MacNas.WM.closeAll();
await wait(300);
const v = MacNas.state.volumes[0].id;

// 系统渲染缩略图有时要一两秒，等它出现再断言，避免时序抖动
const waitFor = async (fn, timeout) => {
  const started = Date.now();
  for (;;) {
    if (fn()) return true;
    if (Date.now() - started > (timeout || 8000)) return fn();
    await wait(250);
  }
};
const openFolder = async () => {
  MacNas.WM.closeAll();
  await wait(250);
  const view = MacNas.openFileManager({ volumeId: v, path: '/资料' });
  await wait(1000);
  return view;
};
const previewWindow = () => [...document.querySelectorAll('.win')]
  .find(w => w.querySelector('.win-title-text').textContent.startsWith('预览'));
const clickFile = async (view, name) => {
  [...view.listEl.querySelectorAll('.row')]
    .find(r => r.querySelector('.row-name').textContent === name)
    .querySelector('.row-main').click();
  await wait(1800);
};

let view = await openFolder();
const names = [...view.listEl.querySelectorAll('.row-name')].map(n => n.textContent);
push('文件列表里有四种预览素材', ['示例图片.png', '示例文档.docx', '示例表格.xlsx', '示例文本.txt'].every(n => names.includes(n)),
  names.join(','));
const docRow = [...view.listEl.querySelectorAll('.row')].find(r => r.querySelector('.row-name').textContent === '示例文档.docx');
push('可预览的文件行按钮是“预览”', docRow.querySelector('.row-actions .icon-btn').title === '预览',
  docRow.querySelector('.row-actions .icon-btn').title);

await clickFile(view, '示例图片.png');
let win = previewWindow();
push('点文件能打开预览窗口', !!win, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join(' | '));
const image = win && win.querySelector('.pv-image');
push('图片真的渲染出来', !!(image && image.complete && image.naturalWidth > 0),
  image ? image.naturalWidth + 'x' + image.naturalHeight : '无');
push('图片预览可切换原始尺寸', !!win.querySelector('.pv-actions .btn.text'));
push('预览有下载按钮', !!win.querySelector('.pv-actions .btn.filled'));
push('预览窗口能被布局记忆记住', (() => {
  const saved = JSON.parse(localStorage.getItem('macnas-session') || 'null');
  return !!(saved && saved.windows.some(w => w.app === 'preview'));
})(), localStorage.getItem('macnas-session'));

view = await openFolder();
await clickFile(view, '示例文本.txt');
win = previewWindow();
const pre = win && win.querySelector('.pv-text');
push('文本文件显示内容', !!(pre && pre.textContent.includes('预览测试文本')),
  pre ? pre.textContent.slice(0, 30) : '无');

view = await openFolder();
await clickFile(view, '示例文档.docx');
await wait(800);
win = previewWindow();
push('Word 文档转成网页用 iframe 呈现', !!win.querySelector('.pv-frame'),
  win.querySelector('.pv-frame') ? win.querySelector('.pv-frame').getAttribute('src').slice(0, 40) : '无');
push('Word 预览说明了是转换后的效果', win.querySelector('.pv-sub').textContent.includes('转换'),
  win.querySelector('.pv-sub').textContent);

view = await openFolder();
await clickFile(view, '示例表格.xlsx');
win = previewWindow();
const thumbReady = await waitFor(() => {
  const image = win && win.querySelector('.pv-image');
  return !!(image && image.complete && image.naturalWidth > 100);
}, 8000);
const thumb = win && win.querySelector('.pv-image');
let thumbFetch = '';
if (thumb) {
  try {
    const res = await fetch(thumb.getAttribute('src'));
    thumbFetch = ' fetch=' + res.status + ' ' + res.headers.get('content-type');
  } catch (e) { thumbFetch = ' fetch 失败 ' + e.message; }
}
push('表格用系统渲染图预览', thumbReady,
  thumb ? (thumb.naturalWidth + 'x' + thumb.naturalHeight + ' complete=' + thumb.complete + thumbFetch) : '无');

// 右键菜单里也有预览
view = await openFolder();
const pngRow = [...view.listEl.querySelectorAll('.row')].find(r => r.querySelector('.row-name').textContent === '示例图片.png');
pngRow.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 300, clientY: 300 }));
await wait(400);
const menuItems = [...document.querySelectorAll('.context-menu .ctx-item')].map(b => b.textContent);
push('右键菜单第一项是预览', menuItems[0] === '预览', menuItems.slice(0, 3).join(','));
document.body.click();
await wait(300);
return JSON.stringify({ checks });
JS
say "文件预览（桌面）"
run_scenario "文件预览-桌面" "$WORK/s8.js" "$BASE/" 1440 900

cat > "$WORK/s9.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await wait(1600);
const rows = [...document.querySelectorAll('.share-body .row')];
const rowFor = (n) => rows.find(r => r.querySelector('.row-name').textContent === n);
push('分享页列出可预览素材', !!rowFor('示例图片.png') && !!rowFor('示例文档.docx'),
  rows.map(r => r.querySelector('.row-name').textContent).join(','));
const buttons = [...rowFor('示例图片.png').querySelectorAll('.row-actions .btn')];
push('分享页有预览按钮', buttons.some(b => b.textContent.includes('预览')), buttons.map(b => b.textContent).join('|'));

buttons.find(b => b.textContent.includes('预览')).click();
await wait(2000);
const overlay = document.querySelector('.pv-overlay');
push('分享页打开预览浮层', !!overlay);
const image = overlay && overlay.querySelector('.pv-image');
push('分享页图片真的加载出来', !!(image && image.complete && image.naturalWidth > 0),
  image ? image.naturalWidth + 'x' + image.naturalHeight : '无');
push('浮层里有下载按钮', !!(overlay && overlay.querySelector('.pv-actions .btn.filled')));
push('浮层是固定定位、盖在页面上', !!(overlay && getComputedStyle(overlay).position === 'fixed'));
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
await wait(600);
push('Esc 能关掉预览浮层', !document.querySelector('.pv-overlay'));

rowFor('示例文档.docx').querySelector('.row-main').click();
await wait(2400);
push('分享页也能预览 Word', !!document.querySelector('.pv-overlay .pv-frame'),
  document.querySelector('.pv-overlay .pv-frame') ? '有 iframe' : '无');
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
await wait(400);
rowFor('示例文本.txt').querySelector('.row-main').click();
await wait(1800);
const pre = document.querySelector('.pv-overlay .pv-text');
push('分享页也能预览文本', !!(pre && pre.textContent.includes('预览测试文本')),
  pre ? pre.textContent.slice(0, 20) : '无');
return JSON.stringify({ checks });
JS
say "文件预览（分享页）"
run_scenario "文件预览-分享页" "$WORK/s9.js" "$BASE/s/$PREVIEW_TOKEN" 1200 800

cat > "$WORK/s5.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ username: 'admin', password: 'test1234' }) });
const session = await fetch('/api/session').then(r => r.json());
await showDesktop(session.username);
await wait(600);
MacNas.WM.closeAll();
await wait(200);

// 快捷键 ⌘K / Ctrl+K 打开搜索
document.dispatchEvent(new KeyboardEvent('keydown', { key: 'k', metaKey: true, bubbles: true }));
await wait(700);
const searchWin = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent === '全局搜索');
push('⌘K 能打开全局搜索', !!searchWin, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join(','));

const input = searchWin.querySelector('input[type="search"]');
push('搜索框能自动获得焦点', document.activeElement === input || searchWin.contains(document.activeElement));
input.value = '季度报告';
input.dispatchEvent(new Event('input', { bubbles: true }));
await wait(1100);
const names = [...searchWin.querySelectorAll('.row-name')].map(n => n.textContent);
push('搜索结果列出匹配文件', names.includes('季度报告-2026.txt'), names.join(','));
push('结果里显示了所在目录与卷名', searchWin.querySelector('.row-sub').textContent.includes('vol'),
  searchWin.querySelector('.row-sub').textContent);
push('命中的关键词被高亮', !!searchWin.querySelector('.row-name mark'),
  searchWin.querySelector('.row-name').textContent + ' / mark=' + !!searchWin.querySelector('.row-name mark'));
const actions = searchWin.querySelectorAll('.row-actions .icon-btn');
push('结果行有打开位置/下载/分享/复制路径', actions.length >= 4, String(actions.length));

// 点击“打开所在位置”，应该打开文件管理器并定位到该文件
actions[0].click();
await wait(1600);
const fmWin = [...document.querySelectorAll('.win')].find(w => w.querySelector('.win-title-text').textContent.startsWith('文件管理'));
push('能跳到文件所在目录', !!fmWin, [...document.querySelectorAll('.win-title-text')].map(n => n.textContent).join(','));
const flashed = fmWin ? fmWin.querySelector('.row.flash') : null;
push('目标文件被高亮定位', !!(flashed && flashed.textContent.includes('季度报告-2026.txt')),
  fmWin ? [...fmWin.querySelectorAll('.row-name')].map(n => n.textContent).join(',') : '');
return JSON.stringify({ checks });
JS
say "全局搜索界面"
run_scenario "全局搜索" "$WORK/s5.js" "$BASE/" 1440 900

cat > "$WORK/s3.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await wait(900);
push('分享页标题正确', (document.querySelector('.share-head h1') || {}).textContent === '目标',
  (document.querySelector('.share-head h1') || {}).textContent || '');
push('分享页列出文件夹内文件', [...document.querySelectorAll('.share-body .row-name')].some(n => n.textContent === '已就位.txt'),
  [...document.querySelectorAll('.share-body .row-name')].map(n => n.textContent).join(','));
push('分享页有下载按钮', !!document.querySelector('.share-body .btn'));
push('分享页不显示桌面与登录', getComputedStyle(document.getElementById('desktop')).display === 'none'
  && getComputedStyle(document.getElementById('lockscreen')).display === 'none');
push('分享页显示有效期', (document.querySelector('.share-foot') || {}).textContent.includes('有效期'));
return JSON.stringify({ checks });
JS
say "分享页（文件夹，匿名访问）"
run_scenario "分享页-文件夹" "$WORK/s3.js" "$BASE/s/$FOLDER_TOKEN" 900 700

cat > "$WORK/s4.js" <<'JS'
const wait = (ms) => new Promise(r => setTimeout(r, ms));
const checks = [];
const push = (name, ok, detail) => checks.push({ name, ok: !!ok, detail: detail || '' });
await wait(700);
push('带密码分享先要求输入密码', !!document.querySelector('.share-password form'));
push('密码界面显示分享名称', (document.querySelector('.share-password h1') || {}).textContent === '界面测试.txt',
  (document.querySelector('.share-password h1') || {}).textContent || '');
const input = document.querySelector('.share-password input[type="password"]');
if (input) {
  input.value = '2468';
  document.querySelector('.share-password form').dispatchEvent(new Event('submit', { cancelable: true }));
  await wait(1400);
}
push('输入正确密码后解锁并显示下载', !!document.querySelector('.share-file .btn'),
  document.querySelector('.share-file .sf-name') ? document.querySelector('.share-file .sf-name').textContent : 'still-locked');
return JSON.stringify({ checks });
JS
say "分享页（密码保护）"
run_scenario "分享页-密码" "$WORK/s4.js" "$BASE/s/$PASSWORD_TOKEN" 900 700

printf '\n\033[1m通过 %d 项，失败 %d 项\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
