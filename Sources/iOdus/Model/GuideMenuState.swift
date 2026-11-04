import Foundation

/// One entry of the guide menu. The guide menu opens over a running game when
/// the player presses the Xbox button.
enum GuideMenuItem: CaseIterable, Equatable {
    case resume
    case achievements
    case friends
    case messages
    case settings
    case backToApp
    case closeGame

    var title: String {
        switch self {
        case .resume: "Resume"
        case .achievements: "Achievements"
        case .friends: "Friends"
        case .messages: "Messages"
        case .settings: "Settings"
        case .backToApp: "Back to iOdus"
        case .closeGame: "Close game"
        }
    }

    var symbol: String {
        switch self {
        case .resume: "play.fill"
        case .achievements: "trophy.fill"
        case .friends: "person.2.fill"
        case .messages: "message.fill"
        case .settings: "gearshape.fill"
        case .backToApp: "house.fill"
        case .closeGame: "xmark.circle.fill"
        }
    }

    /// True for the entries that show an iOdus page inside the overlay, over the
    /// game. The game keeps the focus, so the player stays on the controller.
    var showsInOverlay: Bool {
        switch self {
        case .achievements, .friends, .messages, .settings: true
        case .resume, .backToApp, .closeGame: false
        }
    }

    /// True for the entries that open a screen in the iOdus window.
    var opensApp: Bool {
        switch self {
        case .achievements, .friends, .messages, .settings, .backToApp: true
        case .resume, .closeGame: false
        }
    }
}

/// What the guide menu tells its owner to do after A (or a click).
enum GuideMenuAction: Equatable {
    case resume                 // Close the menu; the game continues
    case page(GuideMenuItem)    // Show the iOdus page of the entry inside the overlay
    case show(GuideMenuItem)    // Close the menu, bring iOdus to the front, open the screen
    case closeGame              // Close the menu and stop the game in the normal way
}

/// The state of the open guide menu: the focus, and the confirm step for "Close game".
struct GuideMenuState: Equatable {
    let gameID: String
    let title: String
    let items: [GuideMenuItem]
    var index = 0
    /// True while the menu asks "Close <game>?".
    var confirmClose = false
    /// The focus in the confirm step: 0 = Close, 1 = Cancel.
    var confirmIndex = 0
    /// The entry whose iOdus page shows in the overlay, or nil for the entry list.
    var page: GuideMenuItem?
    /// True when the runtime has no input gate: the game also gets the menu input.
    var gameGetsInput = false

    init(gameID: String, title: String, items: [GuideMenuItem] = GuideMenuItem.allCases) {
        self.gameID = gameID
        self.title = title
        self.items = items
    }

    /// The menu for the play state, or nil. The menu opens only while a game plays,
    /// not while it starts.
    static func open(play: PlayState, title: String?) -> GuideMenuState? {
        guard case .playing(let id) = play else { return nil }
        return GuideMenuState(gameID: id, title: title ?? "The game")
    }

    var confirmText: String { "Close \(title)?" }

    mutating func move(_ d: Direction) {
        if confirmClose {
            switch d {
            case .up, .left: confirmIndex = 0
            case .down, .right: confirmIndex = 1
            }
            return
        }
        switch d {
        case .up, .left: index = max(0, index - 1)
        case .down, .right: index = min(items.count - 1, index + 1)
        }
    }

    /// A on the focus. Returns nil when the menu stays open (the confirm step starts).
    mutating func choose() -> GuideMenuAction? {
        if confirmClose {
            if confirmIndex == 0 { return .closeGame }
            confirmClose = false
            return nil
        }
        guard index < items.count else { return nil }
        switch items[index] {
        case .resume: return .resume
        case let item where item.showsInOverlay: return .page(item)
        case .closeGame:
            confirmClose = true
            confirmIndex = 0
            return nil
        case let item: return .show(item)
        }
    }

    /// B: leaves the confirm step, else closes the menu. Returns true when the menu closes.
    mutating func back() -> Bool {
        if confirmClose {
            confirmClose = false
            return false
        }
        return true
    }

