#!/bin/bash
# 重启后验证脚本 —— 重启完成后运行：bash ~/miniStat/verify-boot.sh
# 检查 iStat 是否不再自启、miniStat 是否自动起来

echo "=========================================="
echo "  重启后验证  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo

echo "【1】iStat 是否不再自启（应全部为空）"
if ps aux | grep -i "istat" | grep -v grep | grep -v verify-boot; then
    echo "   ❌ iStat 仍在运行！"
else
    echo "   ✅ iStat 未自启"
fi
echo

echo "【2】iStat 用户级 launchd 服务（应为空）"
if launchctl list 2>/dev/null | grep -i bjango; then
    echo "   ❌ 仍有服务被加载"
else
    echo "   ✅ 用户级服务已清空"
fi
echo

echo "【3】iStat 根守护进程（应为空）"
if ps aux | grep "istatmenus.daemon" | grep -v grep; then
    echo "   ❌ 守护进程仍在运行"
else
    echo "   ✅ 守护进程未自启"
fi
echo

echo "【4】miniStat 是否自动启动（应有一个进程）"
MPID=$(pgrep -f "miniStat.app/Contents/MacOS/miniStat" | head -1)
if [ -n "$MPID" ]; then
    echo "   ✅ miniStat 已自动启动，PID $MPID"
    echo "   运行时长: $(ps -o etime= -p $MPID | tr -d ' ')"
    echo "   内存占用: $(ps -o rss= -p $MPID | awk '{printf "%.0f MB", $1/1024}')"
else
    echo "   ❌ miniStat 未自动启动"
fi
echo

echo "【5】miniStat launchd 服务状态"
launchctl list 2>/dev/null | grep ministat || echo "   ❌ 服务缺失"
echo

echo "【6】状态栏是否显示（读取实际读数）"
if [ -n "$MPID" ]; then
    cd "$(dirname "$0")" 2>/dev/null
    if [ -x /tmp/smcprobe/monitor ]; then
        /tmp/smcprobe/monitor 2>/dev/null | tail -4
    fi
fi
echo

echo "【7】截图确认（菜单栏）"
screencapture -x -R 0,0,1800,40 /tmp/after-reboot.png 2>/dev/null && echo "   已截图: /tmp/after-reboot.png"
echo

echo "=========================================="
echo "  验证完毕"
echo "=========================================="
