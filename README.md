<div align="center">

# miniStat

**macOS 菜单栏上的 CPU / GPU / 内存 / 硬盘监控，小巧、好看、几乎不占资源。**

只有你真正关心的四个数字，别的什么也没有。

[![Release](https://img.shields.io/github/v/release/waterliu1981/miniStat?color=blue)](https://github.com/waterliu1981/miniStat/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)](https://github.com/waterliu1981/miniStat)
[![CPU](https://img.shields.io/badge/CPU-单核1.67%25-brightgreen)](#性能)
[![Memory](https://img.shields.io/badge/内存-19MB-brightgreen)](#性能)

<img src="docs/screenshots/menubar.png" alt="miniStat 在 macOS 菜单栏中的样子" width="900">

[English](README.en.md) · [下载最新版](https://github.com/waterliu1981/miniStat/releases) · [反馈问题](https://github.com/waterliu1981/miniStat/issues)

</div>

---

## 为什么用 miniStat？

大多数系统监控工具都很强大，也很重——几十个图表、后台守护进程、登录项、联网上报、root 助手进程。

miniStat 走的是相反的路子。它只回答一个一眼就能看完的问题：

> *我的 Mac 烫不烫？GPU 在忙吗？内存够不够？硬盘快满了吗？*

然后就安静地待在角落里，不打扰你。

| | |
|---|---|
| **一眼看完** | 两行：上面是标签，下面是数值。不用悬停、不用点开菜单。 |
| **轻如鸿毛** | App 体积 **184 KB**，内存 **19 MB**，CPU **单核 1.67%**。 |
| **无守护进程、无需 root** | 就是一个普通用户态 App（`LSUIElement`）。没有辅助进程，没有特权安装。 |
| **不联网** | 一次连接都不发起。所有数据都在本机读取。 |
| **删掉即干净** | 不改任何系统文件。拖进废纸篓就彻底没了。 |
| **看着舒服** | 和菜单栏像素级对齐。数字不会跳、不会晃。 |

---

## 显示什么

```
 CPU   GPU   MEM   SSD
 34°   13%   51%   77%
```

| 指标 | 含义 | 数据来源 |
|---|---|---|
| **CPU** | CPU 温度（°C） | Apple Silicon HID 温度传感器（`tdie`/`tcal` 均值） |
| **GPU** | GPU 使用率（%） | `ioreg` 的 `AGXAccelerator` |
| **MEM** | 内存使用率（%） | `host_statistics64` —— 与「活动监视器」同口径 |
| **SSD** | 硬盘占用率（%） | `URLResourceValues` —— 与 Finder 同口径 |

用官方数据源的好处是：**数字和活动监视器、Finder 对得上**，你不必在两套说法之间纠结。

---

## 安装

需要 macOS 13+ 和 Xcode Command Line Tools。

```bash
# 一条命令完成：编译 → 部署 → 配置开机自启
git clone https://github.com/waterliu1981/miniStat
cd miniStat && bash install.sh
```

装完就在菜单栏上出现了。App 落在 `~/Applications`，并注册为登录启动项。

**确认在跑：**

```bash
pgrep -x miniStat
defaults read ~/Applications/miniStat.app/Contents/Info.plist CFBundleShortVersionString
```

**卸载**——干干净净，不留任何残留：

```bash
launchctl bootout gui/$(id -u)/local.waterliu.ministat
rm -rf ~/Applications/miniStat.app
rm ~/Library/LaunchAgents/local.waterliu.ministat.plist
```

---

## 性能

测试环境：**M4 MacBook Air，10 核，外接双 4K 显示器（非镜像），2 秒刷新：**

| | miniStat v1.1.1+ |
|---|---|
| CPU | **单核 1.67%**（整机 0.167%） |
| 内存 | **19 MB** |
| App 体积 | **184 KB** |
| 进程数 | **1**（没有辅助进程） |
| 后台守护进程 | **0** |

作为对照，同一个 App 如果用 `NSStatusItem` 子视图实现（v1.1 的做法），要吃掉**半个核（50.9%）**——差了 30 倍。原因全在下面的[实现原理](#实现原理)里，是一个挺有意思的 macOS 坑。

---

## 实现原理

### 陷阱：菜单栏里的自定义视图，每次刷新都会被软件光栅化

做一个两行菜单栏项目最直觉的做法，是往 status item 的 button 里塞一堆 `NSTextField`。能用——但 AppKit 只要发现 `NSStatusItem` 里有自定义子视图，每次标记为需要重绘时，就会**用 CPU 把整个项目重新渲染一遍**：

```
_updateReplicants
 └ _redrawReplicantSnapshot:
   └ _cacheDisplayInRect:toBitmapImageRep:
     └ CALayer renderInContext          ← 软件光栅化
       └ CTFontTransformGlyphs / CTFontDrawGlyphs
```

这条路径**根本不管你的文字有没有变**。一个 2 秒一次的定时器会被放大成**每秒上千次重绘**。接两块 4K 屏时，就是常年半颗核。

**解决办法：** 彻底去掉子视图，改用 `button.attributedTitle`。AppKit 走的是轻量文字替换，永远进不到那条快照路径。

### 没有子视图，怎么让两行上下对齐

用 `attributedTitle` 时，两行必须共用**同一套格线**，否则上面那行会随着数值宽度变化而整体平移。

- **格宽** = `max(最宽标签, 最宽数值形态) + 余量`
- **项间分隔**两行都用*数值字体*的空格（否则两行会差好几个点）
- **格内补齐**用多档宽度的空白字符：`U+2003`、`U+2002`、`U+2009`、`U+200A`
- 补齐常数 `4.78` 不是随手取的——它是对 **0–99 全部取值暴力搜出来的**（两种字体的 hair space 宽度不同：0.706pt 和 0.820pt）

结果：两行最大错位 **0.28pt**，在 Retina 屏上不到一个物理像素。

> 两个走过才知道的死胡同：`.kern` 在 CoreText 里会被**乘以 run 的字符数**；连续空格会被**压缩**。两者都不能用来做定宽排版。

### 为什么必须 `baselineOffset = -4`

`NSStatusBarButton` 的 `titleRect(forBounds:)` 实测返回 **`(0, 14, w, 16)`**——按钮高 22pt，但系统只给标题 **16pt**，而且还贴在下半部分。两行文字自然高约 20pt，超出后 AppKit 会把文字**顶部截断式地顶到上边缘**，多出来的空间全塌在底部。

行高参数（`minimumLineHeight` / `maximumLineHeight`）只能改*截断多少*，没法让整块文字下移。唯一有效的手段是 `.baselineOffset`。

| baselineOffset | 上留白 | 下留白 |
|---|---|---|
| -2.0 | 10px | 17px |
| -3.75 | 14px | 13px |
| **-4.0** | **14px** | **13px** |
| -4.25 | 15px | 12px |

最终取 **-4.0**——上下差 1px（0.5pt），已是 2 倍屏下能调的最小单位。

### CPU 温度是怎么读到的

在 Apple Silicon 上，`AppleSMC` 已经迁移到 RTBuddy/SOCD 架构——普通进程能 `IOServiceOpen` 成功，但**一个 key 都读不出来**。

miniStat 走的是和 iStat Menus 相同的路径：IOKit 的私有 HID 事件系统，匹配 `PrimaryUsagePage=0xff00` / `PrimaryUsage=5`，通过 `dlsym` 解析 `IOHIDEventSystemClient*` 系列私有符号。**不需要 root。**

两个坑，代码注释里都标了：

1. `IOHIDEventSystemClientSetMatching` 返回 `Void` 而不是 `Int32`——签名搞错直接段错误。
2. client 必须**持有引用**——服务引用只在 client 存活期间有效，释放后再访问会 `SIGBUS`。

### SSD 占用率的口径陷阱

**别用 `df /`**——macOS 上 `/` 是只读系统卷，会报出 ~19% 的假值。要用 `/System/Volumes/Data`，或者直接用 `URLResourceValues`（Finder 用的就是它，miniStat 也是）。

---

## 自定义

右键菜单栏图标：

- **⌘1 – ⌘4** —— 逐项开关四个指标
- **字号** —— 小 / 标准 / 大
- **刷新间隔** —— 1 / 2 / 3 / 5 / 10 秒（默认 2 秒）

鼠标悬停有 tooltip，显示一位小数的精确值和探测到的温度传感器数量。

---

## 常见问题

**需要 root 吗？**
不需要。全部在用户态运行。

**会联网上报吗？**
不会。不发起任何形式的网络连接。

**Intel Mac 能用吗？**
GPU 和温度两条路径是 Apple Silicon 专用的，Intel 尚未支持。

**为什么 100% 显示成 99%？**
定宽显示，避免菜单栏反复重排。限制在两位数字让每个数值宽度一致。

**能和 iStat Menus 同时开吗？**
技术上可以，但等于把同一批传感器读两遍。仓库里有个 `disable-istat-daemon.sh`，如果打算切换过去可以用。

---

## 从源码构建

```bash
./build.sh                    # 编译 → 打包 → ad-hoc 签名 → 部署
SKIP_TAG_CHECK=1 ./build.sh   # 本地实验时跳过 tag 检查
```

只依赖系统自带 `swiftc`。不装第三方包，不联网。

发布流程：

```bash
git checkout main && git merge --no-ff <branch>
git tag -a v1.2.0 -m "v1.2.0 — 说明"
./build.sh                     # HEAD 上必须有 tag，否则拒绝构建
git push origin main && git push origin v1.2.0
```

---

## 版本历史

| 版本 | 内容 |
|---|---|
| **v1.1.2** | `build.sh` 在 `HEAD` 没有 tag 时拒绝构建，防止打出旧版本号 |
| **v1.1.1** | **性能大修**：改用 `attributedTitle` 去掉子视图，单核 50.9% → **1.67%**。**垂直居中修复**（`titleRect` 只有 16pt，用 `baselineOffset = -4` 修正）。`statusItem.length` 固定，2 秒刷新带 tolerance，tooltip 去抖 |
| v1.1 | 状态栏增量刷新；四项指标固定单元格宽度，GPU 上两位数时整行不再跳动；列间距收紧 50% |
| v1.0 | 首个版本：CPU 温度 / GPU / 内存 / SSD，免 root |

---

## 许可

[MIT](LICENSE)

---

<div align="center">

**做给那些想「知道」、但不想「被打扰」的人。**

如果 miniStat 帮你省下了几次点击菜单栏的动作，欢迎[点个 Star](https://github.com/waterliu1981/miniStat)。

</div>
