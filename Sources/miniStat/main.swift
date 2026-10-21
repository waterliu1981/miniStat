import AppKit
import Foundation

// MARK: - 指标模型

struct Metrics {
    var cpuTemperature: Double?
    var gpuUtilization: Double?
    var memoryFraction: Double?
    var memoryUsedBytes: Double?
    var memoryTotalBytes: Double?
    /// SSD 占用率
    var diskCapacityFraction: Double?
    var diskUsedBytes: Double?
    var diskTotalBytes: Double?
}

// MARK: - 状态栏 App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var metrics = Metrics()

    private let temperatureReader = TemperatureReader()

    // MARK: 渲染方式（性能关键）
    //
    // 演进历程（每一版都是在上一版实测后改的）：
    //
    // v1.0：每 2 秒拆掉重建 4 组 NSStackView + 8 个 NSTextField，再改 statusItem.length。
    // v1.1：视图只建一次、刷新只改 stringValue —— 实测仍约 50% CPU。
    //
    // v1.1 仍慢的原因：只要 NSStatusItem 有自定义子视图，它每次刷新都会走
    //   _updateReplicants -> _redrawReplicantSnapshot -> _cacheDisplayInRect:toBitmapImageRep:
    //   -> CALayer renderInContext -> CoreText 字形，把整条状态栏**用 CPU 软件光栅化**成位图。
    // 而且这条路径与“文字有没有变”无关：控制台定时器一 tick，就会被重投递放大，
    // 采样里看到 ~1000 次/秒的重绘。像素量 × 屏幕数，本机双 4K 下约 50% 单核。
    //
    // 现在改成：不再往 button 里塞任何子视图，改用 button.attributedTitle 做单行排版。
    // AppKit 对 title 走的是轻量文字替换，不触发上面那条离屏光栅化路径。
    //
    // 另外三条配套规则：
    //   · statusItem.length 固定，不用 variableLength（宽度一变整个菜单栏重排）；
    //   · 定时器 5 秒起，tolerance 1 秒（状态栏监控不需要秒级刷新）；
    //   · toolTip 内容没变就不赋值（赋值也是重绘触发点）。
    //
    // 宽度恒定：每个指标占一个固定宽度的格（按键位宽度 + 余量算好），
    // 用 monospacedDigit 字体 + 逐个字段的 .kern 把每格撑到恰好 cellWidth，
    // 所以 0% 与 99%、--° 都落在同一个盒子里，整条标题宽度是常量。

    private enum MetricKey: String, CaseIterable {
        case cpu, gpu, mem, ssd
    }

    /// 已渲染的数值缓存，用于跳过无变化的赋值
    private var lastRenderedValues: [MetricKey: String] = [:]
    /// 已应用的排版配置，变化时才重算定宽（不触发刷新）
    private var appliedLayoutKey: String?
    /// 已设置过的 toolTip，内容相同就不重复赋值
    private var lastToolTip: String?

    /// 采样间隔（秒）
    private var interval: TimeInterval = 5.0

    /// 标签槽宽度（所有标签补齐到这个宽度）
    private var labelSlot: CGFloat = 0
    /// 数值槽宽度（所有数值补齐到这个宽度，保证 9° 与 99° 同宽）
    private var valueSlot: CGFloat = 0

    /// 字号：标签（上行，小字）与数值（下行，大字）
    /// 状态栏厚度 22pt。实测：标签 7 + 数值 10 + 行距 0 => 恰好 22pt，
    /// 行距 +1 就会超（23pt）导致上行被切。所以 0 是最舒展且安全的取值。
    private var labelSize: CGFloat = 7
    private var valueSize: CGFloat = 10

    private var showCPU = true
    private var showGPU = true
    private var showMEM = true
    private var showSSD = true

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // variableLength 会随标题宽度变化触发菜单栏重排；这里算好宽度后钉死。
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.button?.imagePosition = .noImage

        buildMenu()
        refresh()
        startTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    @objc private func handleScreenChange() {
        refresh()
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // 容差 1 秒（或间隔的 20%，取大者）：给系统合并唤醒的机会，省电。
        t.tolerance = max(1.0, interval * 0.2)
        timer = t
        RunLoop.current.add(t, forMode: .common)
    }

    // MARK: 采样

    @objc private func refresh() {
        // 温度与 GPU 走 IOKit，很轻；放在主线程也不会阻塞
        metrics.cpuTemperature = temperatureReader?.cpuTemperature()
        metrics.gpuUtilization = GPUReader.utilization()

        if let m = MemoryReader.sample() {
            metrics.memoryFraction = m.fraction
            metrics.memoryUsedBytes = m.usedBytes
            metrics.memoryTotalBytes = m.totalBytes
        }

        // SSD 占用率走 URLResourceValues，很轻，主线程直接读
        if let d = DiskCapacityReader.sample() {
            metrics.diskCapacityFraction = d.fraction
            metrics.diskUsedBytes = d.usedBytes
            metrics.diskTotalBytes = d.totalBytes
        }

        render()
    }

    // MARK: 渲染

    /// 当前应显示的指标键（按菜单开关过滤）
    private var activeKeys: [MetricKey] {
        var keys: [MetricKey] = []
        if showCPU { keys.append(.cpu) }
        if showGPU { keys.append(.gpu) }
        if showMEM { keys.append(.mem) }
        if showSSD { keys.append(.ssd) }
        return keys
    }

    /// 把某项指标格式化成本次要显示的文字。
    ///
    /// 这里**不**靠补零凑宽度（`00%` 看着别扭），宽度由 buildTitle 里的固定单元格
    /// 保证：每格宽度按「两位数 + 单位」的最宽情况算出来，数值再怎么变都不撑格。
    ///
    /// 为什么不能只靠数字对齐：`%.0f` 的 `0%` 比 `96%` 窄一个数字宽，
    /// 数值行 .center 对齐、父栈 .centerX，任何一格变宽都会把整行重新居中 ——
    /// 肉眼就是 GPU 一上两位数、后面几列被推着右移。
    private func displayValue(for key: MetricKey) -> String {
        switch key {
        case .cpu: return format(metrics.cpuTemperature, unit: "°")
        case .gpu: return format(metrics.gpuUtilization, unit: "%")
        case .mem: return format(metrics.memoryFraction.map { $0 * 100 }, unit: "%")
        case .ssd: return format(metrics.diskCapacityFraction.map { $0 * 100 }, unit: "%")
        }
    }

    /// 取整显示，上限 99（100% 也显示 99%，不超过两格数字）。
    /// 无数据时显示 `--`，与原来一致；宽度由单元格固定，不需要补位。
    private func format(_ value: Double?, unit: String) -> String {
        guard let v = value else { return "--" + unit }
        return String(format: "%.0f", min(max(v, 0), 99)) + unit
    }

    /// 单位：温度用 `°`，其余都是 `%`
    private func unit(for key: MetricKey) -> String {
        key == .cpu ? "°" : "%"
    }

    private func label(for key: MetricKey) -> String {
        switch key {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .mem: return "MEM"
        case .ssd: return "SSD"
        }
    }

    // MARK: 渲染（attributedTitle，单行定宽）

    /// 排版配置指纹：字号/行距/是否全隐藏。变了才重算定宽。
    private var layoutKey: String {
        "\(labelSize)/\(valueSize)/\(activeKeys.map { $0.rawValue }.joined())"
    }

    /// 状态栏可用高度（菜单栏厚度，通常 22 或 24）
    private var barHeight: CGFloat {
        NSScreen.main?.frame.height == 0 ? 22 : NSStatusBar.system.thickness
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let keys = activeKeys

        // 1. 排版/宽度：只在配置或字体变化时算一次
        if appliedLayoutKey != layoutKey {
            applyLayout(keys: keys)
        }

        // 2. 文字：没变就不重设，避免无谓的重绘
        var changed = false
        for key in keys {
            let text = displayValue(for: key)
            if lastRenderedValues[key] != text {
                lastRenderedValues[key] = text
                changed = true
            }
        }
        if changed || appliedTitle == nil {
            let title = buildTitle(keys: keys)
            if title.string != appliedTitle {
                button.attributedTitle = title
                appliedTitle = title.string
            }
        }

        // 3. toolTip：内容相同就不赋值（赋值同样是重绘触发点）
        let tip = tooltip()
        if tip != lastToolTip {
            button.toolTip = tip
            lastToolTip = tip
        }
    }

    /// 已应用的标题文本，用于对比跳过
    private var appliedTitle: String?

    /// 计算并应用定宽、statusItem.length。不触发状态栏重绘。
    private func applyLayout(keys: [MetricKey]) {
        appliedLayoutKey = layoutKey
        appliedTitle = nil
        lastRenderedValues.removeAll()

        guard !keys.isEmpty else {
            statusItem.length = width("miniStat", font: NSFont.systemFont(ofSize: 11)) + 12
            return
        }

        let lf = labelFont(), vf = valueFont()

        // 标签槽 = 最宽标签
        labelSlot = keys.map { width(label(for: $0), font: lf) }.max() ?? 0
        // 数值槽 = 最宽数值形态（两位数字 + 单位，或无数据时的 --）
        var v: CGFloat = 0
        for key in keys {
            let u = unit(for: key)
            v = max(v, width("99" + u, font: vf), width("--" + u, font: vf))
        }
        valueSlot = v

        let total = CGFloat(keys.count) * itemWidth + CGFloat(keys.count - 1) * width("  ", font: lf)
        statusItem.length = total + 12   // 左右各 6pt 内边距
    }

    /// 拼出单行标题：`CPU 38°  GPU 31%  MEM 60%  SSD 78%`。
    ///
    /// 为什么从两行改成单行：两行要同时维护「上行标签」「下行数值」两条居中轴线，
    /// 任何一行宽度变化都会让另一行整体平移；而 AppKit 状态栏标题不支持逐格定宽
    /// （空格会被压缩、kern 会被按 run 长度相乘），两行方案必然出现水平错位。
    /// 单行只有一条轴线，再加「标签槽 + 数值槽」两级定宽，宽度就是常量。
    private func buildTitle(keys: [MetricKey]) -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: labelSize, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .regular)
        let labelColor = NSColor.white.withAlphaComponent(0.92)
        let valueColor = NSColor.white

        let out = NSMutableAttributedString()
        for (i, key) in keys.enumerated() {
            // 标签槽：补齐到最宽标签，右对齐贴向数值
            let lbl = label(for: key)
            out.append(NSAttributedString(string: lbl, attributes: [.font: labelFont, .foregroundColor: labelColor]))
            out.append(NSAttributedString(string: padding(to: labelSlot - width(lbl, font: labelFont), font: labelFont),
                                          attributes: [.font: labelFont]))
            // 标签与数值之间一个空格
            out.append(NSAttributedString(string: " ", attributes: [.font: labelFont]))
            // 数值槽：先放数值，再补齐到最宽数值，保证 9° 与 99° 同宽
            let val = displayValue(for: key)
            out.append(NSAttributedString(string: val, attributes: [.font: valueFont, .foregroundColor: valueColor]))
            out.append(NSAttributedString(string: padding(to: valueSlot - width(val, font: valueFont), font: valueFont),
                                          attributes: [.font: valueFont]))
            // 项间分隔：两个空格（最后一格不加，保持右边缘对称）
            if i != keys.count - 1 {
                out.append(NSAttributedString(string: "  ", attributes: [.font: labelFont]))
            }
        }
        return out
    }

    /// 用多种宽度的空格贪心补齐到指定宽度。
    /// AppKit 会压缩连续空格，所以这里用不同宽度的空白字符（em/半em/thin/hair）
    /// 拼出接近目标宽度的补偿，误差小于 1 个 hair space（约 0.7pt）。
    private func padding(to target: CGFloat, font: NSFont) -> String {
        guard target > 0 else { return "" }
        var rem = target
        var s = ""
        for p in Self.padCharacters {
            let pw = width(p, font: font)
            guard pw > 0 else { continue }
            let n = Int((rem / pw).rounded(.down))
            if n > 0 {
                s += String(repeating: p, count: n)
                rem -= CGFloat(n) * pw
            }
        }
        return s
    }

    /// 补齐用的空白字符，从宽到窄
    private static let padCharacters: [String] = ["\u{2003}", "\u{2002}", "\u{2009}", "\u{200A}"]

    /// 每个指标占用的固定宽度（标签槽 + 空格 + 数值槽）
    private var itemWidth: CGFloat { labelSlot + width(" ", font: labelFont()) + valueSlot }

    private func labelFont() -> NSFont {
        NSFont.systemFont(ofSize: labelSize, weight: .medium)
    }

    private func valueFont() -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .regular)
    }

    /// 量文字宽度（用于算固定单元格宽度）
    private func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func tooltip() -> String {
        var lines: [String] = ["miniStat — 轻量系统监控"]
        if let t = metrics.cpuTemperature {
            lines.append(String(format: "CPU 温度：%.1f °C", t))
        }
        if let g = metrics.gpuUtilization {
            lines.append(String(format: "GPU 利用率：%.0f %%", g))
        }
        if let used = metrics.memoryUsedBytes, let total = metrics.memoryTotalBytes {
            lines.append(String(format: "内存：%.1f / %.1f GB（%.0f %%）",
                               used / 1073741824, total / 1073741824,
                               (metrics.memoryFraction ?? 0) * 100))
        }
        if let used = metrics.diskUsedBytes, let total = metrics.diskTotalBytes {
            lines.append(String(format: "SSD 容量：%.1f / %.1f GB（%.0f %%）",
                               used / 1073741824, total / 1073741824,
                               (metrics.diskCapacityFraction ?? 0) * 100))
        }
        if let temp = temperatureReader {
            lines.append("温度传感器：\(temp.sensorCount) 个")
        } else {
            lines.append("温度传感器：不可用")
        }
        lines.append("刷新间隔：\(Int(interval)) 秒")
        return lines.joined(separator: "\n")
    }

    // MARK: 菜单

    private func buildMenu() {
        let menu = NSMenu()

        let toggleCPU = NSMenuItem(title: "显示 CPU 温度", action: #selector(toggleCPUItem), keyEquivalent: "1")
        toggleCPU.state = showCPU ? .on : .off
        toggleCPU.target = self
        menu.addItem(toggleCPU)

        let toggleGPU = NSMenuItem(title: "显示 GPU 使用率", action: #selector(toggleGPUItem), keyEquivalent: "2")
        toggleGPU.state = showGPU ? .on : .off
        toggleGPU.target = self
        menu.addItem(toggleGPU)

        let toggleMEM = NSMenuItem(title: "显示内存使用率", action: #selector(toggleMEMItem), keyEquivalent: "3")
        toggleMEM.state = showMEM ? .on : .off
        toggleMEM.target = self
        menu.addItem(toggleMEM)

        let toggleSSD = NSMenuItem(title: "显示 SSD 吞吐", action: #selector(toggleSSDItem), keyEquivalent: "4")
        toggleSSD.state = showSSD ? .on : .off
        toggleSSD.target = self
        menu.addItem(toggleSSD)

        menu.addItem(.separator())

        // 字号档位：同时给出「标签 + 数值 + 行距」三件套，
        // 保证加起来不超过状态栏 22pt 厚度
        let sizeMenu = NSMenu()
        // (标题, 标签字号, 数值字号)。单行排版后不再需要行距参数：
        // 高度要么放得下要么放不下，由菜单栏厚度决定，不需要用行距去凑。
        let presets: [(String, CGFloat, CGFloat)] = [
            ("小",   6, 9),
            ("标准", 7, 10),
            ("大",   7, 11)
        ]
        for (title, l, v) in presets {
            let item = NSMenuItem(title: title, action: #selector(setFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [l, v]
            item.state = (l == labelSize && v == valueSize) ? .on : .off
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "字号", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let intervalMenu = NSMenu()
        for secs in [1, 2, 3, 5, 10] {
            let item = NSMenuItem(title: "\(secs) 秒", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = (Double(secs) == interval) ? .on : .off
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "刷新间隔", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 miniStat", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func toggleCPUItem(_ sender: NSMenuItem) {
        showCPU.toggle(); sender.state = showCPU ? .on : .off; refresh()
    }
    @objc private func toggleGPUItem(_ sender: NSMenuItem) {
        showGPU.toggle(); sender.state = showGPU ? .on : .off; refresh()
    }
    @objc private func toggleMEMItem(_ sender: NSMenuItem) {
        showMEM.toggle(); sender.state = showMEM ? .on : .off; refresh()
    }
    @objc private func toggleSSDItem(_ sender: NSMenuItem) {
        showSSD.toggle(); sender.state = showSSD ? .on : .off; refresh()
    }

    @objc private func setFontSize(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [CGFloat], p.count == 2 else { return }
        labelSize = p[0]; valueSize = p[1]
        for item in sender.menu?.items ?? [] {
            if let q = item.representedObject as? [CGFloat], q.count == 2 {
                item.state = (q[0] == p[0] && q[1] == p[1]) ? .on : .off
            }
        }
        refresh()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? Int else { return }
        interval = TimeInterval(secs)
        for item in sender.menu?.items ?? [] {
            item.state = ((item.representedObject as? Int) == secs) ? .on : .off
        }
        startTimer()
        refresh()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 只在状态栏出现，不占 Dock
app.run()
