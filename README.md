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

### 状态栏版式：为什么改用 attributedTitle

v1.1.1 之前用 `NSStackView` 嵌套子视图（每个指标一个竖排小栈，再横向并排）。能显示，但**性能代价很高**，而且不是调参能解决的：

> 只要 `NSStatusItem` 里塞的是自定义子视图，AppKit 每次刷新都会走
> `_updateReplicants` → `_redrawReplicantSnapshot:` → `_cacheDisplayInRect:toBitmapImageRep:`
> → `CALayer renderInContext` → CoreText 字形绘制
>
> 也就是**用 CPU 把整条状态栏软件光栅化成位图**。这条路径与"文字有没有变"无关，
> 2 秒一次的定时器会被放大成每秒上千次重绘。双 4K 外接屏（非镜像）下，
> 实测吃满 **50.9% 单核**。

v1.1.1 改为 `button.attributedTitle` 两行排版（`CPU/GPU/MEM/SSD` 在上、数值在下），不再有任何子视图。AppKit 对 title 走轻量文字替换，不触发上面那条路径。

中间试过单行排版，CPU 能降到 0.63%，但两行版式更接近 iStat、信息密度更高，所以最终保留两行——代价只是 1.67%（见下表）。

#### 两行怎么保证上下对齐

上下两行各自居中时，只要两行总宽不同，就会整体平移。解决办法是**两行共用同一套格宽**：

- 每格宽度 `cellWidth = max(最宽标签, 最宽数值形态) + cellPad`
- 项与项之间用**数值字体的空格**做分隔（两行用同一个字体量，否则差几个 pt）
- 格内剩余宽度用**多档宽度的空白字符**补齐：`U+2003`(em) / `U+2002`(½em) / `U+2009`(thin) / `U+200A`(hair)
- `cellPad = 4.78` 不是随手取的：两行补位字符宽度不同（标签字体 hair=0.706pt、数值字体 hair=0.820pt），这个值是对 **0–99 全部取值暴力搜索**出来的，使两行对齐误差最小

最终两行最大错位 **0.28pt**，小于一个物理像素（@2x 下 0.5pt）。

#### 为什么 `baselineOffset = -4` 是必须的

> 这是 v1.1.1 修掉的第二个坑：文字看着"贴着上边缘、下面空一截"。

`NSStatusBarButton` 的 `titleRect(forBounds:)` 实测返回 **`(0, 14, w, 16)`** —— 按钮高 22pt，但系统只给标题 **16pt**，且贴着下半部分。两行文字自然高约 20pt，超出后 AppKit 会把文字**顶部截断式地顶到上边缘**，留白全塌在底部。

试过无效的：

| 做法 | 结果 |
|---|---|
| 只设 `minimumLineHeight` | 仍贴顶（单选 min 时按最大行高分配） |
| `minimum` + `maximum` 成对设 | 总高可控了，**位置没变**，只是留白从上面挪到下面 |
| 两行都用同一字体 | 仍偏上 16px，与字体不对称无关 |
| 离线用 `NSButton` 渲染同样标题 | **是居中的**，说明问题只出在 `NSStatusBarButton` |

结论：段落样式只能改"截断多少"，**不能让文字块整体下移**。唯一手段是 `.baselineOffset`。

实测取值（M4 Air，菜单栏 30pt / 60px@2x）：

| baselineOffset | 上留白 | 下留白 |
|---|---|---|
| -2.0 | 10px | 17px |
| -3.75 | 14px | 13px |
| **-4.0** | **14px** | **13px** |
| -4.25 | 15px | 12px |

最终 **-4.0**，上下差 1px（0.5pt，@2x 最小可调单位）。

> ⚠️ 这个补偿量绑在「22pt 按钮 + 7/10pt 字号」组合上。换到菜单栏更高的系统、或切到"大"字号档时可能需要微调。

字号预设（`⌘` 菜单里可切）：小 6/9pt、标准 7/10pt、大 7/11pt。

