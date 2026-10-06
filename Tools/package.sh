#!/usr/bin/env bash
# 打出 Apple 芯片与 Intel 两个版本，放到仓库根目录。
# 两个包都用 macOS 14.0 作为最低系统：Intel 机器装不了 macOS 27，
# 部署目标留在 27 的话 Intel 包在真机上根本起不来。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TARGET="${MACNAS_MIN_MACOS:-14.0}"

for arch in arm64 x86_64; do
  echo "==> 构建 $arch（最低 macOS $TARGET）"
  rm -rf ".build14-$arch"
  xcodebuild -project MacNas.xcodeproj -scheme MacNas -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath ".build14-$arch" \
    ARCHS=$arch ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET="$TARGET" build > "/tmp/macnas-pkg-$arch.log" 2>&1 \
    || { grep -E "error:" "/tmp/macnas-pkg-$arch.log" | head -10; exit 1; }

  APP=".build14-$arch/Build/Products/Release/MacNas.app"
  OUT="MacNas-$( [ "$arch" = "x86_64" ] && echo x86_64 || echo arm64 ).zip"
  rm -f "$OUT"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
  printf '    %s  架构=%s  最低系统=%s  大小=%s\n' "$OUT" \
    "$(lipo -archs "$APP/Contents/MacOS/MacNas")" \
    "$(otool -l "$APP/Contents/MacOS/MacNas" | grep -A4 LC_BUILD_VERSION | grep minos | awk '{print $2}')" \
    "$(du -h "$OUT" | awk '{print $1}')"
done

echo
echo "两个包已在仓库根目录。校验信息见 MacNas-packages.txt。"
