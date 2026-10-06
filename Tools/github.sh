#!/usr/bin/env bash
# 推送代码 / 发布安装包到 GitHub。
#
# 这个脚本处理了两件在国内网络下必须做的事：
#   1) 走本地代理（Clash 之类的 SOCKS5 端口），因为 GitHub 域名在本机会被解析成 fake-IP，直连必失败
#   2) 用钥匙串里已保存的 GitHub 凭据做 API 鉴权（不会把凭据写进仓库或 git 配置）
#
# 用法：
#   Tools/github.sh push                 # 推送到 origin main
#   Tools/github.sh release v1.0.1       # 建 Release 并上传根目录的两个安装包
#   Tools/github.sh public               # 把仓库改为公开（private 则改为私有）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OWNER="${MACNAS_GITHUB_OWNER:-23456qwertyuiop}"
REPO="${MACNAS_GITHUB_REPO:-MacNas}"
API="https://api.github.com/repos/${OWNER}/${REPO}"

# 代理：可用 MACNAS_PROXY 覆盖；默认试常见的 Clash SOCKS5 端口
detect_proxy() {
  if [ -n "${MACNAS_PROXY:-}" ]; then echo "$MACNAS_PROXY"; return; fi
  for port in 7897 7890 1080 1087; do
    if nc -z -G 1 127.0.0.1 "$port" 2>/dev/null; then echo "--socks5-hostname 127.0.0.1:$port"; return; fi
  done
  echo ""
}
PROXY="$(detect_proxy)"
[ -n "$PROXY" ] && echo "==> 使用代理：$PROXY" || echo "==> 未检测到本地代理，直连"

# 凭据：优先环境变量，其次钥匙串（只读取，不打印）
token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then echo "$GITHUB_TOKEN"; return; fi
  security find-internet-password -s github.com -w 2>/dev/null || true
}

case "${1:-push}" in
  push)
    TOKEN="$(token)"
    [ -n "$TOKEN" ] || { echo "没找到 GitHub 凭据，请先设置 GITHUB_TOKEN"; exit 1; }
    AUTH=$(printf 'x-access-token:%s' "$TOKEN" | base64)
    git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/${OWNER}/${REPO}.git"
    git branch -M main
    echo "==> 推送 main"
    git -c http.proxy=socks5h://127.0.0.1:7897 -c https.proxy=socks5h://127.0.0.1:7897 \
        -c http.extraHeader="Authorization: Basic $AUTH" push -u origin main
    ;;
  release)
    TAG="${2:?用法: Tools/github.sh release <tag>，例如 v1.0.1}"
    TOKEN="$(token)"
    [ -n "$TOKEN" ] || { echo "没找到 GitHub 凭据"; exit 1; }
    # 先打包，保证附件与仓库里的 zip 一致
    ./Tools/package.sh
    python3 - "$TAG" <<'PY' > /tmp/macnas-release.json
import json, sys
tag = sys.argv[1]
notes = open('MacNas-packages.txt', encoding='utf-8').read()
print(json.dumps({
    "tag_name": tag, "target_commitish": "main", "name": "MacNas " + tag,
    "body": "MacNas " + tag + "\n\n" + notes, "draft": False, "prerelease": False,
}, ensure_ascii=False))
PY
    echo "==> 建 Release $TAG"
    RID=$(curl -s $PROXY --max-time 120 -X POST \
      -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" --data @/tmp/macnas-release.json \
      "$API/releases" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
    [ -n "$RID" ] || { echo "建 Release 失败"; exit 1; }
    for f in MacNas-arm64.zip MacNas-x86_64.zip; do
      echo "==> 上传 $f"
      # 必须禁用 Expect: 100-continue，否则经代理传大文件会失败
      curl -s $PROXY --max-time 900 --retry 5 --retry-delay 3 --retry-all-errors \
        -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/zip" -H "Expect:" \
        --data-binary @"$f" \
        "https://uploads.github.com/repos/${OWNER}/${REPO}/releases/$RID/assets?name=$f" \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);print("    ", d.get("browser_download_url") or d.get("message"))'
    done
    echo "==> 完成：https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
    ;;
  public|private)
    TOKEN="$(token)"
    VIS="false"; [ "$1" = "private" ] && VIS="true"
    curl -s $PROXY --max-time 60 -X PATCH -H "Authorization: token $TOKEN" \
      -H "Content-Type: application/json" -d "{\"private\":$VIS}" "$API" \
      | python3 -c 'import json,sys;d=json.load(sys.stdin);print("==> 现在可见性：", "私有" if d.get("private") else "公开")'
    ;;
  *)
    sed -n '2,14p' "$0"; exit 1;;
esac
