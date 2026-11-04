import Darwin
import Foundation
import IOKit

/// One sample of the system load for the performance overlay.
struct SystemSample: Equatable {
    var cpu: Double?            // 0...1, all cores
    var gpu: Double?            // 0...1, "Device Utilization %"
    var memoryUsed: UInt64?     // Bytes: active + wired + compressed
    var memoryTotal: UInt64
    var temperature: Double?    // °C, the hottest die sensor
    var thermal: ProcessInfo.ThermalState

    var lines: [String] {
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        var lines = ["CPU \(percent(cpu))   GPU \(percent(gpu))"]
        if let used = memoryUsed {
            // GiB (2^30 bytes), as macOS shows the memory size: a 64 GB Mac shows 64.
            let gib = 1_073_741_824.0
            lines.append(String(format: "Memory %.1f / %.0f GB", Double(used) / gib, Double(memoryTotal) / gib))
        }
        lines.append([temperature.map { String(format: "Chip %.0f °C", $0) }, "Thermal \(Self.name(thermal))"]
            .compactMap { $0 }.joined(separator: "   "))
        return lines
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "normal"
        case .fair: "fair"
        case .serious: "high"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Reads CPU, GPU, memory, and temperature without root rights.
/// - CPU: host_processor_info, the change since the last sample.
/// - GPU: the "PerformanceStatistics" of the IOAccelerator service.
/// - Temperature: the HID temperature sensors (the same source as system tools use).
final class SystemStats {
    private var lastTicks: [UInt32]?

    func sample() -> SystemSample {
        SystemSample(cpu: cpuUsage(), gpu: Self.gpuUsage(), memoryUsed: Self.memoryUsed(),
                     memoryTotal: ProcessInfo.processInfo.physicalMemory,
                     temperature: Self.temperature(), thermal: ProcessInfo.processInfo.thermalState)
    }

    // MARK: CPU

    private func cpuUsage() -> Double? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard let lastTicks, lastTicks.count == ticks.count else { return nil }
        return Self.cpuUsage(previous: lastTicks, current: ticks)
    }

    /// The busy part of the ticks between two samples. Each CPU has four counters:
    /// user, system, idle, nice (CPU_STATE_MAX).
    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double? {
        let states = Int(CPU_STATE_MAX)
        guard previous.count == current.count, current.count % states == 0 else { return nil }
        var busy: UInt64 = 0, total: UInt64 = 0
        for cpu in stride(from: 0, to: current.count, by: states) {
            for state in 0..<states {
                let delta = UInt64(current[cpu + state] &- previous[cpu + state])
                total += delta
                if state != Int(CPU_STATE_IDLE) { busy += delta }
            }
        }
        return total == 0 ? nil : Double(busy) / Double(total)
    }

    // MARK: GPU

    static func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            if let stats = value?.takeRetainedValue() as? [String: Any], let usage = gpuUsage(stats) {
                best = max(best ?? 0, usage)
            }
        }
        return best
    }

    static func gpuUsage(_ stats: [String: Any]) -> Double? {
        guard let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    // MARK: Memory

    static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    // MARK: Temperature

    /// The hottest die sensor ("PMU tdie…"). Other sensors give values that are not
    /// temperatures on some chips (for example "PMU tdev" near -9200), so only
    /// values from 0 to 150 °C count.
    static func temperature(from sensors: [(name: String, value: Double)]) -> Double? {
        let valid = sensors.filter { (0...150).contains($0.value) }
        let dies = valid.filter { $0.name.lowercased().contains("tdie") }
        return (dies.isEmpty ? valid : dies).map(\.value).max()
    }

    static func temperature() -> Double? {
        temperature(from: TemperatureSensors.read())
    }
}

/// The HID temperature sensors of Apple silicon. These IOHIDEventSystem functions
/// are not public API; they are looked up at run time, and a missing function
/// gives no temperature instead of a crash.
enum TemperatureSensors {
    private typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let temperatureEvent: Int64 = 15   // kIOHIDEventTypeTemperature

    static func read() -> [(name: String, value: Double)] {
        guard let create = symbol("IOHIDEventSystemClientCreate", Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = symbol("IOHIDEventGetFloatValue", FloatValue.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        // Usage page 0xff00, usage 5: the temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        var result: [(name: String, value: Double)] = []
        for service in services {
            let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
            guard let event = copyEvent(service, temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            result.append((name, floatValue(event, Int32(temperatureEvent << 16))))
        }
        return result
    }
}
