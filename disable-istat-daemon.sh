#!/bin/bash
# 停用并禁用 iStat Menus 根守护进程
# 需要 sudo 密码 —— 请手动执行：sudo bash ~/miniStat/disable-istat-daemon.sh

set -e

echo "==> 1) 停止根守护进程"
launchctl bootout system/com.bjango.istatmenus.daemon 2>/dev/null || echo "   (未加载或已停)"

echo "==> 2) 禁用，防止重启后自动拉起"
launchctl disable system/com.bjango.istatmenus.daemon

echo "==> 3) 移出系统级 plist（防重新加载）"
mkdir -p /Library/LaunchDaemons-disabled
if [ -f /Library/LaunchDaemons/com.bjango.istatmenus.daemon.plist ]; then
    mv /Library/LaunchDaemons/com.bjango.istatmenus.daemon.plist \
       /Library/LaunchDaemons-disabled/ 2>/dev/null || true
    echo "   daemon.plist 已移出"
fi
if [ -f /Library/LaunchDaemons/com.bjango.istatmenus.installer.plist ]; then
    mv /Library/LaunchDaemons/com.bjango.istatmenus.installer.plist \
       /Library/LaunchDaemons-disabled/ 2>/dev/null || true
    echo "   installer.plist 已移出"
fi

echo "==> 4) 停掉仍在运行的守护进程"
pkill -f "istatmenus.daemon" 2>/dev/null && echo "   已结束" || echo "   无残留"

echo "==> 5) 复查"
sleep 1
ps aux | grep "istatmenus" | grep -v grep && echo "   ⚠️ 仍有残留" || echo "   ✅ 已彻底停用"

echo "==> 完成"
