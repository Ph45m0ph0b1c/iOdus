import AppKit
import Combine
import SwiftUI

/// The guide menu over a running game: a blade at the left side of the screen
/// with the game title, the entries, and the button hints.
struct GuideMenuView: View {
    let state: GuideMenuState
    let gamertag: String
    let size: CGSize
    var onTap: (Int) -> Void = { _ in }
    var onTapConfirm: (Int) -> Void = { _ in }
    var onBackdrop: () -> Void = {}
    /// The iOdus page of an entry (for example Friends), or nil for the entry list.
    var page: AnyView? = nil

    var body: some View {
        if let page {
            pageBody(page)
        } else {
            listBody
        }
    }

    /// An iOdus page in a large frame over the game, with the hints of the overlay.
    private func pageBody(_ page: AnyView) -> some View {
        let s = Theme.scale(for: size)
        let inset = 50 * s
        let frame = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset - 50 * s)
        return ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 14 * s) {
                page
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * s))
                    .overlay(RoundedRectangle(cornerRadius: 12 * s).stroke(Theme.accent, lineWidth: 2 * s))
                HStack(spacing: 20 * s) {
                    Text(state.page?.title ?? "")
                        .font(.system(size: 18 * s, weight: .semibold))
                    Spacer()
                    hint("B", Theme.buttonB, "Back", s)
                    Text("View + Menu: back to the game")
                        .font(.system(size: 16 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(width: frame.width)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var listBody: some View {
        let s = Theme.scale(for: size)
        return ZStack(alignment: .leading) {
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .onTapGesture { onBackdrop() }
            VStack(alignment: .leading, spacing: 0) {
                header(s)
                    .padding(.bottom, 26 * s)
                if state.confirmClose {
                    confirm(s)
                } else {
                    entries(s)
                }
                Spacer(minLength: 0)
                hints(s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 36 * s)
            .padding(.vertical, 48 * s)
            .frame(width: 560 * s, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.11))
            .overlay(alignment: .trailing) {
                Rectangle().fill(Theme.accent).frame(width: 3 * s)
            }
            .shadow(color: .black.opacity(0.7), radius: 40 * s)
        }
        .frame(width: size.width, height: size.height)
    }

    private func header(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            HStack(spacing: 10 * s) {
                Circle().fill(Theme.accent).frame(width: 34 * s, height: 34 * s)
                    .overlay(Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 16 * s, weight: .semibold)))
                Text(gamertag.isEmpty ? "iOdus" : gamertag)
                    .font(.system(size: 18 * s, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(state.title)
                .font(.system(size: 32 * s, weight: .semibold))
                .lineLimit(2)
            Text("Playing now")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.accentBright)
            if state.gameGetsInput {
                Label("On this runtime, the game also gets your button presses.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15 * s))
                    .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func entries(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            ForEach(Array(state.items.enumerated()), id: \.offset) { i, item in
                row(item.title, symbol: item.symbol, focused: state.index == i, s)
                    .onTapGesture { onTap(i) }
                if item == .resume || item == .backToApp {
                    Rectangle().fill(Color(white: 0.22)).frame(height: 1)
                        .padding(.vertical, 6 * s)
                }
            }
        }
    }

    private func confirm(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            Text(state.confirmText)
                .font(.system(size: 26 * s, weight: .semibold))
                .lineLimit(2)
            Text("iOdus closes the game in the normal way. Progress that the game did not save can be lost.")
                .font(.system(size: 17 * s))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14 * s)
            row("Close", symbol: "xmark.circle.fill", focused: state.confirmIndex == 0, s)
                .onTapGesture { onTapConfirm(0) }
            row("Cancel", symbol: "arrow.uturn.backward", focused: state.confirmIndex == 1, s)
                .onTapGesture { onTapConfirm(1) }
        }
    }

    private func row(_ title: String, symbol: String, focused: Bool, _ s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            Image(systemName: symbol)
                .frame(width: 26 * s)
            Text(title)
            Spacer()
        }
        .font(.system(size: 21 * s, weight: .semibold))
        .foregroundStyle(focused ? Color.black : .white)
        .padding(.horizontal, 20 * s)
        .frame(height: 56 * s)
        .background(focused ? Color.white : Theme.tile)
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
    }

    private func hints(_ s: CGFloat) -> some View {
        HStack(spacing: 20 * s) {
            hint("A", Theme.buttonA, "Select", s)
            hint("B", Theme.buttonB, state.confirmClose ? "Cancel" : "Close", s)
        }
    }

    private func hint(_ label: String, _ color: Color, _ text: String, _ s: CGFloat) -> some View {
        HStack(spacing: 8 * s) {
            Circle().fill(Color(white: 0.2)).frame(width: 26 * s, height: 26 * s)
                .overlay(Text(label).font(.system(size: 14 * s, weight: .bold)).foregroundStyle(color))
            Text(text).font(.system(size: 16 * s))
        }
    }
}

/// A hosting view that takes the first click, so that a click on an entry acts
/// while the game (another app) is in front.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The guide menu over a running game. The Xbox button opens it (see
/// ControllerInput and GuideInputGate). The panel floats above a full-screen
/// game and does not take the key focus from the game. The controller and
/// mouse clicks drive it.
@MainActor
final class GuideMenu {
    static let shared = GuideMenu()

    private(set) var state: GuideMenuState?
    private weak var model: AppModel?
    private var panel: NSPanel?
    private var watchers: Set<AnyCancellable> = []

    var isOpen: Bool { state != nil }

    /// The gate file of the running game while the menu is open (see GameRuntime.inputGate).
    private var gateFile: URL?

    /// Connects the menu to the model. The menu closes when the game stops,
    /// and when iOdus comes to the front.
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        // A gate file from an earlier iOdus run (for example after a crash) must not
        // keep the next game without input.
        for runtime in model.runtimes { try? FileManager.default.removeItem(at: runtime.inputGateFile) }
        model.$playState
            .receive(on: RunLoop.main)
            .sink { [weak self] play in
                MainActor.assumeIsolated {
                    guard let self, let state = self.state else { return }
                    if play != .playing(id: state.gameID) { self.close() }
                }
            }
            .store(in: &watchers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
            .store(in: &watchers)
    }

    /// The Xbox button: opens the menu while a game plays, or closes it.
    func toggle() {
        if isOpen {
            close()
            return
        }
        guard let model, var state = GuideMenuState.open(play: model.playState,
                                                         title: model.playState.gameID.flatMap { model.game($0)?.title })
        else { return }
        // Stop the game input while the menu is open, when the runtime can.
        let runtime = model.launcher.runtime
        if runtime.inputGate {
            FileManager.default.createFile(atPath: runtime.inputGateFile.path, contents: nil)
            gateFile = runtime.inputGateFile
        } else {
            state.gameGetsInput = true
        }
        self.state = state
        show()
    }

    func move(_ d: Direction) {
        state?.move(d)
        render()
    }

    func confirm() {
        guard var state else { return }
        let action = state.choose()
        self.state = state
        perform(action)
    }

    /// The stack of the iOdus window before the first overlay page. Restored when
    /// the overlay closes, so that the window shows what it showed before.
    private var savedStack: [Screen]?
    /// The stack depth of the open page at its first level.
    private var pageDepth = 0

    /// True while an iOdus page shows in the overlay.
    var showsPage: Bool { state?.page != nil }

    /// Shows the iOdus page of an entry in the overlay. The game keeps the focus.
    private func openPage(_ item: GuideMenuItem) {
        guard let model, let gameID = state?.gameID else { return }
        if savedStack == nil { savedStack = model.stack }
        model.stack = [.home]
        model.showFromGuide(item, gameID: gameID)
        pageDepth = model.stack.count
        state?.page = item
        render()
    }

    /// Back to the entry list, and the iOdus window shows its old screen again.
    private func leavePage() {
        state?.page = nil
        restoreStack()
        render()
    }

    private func restoreStack() {
        guard let model, let saved = savedStack else { return }
        model.installPrompt = nil
        model.statusPanel = nil
        model.friendCard = nil
        model.stack = saved
        savedStack = nil
    }

    func back() {
        guard var state else { return }
        if state.page != nil, let model {
            if model.guidePageAtRoot(depth: pageDepth) { leavePage() } else { model.back() }
            return
        }
        if state.back() {
            close()
        } else {
            self.state = state
            render()
        }
    }

    func close() {
        restoreStack()
        if let gateFile { try? FileManager.default.removeItem(at: gateFile) }
        gateFile = nil
        state = nil
        panel?.orderOut(nil)
    }

    private func tap(_ i: Int) {
        guard var state else { return }
        let action = state.tap(i)
        self.state = state
        perform(action)
    }

    private func tapConfirm(_ i: Int) {
        guard var state else { return }
        let action = state.tapConfirm(i)
        self.state = state
        perform(action)
    }

    /// nil: the menu stays open with a new state (for example the confirm step).
    private func perform(_ action: GuideMenuAction?) {
        guard let action else {
            render()
            return
        }
        if case .page(let item) = action {
            openPage(item)
            return
        }
        let gameID = state?.gameID
        close()
        guard let model, let gameID else { return }
        switch action {
        case .resume, .page:
            break   // .page does not get here: openPage handles it above.
        case .show(let item):
            Self.bringAppToFront()
            model.showFromGuide(item, gameID: gameID)
        case .closeGame:
            // The normal stop path: the game saves, and the save upload runs after it ends.
            model.stopRunningGame()
        }
    }

    /// Brings the iOdus window to the front. The game continues in the background.
    static func bringAppToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Panel

    private func show() {
        let panel = self.panel ?? makePanel()
        render()
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func render() {
        guard let state, let panel else { return }
        let size = (NSScreen.main ?? NSScreen.screens.first)?.frame.size ?? CGSize(width: 1920, height: 1080)
        // The page view observes the model, so it changes with the controller input.
        let page = state.page != nil ? model.map { AnyView(RootContent().environmentObject($0)) } : nil
        let view = GuideMenuView(state: state, gamertag: model?.gamertag ?? "", size: size,
                                 onTap: { [weak self] i in self?.tap(i) },
                                 onTapConfirm: { [weak self] i in self?.tapConfirm(i) },
                                 onBackdrop: { [weak self] in self?.close() },
                                 page: page)
            .environment(\.colorScheme, .dark)
        if let host = panel.contentView as? FirstClickHostingView<AnyView> {
            host.rootView = AnyView(view)
        } else {
            panel.contentView = FirstClickHostingView(rootView: AnyView(view))
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    /// The full main screen, over the game.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(screen.frame, display: true)
    }
}
