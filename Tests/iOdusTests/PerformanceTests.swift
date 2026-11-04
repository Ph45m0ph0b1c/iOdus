import XCTest
@testable import iOdus

final class PerformanceTests: XCTestCase {
    func testCPUUsageUsesTheChangeOfTheBusyTicks() {
        // Two CPUs: user, system, idle, nice.
        let before: [UInt32] = [100, 50, 800, 0, 10, 10, 980, 0]
        let after: [UInt32] = [160, 70, 820, 0, 30, 10, 1040, 0]
        // Busy: 60+20 + 20 = 100. Total: 100 + 20 + 60 = 180.
        XCTAssertEqual(SystemStats.cpuUsage(previous: before, current: after)!, 100.0 / 180.0, accuracy: 0.0001)
        XCTAssertNil(SystemStats.cpuUsage(previous: before, current: before), "No ticks: no value")
        XCTAssertNil(SystemStats.cpuUsage(previous: [1, 2], current: [1, 2, 3, 4]))
    }

    func testGPUUsageReadsDeviceUtilization() {
        XCTAssertEqual(SystemStats.gpuUsage(["Device Utilization %": 78, "Renderer Utilization %": 70]), 0.78)
        XCTAssertNil(SystemStats.gpuUsage(["Renderer Utilization %": 70]))
    }

    func testTemperaturePrefersDieSensorsAndDropsBadValues() {
        let sensors: [(name: String, value: Double)] = [
            ("PMU tdev1", -9201), ("NAND CH0 temp", 38), ("PMU tdie1", 61.5), ("PMU tdie2", 70.2), ("PMU tcal", 51.8),
        ]
        XCTAssertEqual(SystemStats.temperature(from: sensors), 70.2)
        XCTAssertEqual(SystemStats.temperature(from: [("NAND CH0 temp", 38), ("x", -5)]), 38)
        XCTAssertNil(SystemStats.temperature(from: [("PMU tdev1", -9201)]))
    }

    func testPanelLines() {
        let sample = SystemSample(cpu: 0.345, gpu: nil, memoryUsed: 23_729_694_310, memoryTotal: 68_719_476_736,
                                  temperature: 71.4, thermal: .nominal)
        XCTAssertEqual(sample.lines, ["CPU 35%   GPU –", "Memory 22.1 / 64 GB", "Chip 71 °C   Thermal normal"])
    }

    func testModesCycleAndOnlyTheHUDGoesToTheGame() {
        XCTAssertEqual(PerformanceOverlayMode.off.next, .fps)
        XCTAssertEqual(PerformanceOverlayMode.fps.next, .system)
        XCTAssertEqual(PerformanceOverlayMode.system.next, .full)
        XCTAssertEqual(PerformanceOverlayMode.full.next, .off)
        XCTAssertEqual(PerformanceOverlayMode.off.gameEnvironment, [:])
        XCTAssertEqual(PerformanceOverlayMode.system.gameEnvironment, [:], "System only: no Metal HUD")
        XCTAssertEqual(PerformanceOverlayMode.fps.gameEnvironment, ["MTL_HUD_ENABLED": "1"])
        XCTAssertEqual(PerformanceOverlayMode.full.gameEnvironment, ["MTL_HUD_ENABLED": "1"])
        XCTAssertEqual(PerformanceOverlayMode.allCases.filter(\.showsSystem), [.system, .full])
    }

    /// Reads the real sensors of this Mac (read only). Values can be nil on a virtual machine.
    func testLiveSampleHasSaneValues() {
        let stats = SystemStats()
        _ = stats.sample()
        let sample = stats.sample()
        XCTAssertGreaterThan(sample.memoryTotal, 0)
        if let cpu = sample.cpu { XCTAssert((0...1).contains(cpu)) }
        if let temperature = sample.temperature { XCTAssert((0...150).contains(temperature)) }
    }
}
