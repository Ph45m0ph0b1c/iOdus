import CoreGraphics
import XCTest
@testable import iOdus

final class DisplaysTests: XCTestCase {
    private let dell = WineDisplay(id: "1-1-1", name: "DELL U4320Q", number: 1,
                                   points: CGSize(width: 3840, height: 2160), scale: 1)
    private let acer = WineDisplay(id: "2-2-2", name: "Acer X34", number: 2,
                                   points: CGSize(width: 1440, height: 3440), scale: 1)

    func testWineOrderSwapsTheMainDisplayToTheFront() {
        XCTAssertEqual(Displays.order([5, 2], main: 2), [2, 5])
        XCTAssertEqual(Displays.order([2, 5], main: 2), [2, 5])
        // A swap, not a move: the old first display takes the place of the main display.
        XCTAssertEqual(Displays.order([7, 8, 9], main: 9), [9, 8, 7])
        XCTAssertEqual(Displays.order([7, 8], main: 3), [7, 8])
    }

    func testTheCycleGoesFromDefaultThroughEachDisplayBackToDefault() {
        let list = [dell, acer]
        let first = Displays.next(after: nil, in: list)
        XCTAssertEqual(first, DisplayChoice(id: dell.id, name: dell.name))
        let second = Displays.next(after: first, in: list)
        XCTAssertEqual(second, DisplayChoice(id: acer.id, name: acer.name))
        XCTAssertNil(Displays.next(after: second, in: list))
    }

    func testADisconnectedChoiceGoesBackToDefault() {
        let gone = DisplayChoice(id: "9-9-9", name: "Old monitor")
        XCTAssertNil(Displays.next(after: gone, in: [dell, acer]))
        XCTAssertNil(Displays.next(after: nil, in: []))
    }

    func testUnityArgumentsUseTheMonitorNumberAndItsSize() {
        XCTAssertEqual(Displays.unityArguments(acer, retina: false),
                       ["-screen-fullscreen", "1", "-monitor", "2", "-screen-width", "1440", "-screen-height", "3440"])
        let retina = WineDisplay(id: "3-3-3", name: "Built-in", number: 1,
                                 points: CGSize(width: 1512, height: 982), scale: 2)
        XCTAssertEqual(Displays.unityArguments(retina, retina: true),
                       ["-screen-fullscreen", "1", "-monitor", "1", "-screen-width", "3024", "-screen-height", "1964"])
        XCTAssertEqual(Displays.unityArguments(retina, retina: false),
                       ["-screen-fullscreen", "1", "-monitor", "1", "-screen-width", "1512", "-screen-height", "982"])
    }

    func testTheDisplayChoiceIsSavedPerGame() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DisplaysTests-\(UUID().uuidString)"))
        let store = GameOptionsStore(defaults: defaults)
        var options = GameOptions()
        options.display = DisplayChoice(id: dell.id, name: dell.name)
        store.set("9abc", options)
        XCTAssertEqual(store.options("9ABC").display, options.display)
        options.display = nil
        store.set("9abc", options)
        XCTAssertNil(defaults.data(forKey: GameOptionsStore.key).flatMap { String(decoding: $0, as: UTF8.self) }
            .flatMap { $0.contains("9ABC") ? $0 : nil })
    }

    func testOldSavedOptionsWithoutADisplayStillLoad() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DisplaysTests-\(UUID().uuidString)"))
        defaults.set(Data(#"{"9ABC":{"retina":true}}"#.utf8), forKey: GameOptionsStore.key)
        let options = GameOptionsStore(defaults: defaults).options("9abc")
        XCTAssertTrue(options.retina)
        XCTAssertNil(options.display)
    }
}
