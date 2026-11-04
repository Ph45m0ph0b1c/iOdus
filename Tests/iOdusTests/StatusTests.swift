import XCTest
@testable import iOdus

final class StatusTests: XCTestCase {
    func testBatterySymbolsAndTexts() {
        func c(_ level: Float?, _ charging: Bool = false) -> ControllerStatus {
            ControllerStatus(id: "1", name: "Pad", battery: level, charging: charging)
        }
        XCTAssertEqual(c(1).batterySymbol, "battery.100")
        XCTAssertEqual(c(0.5).batterySymbol, "battery.50")
        XCTAssertEqual(c(0.05).batterySymbol, "battery.0")
        XCTAssertEqual(c(0.4, true).batterySymbol, "battery.100.bolt")
        XCTAssertNil(c(nil).batterySymbol)
        XCTAssertEqual(c(0.72).batteryText, "Battery 72%")
        XCTAssertEqual(c(nil).batteryText, "Battery level unknown")
        XCTAssertTrue(c(0.1).lowBattery)
        XCTAssertFalse(c(0.1, true).lowBattery, "A charging controller is not low")
    }

    func testNetworkTexts() {
        var status = NetworkStatus(kind: .offline, xboxLive: .unreachable)
        XCTAssertFalse(status.online)
        XCTAssertEqual(status.symbol, "wifi.slash")
        XCTAssertEqual(status.serviceText, "Not reachable (offline)")
        status.kind = .wired
        XCTAssertEqual(status.kindText, "Ethernet")
        XCTAssertEqual(status.serviceText, "Not reachable")
    }
}

final class NotificationStoreTests: XCTestCase {
    func testAddsNewestFirstLimitsAndPersists() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var store = NotificationStore(file: file)
        for i in 0..<(NotificationStore.limit + 5) {
            store.add(AppNotification(date: Date(), kind: .info, title: "n\(i)", detail: ""))
        }
        XCTAssertEqual(store.items.count, NotificationStore.limit)
        XCTAssertEqual(store.items.first?.title, "n\(NotificationStore.limit + 4)", "Newest first")
        XCTAssertEqual(store.unread, NotificationStore.limit)
        store.markAllRead()
        XCTAssertEqual(NotificationStore(file: file).unread, 0, "Read state is saved")
        store.add(AppNotification(date: Date(), kind: .achievements, title: "a", detail: "",
                                  action: .openAchievements("1907796436")))
        let again = NotificationStore(file: file)
        XCTAssertEqual(again.unread, 1)
        XCTAssertEqual(again.items.first?.action, .openAchievements("1907796436"))
        store.clear()
        XCTAssertTrue(NotificationStore(file: file).items.isEmpty)
    }
}

final class ControllerBatteryTests: XCTestCase {
    func testUnknownZeroIsNoInformation() {
        XCTAssertNil(ControllerInput.batteryLevel(level: 0, state: .unknown), "Not reported yet: no battery shown")
        XCTAssertEqual(ControllerInput.batteryLevel(level: 0.05, state: .discharging), 0.05, "A real low level stays")
        XCTAssertEqual(ControllerInput.batteryLevel(level: 0.6, state: .unknown), 0.6)
        XCTAssertEqual(ControllerInput.batteryLevel(level: 1.2, state: .full), 1)
    }

    func testBluetoothBatteryReadsGamepadsOnly() {
        let json = #"""
        {"SPBluetoothDataType":[{"device_connected":[
          {"Example Headphones":{"device_minorType":"Headphones","device_batteryLevelMain":"80%"}},
          {"Xbox Wireless Controller":{"device_minorType":"Gamepad","device_batteryLevelMain":"100%"}},
          {"Other Pad":{"device_minorType":"Gamepad"}}
        ]}]}
        """#
        let levels = BluetoothBattery.parse(Data(json.utf8))
        XCTAssertEqual(levels, ["Xbox Wireless Controller": [1]])
        XCTAssertEqual(BluetoothBattery.level(for: "Xbox Wireless Controller", controllersWithName: 1, in: levels), 1)
        XCTAssertNil(BluetoothBattery.level(for: "Xbox Wireless Controller", controllersWithName: 2, in: levels),
                     "Two controllers with one name: no clear match")
        XCTAssertNil(BluetoothBattery.level(for: "Other Pad", controllersWithName: 1, in: levels))
        XCTAssertEqual(BluetoothBattery.parse(Data("no json".utf8)), [:])
    }
}
