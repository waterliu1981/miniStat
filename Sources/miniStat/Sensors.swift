import Foundation
import IOKit
import IOKit.hid

// MARK: - CPU 温度（Apple Silicon HID 温度传感器）
//
// Apple Silicon 上 SMC 已迁到 RTBuddy/SOCD，非特权进程读不到 key；
// 系统真实的温度传感器通过 IOKit 的私有 HID 事件系统暴露。
// 这里用 dlsym 解析私有符号，走的是与 iStat Menus 的 HIDSensors 相同的路径。
// 只要 PrimaryUsagePage=0xff00 / PrimaryUsage=5 就能拿到全部温度传感器。
final class TemperatureReader {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopySvcFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private let copyProp: CopyPropFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [CFTypeRef] = []
    /// 必须持有 client：服务引用只在 client 存活期间有效，
    /// client 一旦释放，后续访问服务会直接 SIGBUS。
    private let client: CFTypeRef

    // kIOHIDEventTypeTemperature
    private let tempEventType: Int64 = 15

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatch = sym("IOHIDEventSystemClientSetMatching", SetMatchFn.self),
              let copySvc = sym("IOHIDEventSystemClientCopyServices", CopySvcFn.self),
              let cp = sym("IOHIDServiceClientCopyProperty", CopyPropFn.self),
              let ce = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let gf = sym("IOHIDEventGetFloatValue", GetFloatFn.self)
        else { return nil }

        copyProp = cp
        copyEvent = ce
        getFloat = gf

        guard let clientRef = create(kCFAllocatorDefault) else { return nil }
        let c = clientRef.takeRetainedValue()
        self.client = c

        setMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let arrRef = copySvc(c) else { return nil }
        let arr = arrRef.takeRetainedValue()
        let n = CFArrayGetCount(arr)
        for i in 0..<n {
            guard let p = CFArrayGetValueAtIndex(arr, i) else { continue }
            services.append(Unmanaged<CFTypeRef>.fromOpaque(p).takeUnretainedValue())
        }
    }

    /// 单个传感器的摄氏温度；读不到返回 nil
    private func value(of svc: CFTypeRef) -> Double? {
        guard let evRef = copyEvent(svc, tempEventType, 0, 0) else { return nil }
        let ev = evRef.takeRetainedValue()
        let t = getFloat(ev, Int32(tempEventType << 16))
        // 明显异常的读数（负值或超高）视为无效
        guard t > 0, t < 130 else { return nil }
        return t
    }

    private func name(of svc: CFTypeRef) -> String {
        (copyProp(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
    }

    /// CPU 温度：所有 CPU 核心裸片（tdie）与校准点（tcal）的均值
    func cpuTemperature() -> Double? {
        var vals: [Double] = []
        for svc in services {
            let n = name(of: svc)
            guard n.contains("tdie") || n.contains("tcal") else { continue }
            if let v = value(of: svc) { vals.append(v) }
        }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// GPU 温度：PMU 中标识为 GPU 的传感器（tdev*），用于参考
    func gpuTemperature() -> Double? {
        var vals: [Double] = []
        for svc in services {
            let n = name(of: svc)
            guard n.contains("tdev") else { continue }
            if let v = value(of: svc) { vals.append(v) }
        }
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    var sensorCount: Int { services.count }
}

// MARK: - GPU 使用率
//
// AGXAccelerator 的 PerformanceStatistics 里有系统自报的利用率，
// 无需 root、无需 powermetrics。整机只有一块 GPU，取最大值即可。
enum GPUReader {
    static func utilization() -> Double? {
        guard let s = IORegistryReader.run(
            service: "AGXAccelerator",
            arguments: ["-r", "-d", "1", "-w", "0", "-c", "AGXAccelerator"]) else { return nil }

        // 取所有匹配到的 "Device Utilization %" 中的最大值
        var best: Double?
        var searchRange = s.startIndex..<s.endIndex
        while let r = s.range(of: "\"Device Utilization %\"=", range: searchRange) {
            let rest = s[r.upperBound...]
            if let v = Double(rest.prefix(while: { $0.isNumber })) {
                best = max(best ?? v, v)
            }
            searchRange = rest.startIndex..<s.endIndex
        }
        return best
    }
}

// MARK: - 内存使用率
enum MemoryReader {
    struct Sample {
        var usedBytes: Double
        var totalBytes: Double
        var fraction: Double
    }

    static func sample() -> Sample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = Double(pageSize)

        // 与「活动监视器」口径对齐：App 内存 + 联动内存 + 被压缩内存
        let active = Double(stats.active_count) * ps
        let wired = Double(stats.wire_count) * ps
        let compressed = Double(stats.compressor_page_count) * ps
        let used = active + wired + compressed

        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }
        return Sample(usedBytes: used, totalBytes: total, fraction: used / total)
    }
}

// MARK: - SSD 容量占用率
//
// 注意口径陷阱：`df /` 在 macOS 上看的是只读系统快照，会报出 ~19% 的假值。
// 真实占用率必须走 URLResourceValues（Finder 同一套 API），它读的是数据卷整体。
// 这里用「普通可用」口径，与 Finder / 关于本机显示一致。
enum DiskCapacityReader {
    struct Sample {
        var usedBytes: Double
        var totalBytes: Double
        var fraction: Double
    }

    static func sample() -> Sample? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, total > 0 else { return nil }

        // 优先用「普通可用」；取不到则退回「重要用途可用」
        let avail: Int
        if let a = v.volumeAvailableCapacity {
            avail = a
        } else if let a = v.volumeAvailableCapacityForImportantUsage {
            avail = Int(a)
        } else {
            return nil
        }

        let totalD = Double(total)
        let used = max(0, totalD - Double(avail))
        return Sample(usedBytes: used, totalBytes: totalD, fraction: used / totalD)
    }
}

// MARK: - ioreg 读取公用
enum IORegistryReader {
    static func run(service: String, arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
