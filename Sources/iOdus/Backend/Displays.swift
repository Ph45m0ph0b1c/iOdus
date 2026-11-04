import AppKit
import CoreGraphics

/// A Mac display, as Wine shows it to Windows games.
struct WineDisplay: Equatable {
    /// Vendor, model, and serial number. The CoreGraphics display ID can
    /// change after a restart; these numbers do not.
    let id: String
    let name: String
    /// 1-based: Windows `\\.\DISPLAYn` and the Unity `-monitor n` option.
    let number: Int
    let points: CGSize
    let scale: CGFloat

    /// The size in Windows coordinates: pixels in Wine's Retina mode, else points.
    func size(retina: Bool) -> CGSize {
        retina ? CGSize(width: points.width * scale, height: points.height * scale) : points
    }
}

enum Displays {
    /// The displays in Wine's order (winemac.drv `macdrv_get_adapters`):
    /// the online list without mirrors, then the main display swaps with the
    /// first entry.
    static func wineOrder() -> [WineDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        let online = Array(ids.prefix(Int(count))).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        let screens = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return (number.uint32Value, screen)
        }, uniquingKeysWith: { first, _ in first })
        return order(online, main: CGMainDisplayID()).enumerated().compactMap { index, display in
            guard let screen = screens[display] else { return nil }
            return WineDisplay(id: stableID(display), name: screen.localizedName, number: index + 1,
                               points: screen.frame.size, scale: screen.backingScaleFactor)
        }
    }

    /// Wine's swap: the main display goes first, and the first entry takes its place.
    static func order(_ displays: [CGDirectDisplayID], main: CGDirectDisplayID) -> [CGDirectDisplayID] {
        var list = displays
        if let index = list.firstIndex(of: main), index > 0 { list.swapAt(0, index) }
        return list
    }

    static func stableID(_ display: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))"
    }

    /// The connected display for a saved choice, or nil.
    static func find(_ choice: DisplayChoice?) -> WineDisplay? {
        guard let choice else { return nil }
        return wineOrder().first { $0.id == choice.id }
    }

    /// The per-game cycle: the game's own choice (nil), then each connected display.
    static func next(after choice: DisplayChoice?, in displays: [WineDisplay]) -> DisplayChoice? {
        let index = choice.flatMap { c in displays.firstIndex { $0.id == c.id } }
        let nextIndex = index.map { $0 + 1 } ?? (choice == nil ? 0 : displays.count)
        guard nextIndex < displays.count else { return nil }
        return DisplayChoice(id: displays[nextIndex].id, name: displays[nextIndex].name)
    }

    /// The Unity options for a display: full screen, its monitor number, and its
    /// size. A window (not full screen) of the display size is taller than the
    /// space under the menu bar, so macOS moves it to a display where it fits.
    /// A full-screen window always fits. With `-window-mode borderless`, the
    /// full screen is a borderless window.
    static func unityArguments(_ display: WineDisplay, retina: Bool) -> [String] {
        let size = display.size(retina: retina)
        return ["-screen-fullscreen", "1", "-monitor", String(display.number),
                "-screen-width", String(Int(size.width)), "-screen-height", String(Int(size.height))]
    }
}
