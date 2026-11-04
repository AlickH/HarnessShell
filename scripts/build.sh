#!/usr/bin/env bash
# 生成工程 → 编译 → 打开。
# 用 Developer ID 证书签名：cdhash 固定，TCC 隐私授权（Documents 等）一次后永久有效，
# 不再因 ad-hoc 签名每次编译 cdhash 变化而反复弹授权窗。
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="Developer ID Application: Ning Huang (KLU8GF65GP)"

xcodegen generate >/dev/null

xcodebuild \
  -project Whaless.xcodeproj \
  -target Whaless \
  -configuration Debug \
  SYMROOT=build \
  build 2>&1 | tail -8

APP="build/Debug/Whaless.app"
echo "→ $APP"

# xcodebuild 已按 CODE_SIGN_IDENTITY 签名；再补一次 --deep 深度签名，
# 确保 bundle 内所有可执行文件/资源都用同一证书签好，签名完整稳定。
codesign --force --deep --sign "$IDENTITY" "$APP"

echo "签名身份："
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority" | head -3

open "$APP"
