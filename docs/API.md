# MacNas 开发者 API（v1）

MacNas 除了自己那套网页界面，还对外开放一组 HTTP API，方便你写脚本、做自动化、或者把 MacNas 接进自己的应用。

- **Base URL**：`http://<你的 Mac 地址>:<端口>`，例如 `http://192.168.1.20:7654`
- **接口前缀**：`/api/v1`
- **数据格式**：请求与响应都是 JSON（上传文件时请求体是文件原始字节）
- **鉴权**：`Authorization: Bearer <你的 API Key>`
- **稳定性承诺**：`/api/v1` 下的字段只会新增，不会改名或改变含义；破坏性改动会开 `/api/v2`

> 想在浏览器里直接看到这份文档？打开 MacNas 介绍站的「开发者 API」页面，内容与此处一致。

---

## 1. 先拿到一把 API Key

API Key 只能在**软件本体**里创建（网页端改不了账号、密码、端口，这是有意的安全设计）：

1. 打开 MacNas → 左侧「设置」 → 「开发者 API」
2. 填一个名字（例如「我的备份脚本」），勾选权限：
   - **只读**：列目录、下载、搜索、缩略图、预览
   - **读写**：在只读基础上加上传、新建文件夹、重命名、移动/复制、删除（进回收站）
3. 可选填有效期（天数），点「生成」。**明文 key 只显示一次**，请立刻保存。

想撤销就回到同一页面点「撤销」，撤销后该 key 立即失效。

> 磁盘上只保存 key 的 SHA-256 哈希，不保存明文；列表里也只显示前缀（如 `macnas_6b111c04`）。

---

## 2. 第一次调用

```bash
export MACNAS="http://192.168.1.20:7654"
export KEY="macnas_你保存下来的那一串"

# 看看这把 key 是谁、有什么权限
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/me"
```

```json
{
  "ok": true,
  "api": "MacNas",
  "apiVersion": "v1",
  "caller": "我的备份脚本",
  "scopes": ["read", "write"],
  "volumeCount": 1,
  "docs": "https://github.com/23456qwertyuiop/MacNas/blob/main/docs/API.md"
}
```

接着列出所有存储目录，拿到 `volume` 的 id —— 后面几乎所有接口都要带它：

```bash
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/volumes"
```

```json
{
  "ok": true,
  "volumes": [
    { "id": "6E342369-D35B-4017-8047-C181D60D34A8", "name": "test",
      "path": "/Users/you/Documents/test", "fileCount": 120, "size": 45678901,
      "available": true, "readOnly": false }
  ]
}
```

为了少敲字，下面统一用 `$VOL` 表示这个 id：

```bash
VOL="6E342369-D35B-4017-8047-C181D60D34A8"
```

---

## 3. 读：列目录 / 下载 / 搜索 / 缩略图

### 列目录

```bash
curl -s -H "Authorization: Bearer $KEY" \
  "$MACNAS/api/v1/files?volume=$VOL&path=/照片"
```

```json
{
  "ok": true,
  "path": "/照片",
  "folders": [ { "name": "2026", "path": "/照片/2026", "fileCount": 12, "isFolder": true } ],
  "files": [
    { "id": "A1B2…", "name": "海边.jpg", "path": "/照片/海边.jpg", "size": 2456789,
      "sha256": "9f2c…", "createdAt": "2026-10-06T04:00:00Z", "isFolder": false, "extension": "jpg" }
  ]
}
```

`path` 不传就是根目录 `/`。

### 下载文件

```bash
# 按 id
curl -H "Authorization: Bearer $KEY" -o 海边.jpg \
  "$MACNAS/api/v1/files/download?volume=$VOL&id=A1B2…"

# 也可以按逻辑路径
curl -H "Authorization: Bearer $KEY" -o 海边.jpg \
  "$MACNAS/api/v1/files/download?volume=$VOL&path=/照片/海边.jpg"
```

支持 `Range` 请求头（断点续传、播放器拖动进度都靠它）。

### 看单个文件的元信息

```bash
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/files/stat?volume=$VOL&id=A1B2…"
```

### 搜索

```bash
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/search?q=海边"
```

```json
{ "ok": true, "query": "海边",
  "results": [ { "kind": "file", "name": "海边.jpg", "path": "/照片/海边.jpg",
                 "volumeId": "6E34…", "volumeName": "test", "size": 2456789,
                 "id": "A1B2…", "createdAt": "2026-10-06T04:00:00Z" } ] }
```

`volume` 参数可选；不传就搜所有目录。最多返回 200 条。

### 缩略图与预览

