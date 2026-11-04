import AppKit
import Foundation
import GameController

/// Connects game controllers to the app model. The D-pad and the left stick
/// move the focus, with a key repeat when the user holds a direction.
@MainActor
final class ControllerInput {
    static let shared = ControllerInput()

    private weak var model: AppModel?
    private var held: Direction?
    private var repeatTimer: Timer?
    private var started = false
    private var batteryTimer: Timer?
    private var holdTimer: Timer?
    /// The levels from Bluetooth Settings, for controllers that GameController
    /// reports as "unknown" (see BluetoothBattery).
    private var bluetoothLevels: [String: [Float]] = [:]

    /// The time that B must stay down to open the stream menu.
    static let holdSeconds: TimeInterval = 0.8

    /// True while a cloud stream has the input: iOdus ignores the buttons then,
    /// and the web player reads the controller itself.
    private var streamCaptures: Bool { model?.stream?.capturesInput == true }

    /// Runs `action` only when the stream does not capture the input, and
    /// only when the input belongs to the app (see GuideInputGate).
    private func app(_ action: (AppModel) -> Void) {
        guard let model, !streamCaptures, route(.other) == .app else { return }
        action(model)
    }

    /// Where a controller input goes: the app, the guide menu, or nowhere.
    /// iOdus gets background events, so the game can have the same input.
    private func route(_ input: GuideInput) -> GuideRoute {
        GuideInputGate.route(input, appActive: NSApp.isActive, playing: model?.playState.isPlaying == true,
                             menuOpen: GuideMenu.shared.isOpen, page: GuideMenu.shared.showsPage)
    }

    /// A: select in the guide menu or in the app.
    private func buttonA() {
        switch route(.accept) {
        case .menu: GuideMenu.shared.confirm()
        case .app: app { $0.confirm() }
        case .toggleMenu, .ignore: break
        }
    }

    /// The Xbox button: the guide menu over a running game, else Home.
    /// During a stream, the Xbox button opens the stream menu (AppModel.home).
    private func buttonHome() {
        switch route(.guide) {
        case .toggleMenu: GuideMenu.shared.toggle()
        case .app: model?.home()
        case .menu, .ignore: break
        }
    }

    /// One focus step: in the guide menu or in the app.
    private func step(_ d: Direction) {
        switch route(.navigation) {
        case .menu: GuideMenu.shared.move(d)
        case .app: model?.move(d)
        case .toggleMenu, .ignore: break
        }
    }