    /// A click on an entry.
    mutating func tap(_ i: Int) -> GuideMenuAction? {
        guard !confirmClose, items.indices.contains(i) else { return nil }
        index = i
        return choose()
    }

    /// A click on a button of the confirm step: 0 = Close, 1 = Cancel.
    mutating func tapConfirm(_ i: Int) -> GuideMenuAction? {
        guard confirmClose, i == 0 || i == 1 else { return nil }
        confirmIndex = i
        return choose()
    }
}

/// The kinds of controller input for the guide gate.
/// View + Menu pressed together: the second way to open the guide menu.
/// macOS keeps the Xbox button for itself while another app (the game) is in
/// front, so iOdus does not get that button then. It gets View and Menu.
struct GuideButtonPair {
    enum Button { case view, menu }
    private(set) var viewDown = false
    private(set) var menuDown = false

    /// Records a change. True when this press completes the pair (both down).
    mutating func change(_ button: Button, pressed: Bool) -> Bool {
        let wasBoth = viewDown && menuDown
        switch button {
        case .view: viewDown = pressed
        case .menu: menuDown = pressed
        }
        return pressed && viewDown && menuDown && !wasBoth
    }
}

enum GuideInput: Equatable {
    case guide          // The Xbox button
    case navigation     // The D-pad and the left stick
    case accept         // A
    case back           // B
    case other          // X, Y, and the shoulder buttons
}

/// Where a controller input goes.
enum GuideRoute: Equatable {
    case app            // The normal iOdus navigation
    case menu           // The guide menu
    case toggleMenu     // Open or close the guide menu
    case ignore         // Nobody: the game has the controller
}

/// Decides where a controller input goes. iOdus also gets controller input in
/// the background, so that it sees the Xbox button while a game is in front.
/// The game reads the same controller, so in the background only the Xbox
/// button and the open guide menu may act.
enum GuideInputGate {
    static func route(_ input: GuideInput, appActive: Bool, playing: Bool, menuOpen: Bool,
                      page: Bool = false) -> GuideRoute {
        // An iOdus page in the overlay: the app navigation drives it. B goes to the
        // menu, which goes back in the page or returns to the entry list.
        if menuOpen && page {
            switch input {
            case .guide: return .toggleMenu
            case .back: return .menu
            case .navigation, .accept, .other: return .app
            }
        }
        if menuOpen {
            switch input {
            case .guide: return .toggleMenu
            case .navigation, .accept, .back: return .menu
            case .other: return .ignore
            }
        }
        if appActive { return .app }
        if playing && input == .guide { return .toggleMenu }
        return .ignore
    }
}

extension PlayState {
    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }
}

extension AppModel {
    /// True when B on an overlay page must return to the guide entry list: no
    /// prompt, panel, card, or text box is open, and the page is at its first level.
    func guidePageAtRoot(depth: Int) -> Bool {
        installPrompt == nil && statusPanel == nil && friendCard == nil && !isTyping && stack.count <= depth
    }

    /// Opens the screen of a guide menu entry in the iOdus window. The caller
    /// brings the window to the front. The game continues to run.
    func showFromGuide(_ item: GuideMenuItem, gameID: String) {
        guard item.opensApp else { return }
        installPrompt = nil
        statusPanel = nil
        friendCard = nil
        switch item {
        case .achievements:
            guard let game = game(gameID) else { return }
            if let titleId = game.titleId, screen == .achievements(titleId) { return }
            openAchievements(game)
        case .friends:
            friendIndex = 0
            if screen != .friends { stack.append(.friends) }
            Task { await loadFriends(force: false) }
        case .messages:
            messageIndex = 0
            if screen != .messages { stack.append(.messages) }
            Task { await loadInbox(notify: false) }
        case .settings:
            settingsIndex = 0
            if screen != .settings { stack.append(.settings) }
        case .backToApp, .resume, .closeGame:
            break
        }
    }
}
