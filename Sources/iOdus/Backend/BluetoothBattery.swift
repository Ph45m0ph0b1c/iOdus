import Foundation

/// The battery levels of Bluetooth game controllers, as macOS shows them in
/// Bluetooth Settings. Some controllers (for example the Xbox Wireless Controller
/// over Bluetooth LE) report their level only through the Bluetooth battery
/// service, and GameController gives the state "unknown" for them.
/// The source is `system_profiler SPBluetoothDataType -json`; it needs no permission.
enum BluetoothBattery {
    /// The levels (0...1) of the connected gamepads, by device name. A name can have
    /// more than one level when two controllers of one model are connected.
    static func parse(_ data: Data) -> [String: [Float]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: [Float]] = [:]
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let device = value as? [String: Any],
                          device["device_minorType"] as? String == "Gamepad",
                          let text = device["device_batteryLevelMain"] as? String,
                          let percent = Float(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
                    else { continue }
                    result[name, default: []].append(min(max(percent / 100, 0), 1))
                }
            }
        }
        return result
    }

    /// Reads the levels. Runs the tool outside the main thread.
    static func read() async -> [String: [Float]] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [:] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? parse(data) : [:]
        }.value
    }

    /// The Bluetooth level for a controller that GameController does not give a level for.
    /// Only when the match is clear: one connected controller and one level with that name.
    static func level(for name: String, controllersWithName count: Int, in levels: [String: [Float]]) -> Float? {
        guard count == 1, let list = levels[name], list.count == 1 else { return nil }
        return list[0]
    }
}
