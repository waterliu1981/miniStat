#!/bin/bash
# miniStat 一键安装脚本
#
# 用法：bash install.sh
#
# 这个脚本会依次完成：
#   1. 检查编译环境
#   2. 编译并部署 App
#   3. 配置开机自启动
#   4. 启动并验证
#
# 只依赖系统自带的 swiftc，不联网、不装任何第三方包、不需要管理员权限。

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="miniStat"
APP_PATH="$HOME/Applications/$APP_NAME.app"
AGENT_LABEL="local.waterliu.ministat"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "=========================================="
echo "  miniStat 安装程序"
echo "=========================================="
echo

# ---------- 1. 环境检查 ----------
echo "【1/4】检查编译环境"
if ! command -v swiftc >/dev/null 2>&1; then
    echo "  ❌ 未找到 swiftc。请先安装：xcode-select --install"
    exit 1
fi
echo "  ✅ swiftc: $(swiftc --version 2>&1 | head -1)"
echo "  ✅ 架构: $(uname -m)"
echo "  ✅ 系统: macOS $(sw_vers -productVersion)"
echo

# ---------- 2. 编译并部署 ----------
echo "【2/4】编译并部署"
bash "$SRC_DIR/build.sh"
echo

# ---------- 3. 配置开机自启动 ----------
echo "【3/4】配置开机自启动"

# 如果已有实例在跑，先停掉，避免两套并存
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "  停掉已运行的实例..."
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 1
fi

# 写入 LaunchAgent：登录时自启 + 崩溃自动拉起
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_PATH/Contents/MacOS/$APP_NAME</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>Crashed</key>
        <true/>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST

launchctl unload "$AGENT_PLIST" 2>/dev/null || true
launchctl load "$AGENT_PLIST"
echo "  ✅ 已配置：$AGENT_PLIST"
echo

# ---------- 4. 启动并验证 ----------
echo "【4/4】启动并验证"
sleep 4

PID="$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" | head -1 || true)"
if [ -n "$PID" ]; then
    echo "  ✅ 进程已启动 (PID $PID)"
    RSS="$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ' || echo 0)"
    echo "     内存占用: $((RSS / 1024)) MB"
else
    echo "  ⚠️ 进程未启动，尝试直接拉起..."
    open "$APP_PATH" || true
    sleep 4
    PID="$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" | head -1 || true)"
    if [ -n "$PID" ]; then
        echo "  ✅ 已拉起 (PID $PID)"
    else
        echo "  ❌ 启动失败，请手动运行检查："
        echo "     $APP_PATH/Contents/MacOS/$APP_NAME"
    fi
fi

echo
echo "  服务状态: $(launchctl list 2>/dev/null | grep "$AGENT_LABEL" || echo '未注册')"
echo
echo "=========================================="
echo "  安装完成"
echo "=========================================="
echo
echo "  菜单栏右上角应出现四项指标（标签在上、数值在下）："
echo "    CPU 温度 / GPU 使用率 / MEM 使用率 / SSD 占用率"
echo
echo "  若没看到，可能被菜单栏图标挤掉了 —— 在菜单栏管理里收起一些图标即可。"
echo
echo "  卸载方法："
echo "    launchctl unload $AGENT_PLIST"
echo "    rm -rf $APP_PATH $AGENT_PLIST"
echo