```bash
# 缩略图（JPEG 字节；size 支持 32–1024，默认 256）
curl -H "Authorization: Bearer $KEY" -o thumb.jpg \
  "$MACNAS/api/v1/thumbnails?volume=$VOL&id=A1B2…&size=256"

# 预览元信息（判断浏览器/客户端该怎么渲染）
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/preview?volume=$VOL&id=$DOC_ID"
# 预览内容（图片原图、文本转好的纯文本、Word 转好的 HTML、其它格式的渲染图）
curl -H "Authorization: Bearer $KEY" -o preview.html \
  "$MACNAS/api/v1/preview/content?volume=$VOL&id=$DOC_ID"
```

### 统计

```bash
curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/stats?volume=$VOL"
```

返回逻辑大小、实际占用、去重节省、类型与大小分布等（与软件「存储分析」页面一致）。

---

## 4. 写：上传 / 新建文件夹 / 重命名 / 移动 / 删除

> 这些接口需要**读写**权限的 key；用只读 key 调用会返回 `403 read_only_key`。

### 上传文件

请求体就是文件的原始字节（不是 multipart）：

```bash
curl -H "Authorization: Bearer $KEY" -X POST \
  --data-binary @本地文件.jpg \
  "$MACNAS/api/v1/files/upload?volume=$VOL&path=/照片&name=新照片.jpg"
```

```json
{ "ok": true,
  "file": { "id": "C3D4…", "name": "新照片.jpg", "path": "/照片/新照片.jpg",
            "size": 2456789, "sha256": "ab12…", "isFolder": false, "extension": "jpg" },
  "outcome": "stored" }
```

- 同名文件默认**自动改名**（`新照片 (2).jpg`），不会覆盖。
- 加 `&overwrite=1` 表示同名直接覆盖（旧内容会进历史版本，可回滚）。
- 如果内容在库里已经存在，`outcome` 会是 `"deduplicated"`：记录建好了，但一个字节都没多占。

### 新建文件夹

```bash
curl -s -H "Authorization: Bearer $KEY" -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"volume\":\"$VOL\",\"path\":\"/\",\"name\":\"归档\"}" \
  "$MACNAS/api/v1/folders"
```

### 重命名

```bash
# 文件：用 id
curl -s -H "Authorization: Bearer $KEY" -X POST -H 'Content-Type: application/json' \
  -d "{\"volume\":\"$VOL\",\"id\":\"C3D4…\",\"name\":\"改名后.jpg\"}" \
  "$MACNAS/api/v1/files/rename"

# 文件夹：用 from（逻辑路径）
curl -s -H "Authorization: Bearer $KEY" -X POST -H 'Content-Type: application/json' \
  -d "{\"volume\":\"$VOL\",\"from\":\"/归档\",\"name\":\"归档2026\"}" \
  "$MACNAS/api/v1/files/rename"
```

### 移动 / 复制

```bash
curl -s -H "Authorization: Bearer $KEY" -X POST -H 'Content-Type: application/json' \
  -d "{\"volume\":\"$VOL\",\"ids\":[\"C3D4…\"],\"paths\":[\"/旧文件夹\"],\"toPath\":\"/归档\",\"mode\":\"move\"}" \
  "$MACNAS/api/v1/files/move"
```

`mode` 取 `move`（默认）或 `copy`。`ids` 放文件 id，`paths` 放文件夹的逻辑路径，可以混用、可以多个。
重名会自动改名，返回里的 `renamed` 告诉你有几项被改名了。

### 删除（进回收站）

```bash
curl -s -H "Authorization: Bearer $KEY" -X DELETE \
  "$MACNAS/api/v1/files?volume=$VOL&id=C3D4…"

# 也可以用 POST（有些客户端不方便发 DELETE）
curl -s -H "Authorization: Bearer $KEY" -X POST -H 'Content-Type: application/json' \
  -d "{\"volume\":\"$VOL\",\"path\":\"/归档\"}" "$MACNAS/api/v1/files/delete"
```

删除是**进回收站**，不是永久删除 —— 和你在软件里点「移到回收站」完全一样，用户还能还原。

---

## 5. 错误处理

所有错误都是同一个形状：

```json
{ "error": { "code": "invalid_key", "message": "API Key 无效。请检查是否复制完整，或它是否已被撤销。" } }
```

| HTTP | code | 含义 |
|---|---|---|
| 400 | `missing_volume` / `bad_name` / `missing_target` / `missing_query` / `empty_body` | 参数不全或名字不合法 |
| 401 | `unauthorized` | 没带凭据，或凭据无效 |
| 401 | `invalid_key` | key 不存在（多为复制不完整） |
| 403 | `key_disabled` / `key_expired` | key 被撤销 / 已过期 |
| 403 | `read_only_key` | 用只读 key 调了写接口 |
| 404 | `not_found` / `unknown_volume` | 文件或目录不存在 |
| 405 | `method_not_allowed` | 方法用错了 |
| 429 | `rate_limited` | 请求太频繁，响应头里有 `Retry-After`（秒） |