    /// B: back, or a long press during a stream opens the iOdus menu.
    private func buttonB(_ pressed: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard pressed else { return }
        switch route(.back) {
        case .menu:
            GuideMenu.shared.back()
            return
        case .toggleMenu, .ignore:
            return
        case .app:
            break
        }
        guard streamCaptures else {
            model?.back()
            return
        }
        holdTimer = Timer.scheduledTimer(withTimeInterval: Self.holdSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model,
                      StreamInputGate.route(.holdB, session: model.stream) == .openMenu else { return }
                model.openStreamMenu()
            }
        }
    }

    func start(_ model: AppModel) {
        self.model = model
        guard !started else { return }
        started = true
        // Background events: iOdus must see the Xbox button while a game is in
        // front. GuideInputGate keeps the other buttons away from the app then.
        GCController.shouldMonitorBackgroundEvents = true
        GuideMenu.shared.attach(model)
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated {
                ControllerInput.shared.attach(controller)
                ControllerInput.shared.report(connected: Self.name(of: controller))
                ControllerInput.shared.refreshBluetoothLevels()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { note in
            let name = (note.object as? GCController).map(Self.name(of:))
            MainActor.assumeIsolated { ControllerInput.shared.report(disconnected: name ?? "A controller") }
        }
        GCController.controllers().forEach(attach)
        report()
        refreshBluetoothLevels()
        // GCDeviceBattery has no change notification, so read it again every 30 seconds.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                ControllerInput.shared.report()
                ControllerInput.shared.refreshBluetoothLevels()
            }
        }
    }

    /// The battery level, or nil when the controller does not report it. Many
    /// controllers give level 0 with the state "unknown" until (or unless) they
    /// report a real level; that is not an empty battery.
    nonisolated static func batteryLevel(_ battery: GCDeviceBattery?) -> Float? {
        guard let battery else { return nil }
        return batteryLevel(level: battery.batteryLevel, state: battery.batteryState)
    }

    nonisolated static func batteryLevel(level: Float, state: GCDeviceBattery.State) -> Float? {
        if state == .unknown && level <= 0 { return nil }
        return min(max(level, 0), 1)
    }

    nonisolated static func name(of controller: GCController) -> String {
        controller.vendorName ?? controller.productCategory
    }

    /// Reads the Bluetooth levels again, but only when a controller has no level
    /// from GameController. Then sends the list again.
    private func refreshBluetoothLevels() {
        let controllers = GCController.controllers()
        guard controllers.contains(where: { Self.batteryLevel($0.battery) == nil }) else { return }
        Task {
            let levels = await BluetoothBattery.read()
            guard levels != bluetoothLevels else { return }
            bluetoothLevels = levels
            report()
        }
    }

    /// Sends the controller list and the battery levels to the model.
    private func report(connected: String? = nil, disconnected: String? = nil) {
        let controllers = GCController.controllers()
        let names = controllers.map(Self.name(of:))
        let list = controllers.map { controller in
            let name = Self.name(of: controller)
            return ControllerStatus(
                id: String(UInt(bitPattern: ObjectIdentifier(controller).hashValue)),
                name: name,
                battery: Self.batteryLevel(controller.battery)
                    ?? BluetoothBattery.level(for: name, controllersWithName: names.filter { $0 == name }.count,
                                              in: bluetoothLevels),
                charging: [.charging, .full].contains(controller.battery?.batteryState ?? .unknown))
        }
        model?.updateControllers(list, connected: connected, disconnected: disconnected)
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x: x, y: y, source: 0) }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.direction(x: x, y: y, source: 1) }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.buttonA() } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.buttonB(pressed) }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.app { $0.xPressed() } } }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.app { $0.focusSearch() } } }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.app { $0.shoulder(-1) } } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.app { $0.shoulder(1) } } }
        }
        // Ask macOS not to use the Xbox button for its own action (Launchpad or Game Center).
        pad.buttonHome?.preferredSystemGestureState = .disabled
        pad.buttonHome?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { MainActor.assumeIsolated { self?.buttonHome() } }
        }
        pad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.pairChanged(.view, pressed: pressed) }
        }
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.pairChanged(.menu, pressed: pressed) }
        }
    }

    private var activeSource: Int?
    private var buttonPair = GuideButtonPair()

    /// View + Menu together: opens or closes the guide menu over a running game.
    /// Inside iOdus the pair does nothing; the Xbox button works there.
    private func pairChanged(_ button: GuideButtonPair.Button, pressed: Bool) {
        guard buttonPair.change(button, pressed: pressed) else { return }
        if route(.guide) == .toggleMenu { GuideMenu.shared.toggle() }
    }

    private func direction(x: Float, y: Float, source: Int) {
        if streamCaptures || route(.navigation) == .ignore {
            held = nil
            activeSource = nil
            repeatTimer?.invalidate()
            return
        }
        let threshold: Float = 0.5
        let d: Direction?
        if abs(x) < threshold && abs(y) < threshold {
            d = nil
        } else if abs(x) > abs(y) {
            d = x > 0 ? .right : .left
        } else {
            d = y > 0 ? .up : .down
        }
        // A release on one input must not stop a hold on the other input.
        if d == nil, let active = activeSource, active != source { return }
        guard d != held else { return }
        held = d
        activeSource = d == nil ? nil : source
        repeatTimer?.invalidate()
        guard let d else { return }
        step(d)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.40, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startRepeat(d) }
        }
    }

    private func startRepeat(_ d: Direction) {
        guard held == d else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.held == d else { return }
                self.step(d)
            }
        }
    }
}
