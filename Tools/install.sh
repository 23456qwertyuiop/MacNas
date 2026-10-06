#!/usr/bin/env bash
# 把 MacNas 装成一个「能双击打开」的正常 App。
#
# 为什么需要这个脚本：Xcode 与 xcodebuild 产出的 MacNas.app 位于 DerivedData / .build 里，
# 这两个位置**不被 Spotlight 索引**，启动台里也看不到 —— 于是用户想「打开这个软件」时
# 根本找不到可启动的副本，表现就是「点了完全没反应」。
#
# 用法：Tools/install.sh [安装目录]        默认 /Applications
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-/Applications}"
APP_NAME="MacNas.app"

cd "$ROOT"
echo "==> 构建 Release"
xcodebuild -project MacNas.xcodeproj -scheme MacNas -configuration Release \
  -destination 'platform=macOS' -derivedDataPath .build build > /tmp/macnas-install-build.log 2>&1 \
  || { tail -20 /tmp/macnas-install-build.log; exit 1; }

BUILT="$ROOT/.build/Build/Products/Release/$APP_NAME"
[ -d "$BUILT" ] || { echo "没找到构建产物：$BUILT"; exit 1; }

DEST="$TARGET_DIR/$APP_NAME"
echo "==> 安装到 $DEST"
# 先删掉旧的，避免旧的 Resources 残留导致前后端版本不一致
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# 清掉可能的隔离属性（自己构建的本没有，但复制过来时保险）
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "==> 校验"
codesign --verify --deep --strict "$DEST" 2>/dev/null && echo "  签名校验通过" || echo "  （未签名或校验跳过，本机自用没问题）"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')
echo "  版本 $VERSION"
echo "  前端资源：$(ls "$DEST/Contents/Resources" | tr '\n' ' ')"
echo
echo "装好了：$DEST"
echo "现在可以从「启动台」或「访达 → 应用程序」双击打开，也可以拖到 Dock 上。"
echo "如果之前从 Xcode 跑着一个旧实例，先按 ⌘Q 退出它（同一个 App 只会激活已运行的那个）。"
