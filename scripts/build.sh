#!/usr/bin/env bash
# 生成工程 → 编译 → 打开。没有签名证书，用 ad-hoc（CODE_SIGN_IDENTITY = "-"），
# 本机自用足够；要分发再换成 Developer ID + 公证。
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null

xcodebuild \
  -project Whaless.xcodeproj \
  -target Whaless \
  -configuration Debug \
  SYMROOT=build \
  build 2>&1 | tail -8

APP="build/Debug/Whaless.app"
echo "→ $APP"
open "$APP"
