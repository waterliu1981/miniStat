#!/bin/bash
# miniStat 构建脚本：编译 → 打包 .app → ad-hoc 签名 → 部署
#
# 用法：./build.sh
# 说明：本脚本只依赖系统自带的 swiftc（Xcode / Command Line Tools），
#       不依赖任何第三方包，不联网。

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="miniStat"

# 安装位置：优先 ~/Applications（无需管理员权限）
DEST_DIR="${MINISTAT_DEST_DIR:-$HOME/Applications}"
BUILD_DIR="$SRC_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DEST="$DEST_DIR/$APP_NAME.app"

# 版本号：取「当前提交」上的 tag（v1.1.1 → 1.1.1）。
#
# 注意这里用的是 `--points-at HEAD` 而不是 `--abbrev=0`：
# 后者会取最近的一个 tag，即使当前 HEAD 已经领先它很多提交也会照用，
# 于是构建出来的 .app 顶着旧版本号 —— 之前踩过这个坑。
# 现在要求 HEAD 正好被某个 tag 指向，否则直接报错退出。
#
# 想跳过检查（临时构建、调试用）可以：
#   SKIP_TAG_CHECK=1 ./build.sh        # 用兜底版本号
FALLBACK_VERSION="1.1.1"

TAG_AT_HEAD="$(git -C "$SRC_DIR" tag --points-at HEAD 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$TAG_AT_HEAD" ]]; then
    VERSION="${TAG_AT_HEAD#v}"
else
    if [[ "${SKIP_TAG_CHECK:-0}" == "1" ]]; then
        VERSION="$FALLBACK_VERSION"
        echo "⚠️  当前提交没有 tag，按 SKIP_TAG_CHECK=1 使用兜底版本号 $VERSION"
    else
        echo "❌ 当前提交（$(git -C "$SRC_DIR" rev-parse --short HEAD)）没有被打 tag，拒绝构建。"
        echo ""
        echo "   版本号来自 tag，直接构建会得到错误（或兜底的旧）版本号。请先打 tag："
        echo ""
        echo "     git tag -a v1.1.2 -m \"v1.1.2 — 变更说明\""
        echo "     ./build.sh"
        echo ""
        echo "   如果只是临时构建、不需要正确版本号，可以："
        echo ""
        echo "     SKIP_TAG_CHECK=1 ./build.sh"
        echo ""
        exit 1
    fi
fi

if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "❌ tag「$TAG_AT_HEAD」不是合法的版本号（应形如 v1.2.3）"
    exit 1
fi

echo "==> 环境检查"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "❌ 未找到 swiftc。请先安装 Xcode 或 Command Line Tools："
    echo "    xcode-select --install"
    exit 1
fi
echo "    swiftc: $(swiftc --version 2>&1 | head -1)"
echo "    架构:   $(uname -m)"

echo "==> 清理"
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# 只编译本机原生架构：每台 Mac 编译出来的才是那台机器最优的产物，
# 不需要 lipo 拼双架构（那反而引入跨架构兼容负担）。
echo "==> 编译（原生架构）"
swiftc -O \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    "$SRC_DIR/Sources/$APP_NAME/Sensors.swift" \
    "$SRC_DIR/Sources/$APP_NAME/main.swift"

echo "==> 生成 Info.plist"
echo "    版本:   $VERSION"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>miniStat</string>
    <key>CFBundleDisplayName</key>
    <string>miniStat</string>
    <key>CFBundleIdentifier</key>
    <string>local.waterliu.ministat</string>
    <key>CFBundleExecutable</key>
    <string>miniStat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || \
    echo "    (签名失败通常仍可运行；若被 Gatekeeper 拦截再另行处理)"

echo "==> 部署到 $DEST"
mkdir -p "$DEST_DIR"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"

echo "==> 完成"
echo "    构建产物: $APP_BUNDLE"
echo "    部署位置: $DEST"
