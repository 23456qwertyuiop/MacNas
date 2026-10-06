#!/usr/bin/env bash
# 推送到 GitHub。用法：Tools/push.sh git@github.com:你的账号/MacNas.git
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
URL="${1:?用法: Tools/push.sh <仓库地址>}"

if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$URL"
else
  git remote add origin "$URL"
fi
git branch -M main

# 远端如果已有提交（建仓库时勾了 README），先合并再推，避免被拒
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  echo "==> 远端 main 已有提交，先合并"
  git pull --rebase origin main
fi

echo "==> 推送到 $URL"
git push -u origin main
echo
echo "完成。仓库地址：$URL"
