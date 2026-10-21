# miniStat

macOS 状态栏系统监控工具，只显示四项指标：**CPU 温度、GPU 使用率、内存使用率、SSD 占用率**。

自己写的私有工具，用于替代 iStat Menus。**零依赖、零特权、纯用户态。**

---

## 给「另一个 Mac 上的 agent」的安装说明

如果你是 agent，正在读这份文档来帮用户安装这个 App，请按下面步骤执行。

### 第一步：确认环境

```bash
xcode-select -p          # 确认已装 Xcode / Command Line Tools
swiftc --version        # 确认能编译 Swift
uname -m                # 看架构（arm64）
sw_vers -productVersion # 看系统版本
```

如果 `swiftc` 不存在，先让用户执行 `xcode-select --install`。**不要自行安装 Xcode**。

### 第二步：安装（一条命令）

```bash
cd <本目录> && bash install.sh
```

`install.sh` 会自动完成：编译 → 部署到 `~/Applications` → 配置开机自启动 → 启动 → 验证。

### 第三步：验证

```bash
# 进程是否在跑
pgrep -fl miniStat

# 自启动是否注册
launchctl list | grep ministat

# 状态栏是否显示（截图看右上角）
screencapture -x -R 0,0,1800,40 /tmp/ministat-check.png
```

然后请**看一眼截图**，确认菜单栏右上角出现了四项指标。如果没看到，见下面「排错」。

---

## 这个 App 显示什么

菜单栏上是一个「标签在上、数值在下」的两行小单元，四个并排：

```
CPU    GPU    MEM    SSD
54°    34%    92%    78%
```

| 指标 | 含义 | 数据来源 |
|---|---|---|
| **CPU** | CPU 温度（°C） | Apple Silicon 的 HID 温度传感器（`tdie`/`tcal` 均值） |
| **GPU** | GPU 使用率（%） | `ioreg` 的 AGXAccelerator |
| **MEM** | 内存使用率（%） | `host_statistics64`，与「活动监视器」同口径 |
| **SSD** | 硬盘容量占用率（%） | `URLResourceValues`，与 Finder 同口径 |

---

## 技术说明（给 agent 看的实现要点）

### CPU 温度：为什么不用 SMC

Apple Silicon 上 `AppleSMC` 已经迁到 RTBuddy/SOCD 架构，普通进程能 `IOServiceOpen` 成功但**读不出任何 key**。

本 App 走的是**系统真实的温度传感器**：IOKit 的私有 HID 事件系统，匹配 `PrimaryUsagePage=0xff00` / `PrimaryUsage=5`，通过 `dlsym` 解析 `IOHIDEventSystemClient*` 系列私有符号。这条路径**与 iStat Menus 相同**，且**不需要 root**。

实现细节在 `Sources/miniStat/Sensors.swift` 的 `TemperatureReader`。两个坑已在代码注释里标明：

1. `IOHIDEventSystemClientSetMatching` 返回 `Void`（不是 `Int32`）—— 搞错会段错误。
2. **必须持有 `IOHIDEventSystemClient`** —— 服务引用只在 client 存活期间有效，client 释放后访问服务会 `SIGBUS`。

### 状态栏版式：为什么用 NSStackView

状态栏厚度只有 **22pt**。两行必须严格压在这个高度内。

- 用 attributed string 拼多个含 `\n` 的单元**不行** —— 每个单元会被推到新的一行（实测每加一个单元高度 +13pt）。
- 正确做法是 `NSStackView` 嵌套：每个指标一个竖排小栈，再横向并排。总高实测 **19pt**。
- 显式设 `statusItem.length` —— `variableLength` 不会根据子视图自动撑宽，会塌成 0 宽。

字号预设（`⌘` 菜单里可切）：小 18pt / 标准 22pt / 大 22pt —— 都在 22pt 内。

### 状态栏刷新：视图只建一次

早期版本每 2 秒把 statusItem 的 button 子视图全部拆掉，重建 4 组 `NSStackView` + 8 个 `NSTextField`，再 `layoutSubtreeIfNeeded()` 并重设 `statusItem.length`。这会让 AppKit 把整棵视图树离屏光栅化一遍（`_redrawReplicantSnapshot` → `_cacheDisplayInRect` → `CALayer renderInContext` → CoreText 字形绘制），是常驻 CPU 的大头。

现在的做法：

- 视图树**只构建一次**，之后刷新只改 `NSTextField.stringValue`；`lastRenderedValues` 缓存跳过没变化的赋值，避免把 statusItem 标记为重绘。
- 只有勾选指标或切字号时才重建（`containerBuilt` 标记）。
- 数值统一成**固定宽度**（百分比两位数、100% 显示为 99%），保证总宽恒定。宽度一变，`statusItem.length` 就会变，进而引发整个菜单栏重排。

实测（`top -l 3 -s 5` 取稳态值）：

| 机器 | 改前 | 改后 |
|---|---|---|
| M5 Max / macOS 27.0.1 | 未单独测 | **1.3%–1.9%** |
| M4（提交时测量，机器有 BTLEServer 占用约 97% 单核干扰） | ~52% | ~49% |

M4 那组数据受干扰，不能代表改动的实际收益；干净环境下的 M5 Max 数据是 1–2% 量级。换机后如需对比，请在**无高负载干扰**的环境下测，并注明机型和系统版本。

### SSD 占用率：口径陷阱

**不要用 `df /`** —— macOS 上 `/` 是只读系统卷，会报出 ~19% 的假值。真实数据在 `/System/Volumes/Data`，或直接用 `URLResourceValues`（Finder 同款 API）。

---

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 状态栏看不到 | 被别的图标挤掉了 | 菜单栏图标太多，收起几个 |
| 状态栏只显示一半 | 行距过大 | 菜单里切到「小」字号 |
| 进程反复重启 | 上次异常退出 | `launchctl unload` 再 `load` 一次 |
| 编译报错 | 缺 Xcode | `xcode-select --install` |
| 温度显示 `--` | HID 私有符号不可用 | 系统版本变化，需重新探测 |
| 被 Gatekeeper 拦 | ad-hoc 签名 | 系统设置 → 隐私与安全性 → 仍要打开 |

---

## 卸载

```bash
launchctl unload ~/Library/LaunchAgents/local.waterliu.ministat.plist
rm -rf ~/Applications/miniStat.app
rm -f ~/Library/LaunchAgents/local.waterliu.ministat.plist
```

无后台残留、无系统改动、无 root 组件，删掉即干净。

---

## 备注

- **不需要 root，不装守护进程，不改系统文件。**
- **不联网**，所有数据来自本机。
- 这是 ad-hoc 签名的自用工具，未做 Apple 公证。换机器后**建议本地重新编译**（`bash install.sh`），比拷 `.app` 更稳。
