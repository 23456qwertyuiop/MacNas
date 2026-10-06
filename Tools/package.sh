#!/usr/bin/env bash
# 打出 Apple 芯片与 Intel 两个版本，放到仓库根目录。
#
# 最低系统为什么是 macOS 14：实测（连 10 行的最小 SwiftUI 程序也一样）发现，
# 用当前工具链把部署目标设到 14 以下时，SwiftUI 在 macOS 27 上不会创建任何窗口，
# 界面完全不出现。要再往下支持就得把窗口管理从 SwiftUI App 换成 AppKit。
# 想改就用 MACNAS_MIN_MACOS=… 覆盖，但改完务必真的启动一次验证。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TARGET="${MACNAS_MIN_MACOS:-14.0}"

for arch in arm64 x86_64; do
  echo "==> 构建 ${arch}（最低 macOS ${TARGET}）"
  rm -rf ".build14-$arch"
  xcodebuild -project MacNas.xcodeproj -scheme MacNas -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath ".build14-$arch" \
    ARCHS=$arch ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET="$TARGET" build > "/tmp/macnas-pkg-$arch.log" 2>&1 \
    || { echo "构建失败，错误如下："; grep -E "error:" "/tmp/macnas-pkg-$arch.log" | head -10; exit 1; }

  APP=".build14-$arch/Build/Products/Release/MacNas.app"
  if [ "$arch" = "x86_64" ]; then OUT="MacNas-x86_64.zip"; else OUT="MacNas-arm64.zip"; fi
  rm -f "$OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"

  FOUND_ARCHS=$(lipo -archs "$APP/Contents/MacOS/MacNas")
  FOUND_MINOS=$(otool -l "$APP/Contents/MacOS/MacNas" | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}')
  FOUND_SIZE=$(du -h "$OUT" | awk '{print $1}')
  FOUND_SHA=$(shasum -a 256 "$OUT" | awk '{print $1}')
  echo "    $OUT"
  echo "      架构 ${FOUND_ARCHS} ｜ 最低系统 ${FOUND_MINOS} ｜ 大小 ${FOUND_SIZE}"
  echo "      SHA-256 ${FOUND_SHA}"
done

echo
echo "两个包已在仓库根目录（MacNas-arm64.zip / MacNas-x86_64.zip）。"