### 状态栏刷新策略

- 刷新间隔默认 **2 秒**（菜单里可选 1 / 2 / 3 / 5 / 10 秒），`tolerance = max(1s, 间隔×20%)`，给系统合并唤醒的机会。
- **`statusItem.length` 固定**（启动时按格宽算好后钉死），不用 `variableLength`——宽度一变整个菜单栏都要重排。
- 数值没变化时不重设标题；`toolTip` 内容没变也不赋值（赋值同样是重绘触发点）。

#### 实测（上下两行版式 + 2 秒刷新）

| 机器 | 版本 | 单核占用 |
|---|---|---|
| M4 Air / 双 4K 外接屏非镜像 / 10 核 | v1.1（NSStackView） | **50.9%** |
| 同上 / 5 秒刷新 / 单行版（中间实验） | — | 0.63% |
| 同上 / **2 秒刷新 / 两行** | **v1.1.1** | **1.67%** |

`sample` 抓栈确认：剩余开销基本全是 IOKit 传感读数本身（`GPUReader` 走 `ioreg`、`TemperatureReader` 走 `io_hideventsystem_copy_event_for_service`、`DiskCapacityReader` 走 `CFURLCopyResourcePropertiesForKeys`），渲染已不是瓶颈。

换机对比请在**无高负载干扰**的环境下测，并注明机型、系统版本和屏幕配置。

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

## 版本

版本号跟随 git tag：`build.sh` 用 `git tag --points-at HEAD` 取**当前提交上的** tag（`v1.1.1` → `1.1.1`）写进 `CFBundleShortVersionString`。

**当前提交没有 tag 时，`build.sh` 会拒绝构建**并提示先打 tag。这是有意的——早期用的 `git describe --abbrev=0` 会取"最近的一个 tag"，即使 HEAD 已经领先它很多提交也照用，于是构建出来的 `.app` 顶着旧版本号。

发布流程：

```bash
# 1. 合并到 main
git checkout main && git merge --no-ff <branch>

# 2. 在 main 上打 tag（必须指向要发布的那个提交）
git tag -a v1.1.2 -m "v1.1.2 — 变更说明"

# 3. 构建（此时 HEAD 有 tag，能通过检查）
./build.sh

# 4. 推送
git push origin main && git push origin v1.1.2
gh release create v1.1.2 --title "..." --notes-file <notes>
```

只想临时构建、不需要正确版本号时：

```bash
SKIP_TAG_CHECK=1 ./build.sh     # 使用 build.sh 里的兜底版本号
```

在另一台 Mac 上「对齐版本」：

```bash
git clone https://github.com/waterliu1981/miniStat
cd miniStat && git checkout v1.1.1 && bash install.sh

# 装完确认版本
defaults read ~/Applications/miniStat.app/Contents/Info.plist CFBundleShortVersionString
```

| 版本 | 内容 |
|---|---|
| v1.1.1 | **性能大修**：状态栏改为 `attributedTitle` 两行排版，去掉 NSStackView/NSTextField 子视图，绕开 AppKit 每次刷新都做的离屏软件光栅化；单核占用 50.9% → 1.67%。**修复垂直居中**：`NSStatusBarButton.titleRect` 只有 16pt 高，用 `baselineOffset = -4` 修正。`statusItem.length` 固定；刷新默认 2 秒并带 tolerance；toolTip 去抖 |
| v1.1 | 状态栏增量刷新（稳态 CPU 1–2%）；四项指标固定单元格宽度，GPU 上两位数时整行不再跳动；列间距收紧 50% |
| v1.0 | 首个版本：CPU 温度 / GPU / 内存 / SSD 四项，免 root |

---

## 备注

- **不需要 root，不装守护进程，不改系统文件。**
- **不联网**，所有数据来自本机。
- 这是 ad-hoc 签名的自用工具，未做 Apple 公证。换机器后**建议本地重新编译**（`bash install.sh`），比拷 `.app` 更稳。