**限流**：每把 key 单独计算 —— 读 600 次/分钟、写 120 次/分钟。正常脚本完全够用；
如果你是批量同步，建议加个并发上限，并尊重 `Retry-After`。

---

## 6. 跨域（浏览器里的网页调用）

默认**完全不开 CORS**：API Key 一旦被浏览器页面拿到，就等于把钥匙交给了那个网页，
所以除非你确实需要，不要让任意网页能调用。

确实需要时，在软件「设置 → 开发者 API → 允许跨域来源」里填白名单（例如 `http://localhost:5173`），
或用 `*` 允许任意来源（**不建议**，等于把 NAS 暴露给任何你访问过的网页）。
白名单生效后，`/api/v1` 的响应会带 `Access-Control-Allow-Origin`，并正确应答 `OPTIONS` 预检。

---

## 7. 一段完整的示例脚本

```bash
#!/usr/bin/env bash
# 把当前目录的照片备份进 MacNas 的 /照片备份/<日期>
set -euo pipefail
MACNAS="${MACNAS:-http://192.168.1.20:7654}"
KEY="${MACNAS_KEY:?请先 export MACNAS_KEY=macnas_xxx}"

VOL=$(curl -s -H "Authorization: Bearer $KEY" "$MACNAS/api/v1/volumes" \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["volumes"][0]["id"])')
TARGET="/照片备份/$(date +%Y-%m-%d)"

curl -s -H "Authorization: Bearer $KEY" -X POST -H 'Content-Type: application/json' \
     -d "{\"volume\":\"$VOL\",\"path\":\"/照片备份\",\"name\":\"$(date +%Y-%m-%d)\"}" \
     "$MACNAS/api/v1/folders" > /dev/null || true

for f in *.jpg *.heic *.png; do
  [ -e "$f" ] || continue
  RESULT=$(curl -s -H "Authorization: Bearer $KEY" -X POST --data-binary @"$f" \
    "$MACNAS/api/v1/files/upload?volume=$VOL&path=$TARGET&name=$(basename "$f")")
  echo "$f → $(echo "$RESULT" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("file",{}).get("name") or d)')"
done
echo "完成：$TARGET"
```

---

## 8. 关于「换机器 / 换端口」

API Key 存在软件的支持目录里（`~/Library/Application Support/MacNas/api-keys.json`），
跟着这台 Mac 的 MacNas 走。换端口不用重建 key，客户端改 Base URL 即可。

---

## 9. 接口清单（速查）

| 方法 | 路径 | 权限 | 说明 |
|---|---|---|---|
| GET | `/api/v1/me` | 任意 | key 信息与权限 |
| GET | `/api/v1/volumes` | 只读 | 列出存储目录 |
| GET | `/api/v1/stats` | 只读 | 空间统计（可带 `volume`） |
| GET | `/api/v1/files` | 只读 | 列目录（`volume`、`path`） |
| GET | `/api/v1/files/stat` | 只读 | 单个文件元信息（`id` 或 `path`） |
| GET | `/api/v1/files/download` | 只读 | 下载（支持 Range） |
| GET | `/api/v1/search` | 只读 | 搜索（`q`、可选 `volume`） |
| GET | `/api/v1/thumbnails` | 只读 | 缩略图（`id`、`size`） |
| GET | `/api/v1/preview` | 只读 | 预览元信息 |
| GET | `/api/v1/preview/content` | 只读 | 预览内容 |
| POST | `/api/v1/files/upload` | 读写 | 上传（`volume`、`path`、`name`、`overwrite`） |
| POST | `/api/v1/folders` | 读写 | 新建文件夹 |
| POST | `/api/v1/files/rename` | 读写 | 重命名 |
| POST | `/api/v1/files/move` | 读写 | 移动 / 复制 |
| DELETE | `/api/v1/files` | 读写 | 删除（进回收站） |
| POST | `/api/v1/files/delete` | 读写 | 同上，给不方便发 DELETE 的客户端 |

## 10. 没有放进 API 的能力（有意的）

为了避免第三方误操作把用户的系统搞乱，这些**只能在本机软件里做**：

- 改账号、密码、端口
- 创建 / 撤销分享链接、照片收集链接
- 清空回收站、彻底删除、恢复历史版本
- 移除存储目录、重建索引、镜像导出

如果你确实需要其中某项，欢迎在 GitHub 上开 issue 说明场景，我们会评估在 v2 里加进只读或受限权限。
