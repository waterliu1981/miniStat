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

    private func render() {
        guard let button = statusItem.button else { return }

        // 布局方式：每个指标是一个「竖排小栈」（标签在上、数值在下），
        // 所有小栈再横向并排。实测总高 19pt，稳稳放进 22pt 状态栏。
        // 用 attributed string 拼多行会在换行处断掉，所以这里用真视图。
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 7
        container.alignment = .centerY
        container.translatesAutoresizingMaskIntoConstraints = false

        if showCPU {
            container.addArrangedSubview(makeUnit("CPU", fmtValue(metrics.cpuTemperature, decimals: 0) + "°"))
        }
        if showGPU {
            container.addArrangedSubview(makeUnit("GPU", fmtValue(metrics.gpuUtilization, decimals: 0) + "%"))
        }
        if showMEM, let f = metrics.memoryFraction {
            container.addArrangedSubview(makeUnit("MEM", String(Int((f * 100).rounded())) + "%"))
        }
        if showSSD, let f = metrics.diskCapacityFraction {
            container.addArrangedSubview(makeUnit("SSD", String(Int((f * 100).rounded())) + "%"))
        }

        // 清掉上一次的子视图，避免叠加
        for sub in button.subviews { sub.removeFromSuperview() }
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .noImage

        if container.arrangedSubviews.isEmpty {
            let title = NSTextField(labelWithString: "miniStat")
            title.font = NSFont.systemFont(ofSize: 11)
            title.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(title)
            NSLayoutConstraint.activate([
                title.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                title.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            statusItem.length = NSStatusItem.variableLength
        } else {
            // 关键：先让容器算出自然尺寸，再用它显式撑开 statusItem 宽度。
            // 若只依赖 variableLength + centerX 约束，按钮会因为不知道自己该多宽而塌成 0。
            button.addSubview(container)
            container.layoutSubtreeIfNeeded()
            let fit = container.fittingSize
            statusItem.length = fit.width + 12
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
                container.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
        }

        button.toolTip = tooltip()
    }

    /// 一个指标单元：标签在上、数值在下，纵向排列
    private func makeUnit(_ label: String, _ value: String) -> NSView {
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

        let stack = NSStackView(views: [labelField, valueField])
        stack.orientation = .vertical
        stack.spacing = lineSpacing     // 负值收紧，正值放松
        stack.alignment = .centerX
        return stack
    }

    /// 数值部分（不带单位）
    private func fmtValue(_ value: Double?, decimals: Int) -> String {
        guard let v = value else { return "--" }
        return String(format: "%.\(decimals)f", v)
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
        guard let p = sender.representedObject as? [CGFloat], p.count == 3 else { return }
        labelSize = p[0]; valueSize = p[1]; lineSpacing = p[2]
        for item in sender.menu?.items ?? [] {
            if let q = item.representedObject as? [CGFloat], q.count == 3 {
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
