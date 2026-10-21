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

    // MARK: 视图缓存（性能关键）
    //
    // 状态栏刷新曾经的做法是：每 2 秒把 button 的子视图全部拆掉、重建 4 组
    // NSStackView + 8 个 NSTextField，再 layoutSubtreeIfNeeded() + 改 statusItem.length。
    // 每次都触发 AppKit 把整棵视图树离屏光栅化成位图（_redrawReplicantSnapshot
    // -> _cacheDisplayInRect -> CALayer renderInContext -> CoreText 字形绘制），
    // 实测吃掉 50% CPU。
    //
    // 现在改成：视图只建一次，后续刷新只改 NSTextField.stringValue。
    // 文字没变化的字段不赋值，NSStatusItem 就不会被标记为需要重绘。
    //
    // 另一点：数值一律固定宽度（2 位百分比 + 2 位温度，100% 显示 99%），
    // 保证状态栏总宽恒定，避免 length 变化引发整个菜单栏重排。

    /// 每个指标单元对应的数值 label，key 用于查找
    private enum MetricKey: String, CaseIterable {
        case cpu, gpu, mem, ssd
    }

    private var valueFields: [MetricKey: NSTextField] = [:]
    /// 已渲染的数值缓存，用于跳过无变化的赋值
    private var lastRenderedValues: [MetricKey: String] = [:]
    /// 容器是否已构建
    private var containerBuilt = false

    /// 采样间隔（秒）
    private var interval: TimeInterval = 2.0

    /// 字号：标签（上行，小字）与数值（下行，大字）
    /// 状态栏厚度 22pt。实测：标签 7 + 数值 10 + 行距 0 => 恰好 22pt，
    /// 行距 +1 就会超（23pt）导致上行被切。所以 0 是最舒展且安全的取值。
    private var labelSize: CGFloat = 7
    private var valueSize: CGFloat = 10
    private var lineSpacing: CGFloat = 0

    private var showCPU = true
    private var showGPU = true
    private var showMEM = true
    private var showSSD = true

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 0.5
        RunLoop.current.add(timer!, forMode: .common)
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
    /// 这里**不**靠补零凑宽度（`00%` 看着别扭），宽度由 makeUnit 里的固定单元格
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

    private func label(for key: MetricKey) -> String {
        switch key {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .mem: return "MEM"
        case .ssd: return "SSD"
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }

        button.imagePosition = .noImage

        let keys = activeKeys

        // 首次或被切掉/恢复时重建整棵视图树；其余情况只改文字。
        if !containerBuilt {
            rebuildContainer(keys: keys)
        }

        // 只更新文字，不重建视图。文字没变化的字段不赋值，
        // AppKit 就不会把 NSStatusItem 标记为需要重绘。
        var changed = false
        for key in keys {
            let text = displayValue(for: key)
            if lastRenderedValues[key] != text {
                valueFields[key]?.stringValue = text
                lastRenderedValues[key] = text
                changed = true
            }
        }

        if changed {
            button.toolTip = tooltip()
        }
    }

    /// 构建一次视图树（仅在启动 / 勾选项变化 / 字号变化时调用）
    private func rebuildContainer(keys: [MetricKey]) {
        guard let button = statusItem.button else { return }

        for sub in button.subviews { sub.removeFromSuperview() }
        valueFields.removeAll()
        lastRenderedValues.removeAll()
        button.attributedTitle = NSAttributedString(string: "")

        if keys.isEmpty {
            let title = NSTextField(labelWithString: "miniStat")
            title.font = NSFont.systemFont(ofSize: 11)
            title.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(title)
            NSLayoutConstraint.activate([
                title.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                title.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            statusItem.length = NSStatusItem.variableLength
            containerBuilt = true
            return
        }

        // 布局方式：每个指标是一个「竖排小栈」（标签在上、数值在下），
        // 所有小栈再横向并排。实测总高 19pt，稳稳放进 22pt 状态栏。
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 7
        container.alignment = .centerY
        container.translatesAutoresizingMaskIntoConstraints = false

        for key in keys {
            let initial = displayValue(for: key)
            let unit = makeUnit(label(for: key), initial, key: key)
            container.addArrangedSubview(unit)
            lastRenderedValues[key] = initial
        }

        button.addSubview(container)
        container.layoutSubtreeIfNeeded()
        let fit = container.fittingSize
        statusItem.length = fit.width + 12
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
            container.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])

        button.toolTip = tooltip()
        containerBuilt = true
    }

    /// 一个指标单元：标签在上、数值在下，纵向排列。
    ///
    /// 单元格宽度按「最宽情况」（两位数 + 单位）预先算好并钉死，
    /// 所以 `40°` 与 `9°`、`0%` 与 `96%` 占的格子一样宽，整行宽度是常量。
    private func makeUnit(_ label: String, _ value: String, key: MetricKey) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = NSFont.systemFont(ofSize: labelSize, weight: .medium)
        // 标签也用白色高不透明度：secondaryLabelColor 的 alpha 只有 0.55，
        // 在深色菜单栏上会发灰发暗，看起来像黑色。
        labelField.textColor = NSColor.white.withAlphaComponent(0.92)
        labelField.alignment = .center
        labelField.isBezeled = false
        labelField.drawsBackground = false

        let valueField = NSTextField(labelWithString: value)
        valueField.font = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .regular)
        valueField.textColor = NSColor.white
        valueField.alignment = .center
        valueField.isBezeled = false
        valueField.drawsBackground = false

        // 缓存起来，后续刷新只改 stringValue
        valueFields[key] = valueField

        // 单元格宽度 = max(两格数字+单位, 标签) + 余量。用等宽数字字体量，
        // 保证 0–99 个位数/两位数、`--`、`.` 占位都落在同一个宽度里。
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: valueSize, weight: .regular)
        let widestValue = max(width("99" + unit(for: key), font: valueFont),
                              width("--" + unit(for: key), font: valueFont))
        let cellWidth = max(widestValue, width(label, font: labelField.font!)) + 10

        // 标签和数值都在单元格里居中；放开约束、只要最小宽度，
        // 文字怎么变都不会把格子撑宽或缩窄。
        for field in [labelField, valueField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: cellWidth).isActive = true
        }

        let stack = NSStackView(views: [labelField, valueField])
        stack.orientation = .vertical
        stack.spacing = lineSpacing     // 负值收紧，正值放松
        stack.alignment = .centerX
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: cellWidth).isActive = true
        return stack
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
        let presets: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("小",   6, 9,  -1),
            ("标准", 7, 10,  0),
            ("大",   7, 11, -1)
        ]
        for (title, l, v, sp) in presets {
            let item = NSMenuItem(title: title, action: #selector(setFontSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [l, v, sp]
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
        showCPU.toggle(); sender.state = showCPU ? .on : .off; containerBuilt = false; refresh()
    }
    @objc private func toggleGPUItem(_ sender: NSMenuItem) {
        showGPU.toggle(); sender.state = showGPU ? .on : .off; containerBuilt = false; refresh()
    }
    @objc private func toggleMEMItem(_ sender: NSMenuItem) {
        showMEM.toggle(); sender.state = showMEM ? .on : .off; containerBuilt = false; refresh()
    }
    @objc private func toggleSSDItem(_ sender: NSMenuItem) {
        showSSD.toggle(); sender.state = showSSD ? .on : .off; containerBuilt = false; refresh()
    }

    @objc private func setFontSize(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? [CGFloat], p.count == 3 else { return }
        labelSize = p[0]; valueSize = p[1]; lineSpacing = p[2]
        for item in sender.menu?.items ?? [] {
            if let q = item.representedObject as? [CGFloat], q.count == 3 {
                item.state = (q[0] == p[0] && q[1] == p[1]) ? .on : .off
            }
        }
        containerBuilt = false
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
