import XCTest
@testable import iOdus

final class GuideMenuStateTests: XCTestCase {
    func testOpensOnlyWhilePlaying() {
        XCTAssertNil(GuideMenuState.open(play: .idle, title: "DREDGE"))
        XCTAssertNil(GuideMenuState.open(play: .preparing(id: "G", step: "Starting…"), title: "DREDGE"))
        let state = GuideMenuState.open(play: .playing(id: "G"), title: "DREDGE")
        XCTAssertEqual(state?.gameID, "G")
        XCTAssertEqual(state?.title, "DREDGE")
        XCTAssertEqual(state?.index, 0)
        XCTAssertEqual(state?.confirmClose, false)
        XCTAssertEqual(GuideMenuState.open(play: .playing(id: "G"), title: nil)?.title, "The game")
    }

    func testEntries() {
        let state = GuideMenuState(gameID: "G", title: "T")
        XCTAssertEqual(state.items, [.resume, .achievements, .friends, .messages, .settings, .backToApp, .closeGame])
        XCTAssertEqual(state.items.first, .resume, "A at once resumes the game")
        XCTAssertEqual(state.items.map(\.title),
                       ["Resume", "Achievements", "Friends", "Messages", "Settings", "Back to iOdus", "Close game"])
        XCTAssertEqual(GuideMenuItem.allCases.filter(\.opensApp), [.achievements, .friends, .messages, .settings, .backToApp])
    }

    func testNavigationStopsAtTheEnds() {
        var state = GuideMenuState(gameID: "G", title: "T")
        state.move(.up)
        XCTAssertEqual(state.index, 0)
        state.move(.down)
        state.move(.right)
        XCTAssertEqual(state.index, 2)
        state.move(.left)
        XCTAssertEqual(state.index, 1)
        for _ in 0..<20 { state.move(.down) }
        XCTAssertEqual(state.index, state.items.count - 1)
    }

    func testChooseEntries() {
        var state = GuideMenuState(gameID: "G", title: "T")
        XCTAssertEqual(state.choose(), .resume)
        for (i, item) in state.items.enumerated() where item.opensApp {
            state.index = i
            // The pages show inside the overlay; "Back to iOdus" brings the window to the front.
            XCTAssertEqual(state.choose(), item.showsInOverlay ? .page(item) : .show(item))
        }
    }

    func testCloseGameNeedsTheConfirmStep() {
        var state = GuideMenuState(gameID: "G", title: "DREDGE")
        state.index = state.items.firstIndex(of: .closeGame)!
        XCTAssertNil(state.choose(), "The first A only asks")
        XCTAssertTrue(state.confirmClose)
        XCTAssertEqual(state.confirmText, "Close DREDGE?")
        XCTAssertEqual(state.confirmIndex, 0)

        // Cancel: back to the list, the game continues.
        state.move(.down)
        XCTAssertEqual(state.confirmIndex, 1)
        XCTAssertNil(state.choose())
        XCTAssertFalse(state.confirmClose)
        XCTAssertEqual(state.items[state.index], .closeGame)

        // Close.
        XCTAssertNil(state.choose())
        state.move(.right)
        state.move(.up)
        XCTAssertEqual(state.confirmIndex, 0)
        XCTAssertEqual(state.choose(), .closeGame)
    }

    func testBack() {
        var state = GuideMenuState(gameID: "G", title: "T")
        state.index = state.items.firstIndex(of: .closeGame)!
        _ = state.choose()
        XCTAssertFalse(state.back(), "B in the confirm step goes back to the list")
        XCTAssertFalse(state.confirmClose)
        XCTAssertTrue(state.back(), "B on the list closes the menu")
    }

    func testTaps() {
        var state = GuideMenuState(gameID: "G", title: "T")
        XCTAssertEqual(state.tap(2), .page(.friends))
        XCTAssertNil(state.tap(99))
        XCTAssertNil(state.tapConfirm(0), "No confirm step yet")
        XCTAssertNil(state.tap(state.items.count - 1))
        XCTAssertTrue(state.confirmClose)
        XCTAssertNil(state.tap(0), "The list does not take clicks in the confirm step")
        XCTAssertNil(state.tapConfirm(1))
        XCTAssertFalse(state.confirmClose)
        _ = state.tap(state.items.count - 1)
        XCTAssertEqual(state.tapConfirm(0), .closeGame)
    }
}

final class GuideInputGateTests: XCTestCase {
    private let all: [GuideInput] = [.guide, .navigation, .accept, .back, .other]

    func testAppInFrontWithoutMenu() {
        for input in all {
            XCTAssertEqual(GuideInputGate.route(input, appActive: true, playing: false, menuOpen: false), .app)
            XCTAssertEqual(GuideInputGate.route(input, appActive: true, playing: true, menuOpen: false), .app,
                           "With iOdus in front, the Xbox button goes Home as before")
        }
    }

    func testBackgroundWithoutGameIgnoresAll() {
        for input in all {
            XCTAssertEqual(GuideInputGate.route(input, appActive: false, playing: false, menuOpen: false), .ignore)
        }
    }

    func testBackgroundWhilePlayingOnlyTheGuideButton() {
        XCTAssertEqual(GuideInputGate.route(.guide, appActive: false, playing: true, menuOpen: false), .toggleMenu)
        for input in all where input != .guide {
            XCTAssertEqual(GuideInputGate.route(input, appActive: false, playing: true, menuOpen: false), .ignore,
                           "The game has the controller")
        }
    }

    func testOpenMenuHasTheNavigation() {
        for active in [false, true] {
            XCTAssertEqual(GuideInputGate.route(.guide, appActive: active, playing: true, menuOpen: true), .toggleMenu)
            XCTAssertEqual(GuideInputGate.route(.navigation, appActive: active, playing: true, menuOpen: true), .menu)
            XCTAssertEqual(GuideInputGate.route(.accept, appActive: active, playing: true, menuOpen: true), .menu)
            XCTAssertEqual(GuideInputGate.route(.back, appActive: active, playing: true, menuOpen: true), .menu)
            XCTAssertEqual(GuideInputGate.route(.other, appActive: active, playing: true, menuOpen: true), .ignore)
        }
    }

    func testPlayStateIsPlaying() {
        XCTAssertFalse(PlayState.idle.isPlaying)
        XCTAssertFalse(PlayState.preparing(id: "G", step: "x").isPlaying)
        XCTAssertTrue(PlayState.playing(id: "G").isPlaying)
    }
}

final class GuidePageTests: XCTestCase {
    func testOnAPageTheAppDrivesTheInputAndBGoesToTheMenu() {
        for active in [false, true] {
            XCTAssertEqual(GuideInputGate.route(.navigation, appActive: active, playing: true, menuOpen: true, page: true), .app)
            XCTAssertEqual(GuideInputGate.route(.accept, appActive: active, playing: true, menuOpen: true, page: true), .app)
            XCTAssertEqual(GuideInputGate.route(.other, appActive: active, playing: true, menuOpen: true, page: true), .app)
            XCTAssertEqual(GuideInputGate.route(.back, appActive: active, playing: true, menuOpen: true, page: true), .menu)
            XCTAssertEqual(GuideInputGate.route(.guide, appActive: active, playing: true, menuOpen: true, page: true), .toggleMenu)
        }
    }

    @MainActor
    func testPageRootDependsOnTheDepthAndOpenPanels() {
        let model = AppModel()
        model.startDemo()
        model.stack = [.home, .friends]
        XCTAssertTrue(model.guidePageAtRoot(depth: 2))
        model.stack = [.home, .friends, .messages]
        XCTAssertFalse(model.guidePageAtRoot(depth: 2), "A deeper screen: B goes back in the page")
        model.stack = [.home, .friends]
        model.statusPanel = .controllers
        XCTAssertFalse(model.guidePageAtRoot(depth: 2), "An open panel closes first")
    }
}

@MainActor
final class GuideMenuModelTests: XCTestCase {
    func testShowFromGuideOpensTheScreens() {
        let model = AppModel()
        model.startDemo()
        model.stack = [.home, .library]
        let game = model.games[0]

        model.statusPanel = .controllers
        model.showFromGuide(.friends, gameID: game.id)
        XCTAssertEqual(model.stack, [.home, .library, .friends])
        XCTAssertNil(model.statusPanel, "A panel must not hide the screen")
        model.showFromGuide(.friends, gameID: game.id)
        XCTAssertEqual(model.stack.count, 3, "No second Friends page")

        model.showFromGuide(.messages, gameID: game.id)
        XCTAssertEqual(model.screen, .messages)

        model.settingsIndex = 3
        model.showFromGuide(.settings, gameID: game.id)
        XCTAssertEqual(model.screen, .settings)
        XCTAssertEqual(model.settingsIndex, 0)

        let before = model.stack
        model.showFromGuide(.backToApp, gameID: game.id)
        model.showFromGuide(.resume, gameID: game.id)
        model.showFromGuide(.closeGame, gameID: game.id)
        XCTAssertEqual(model.stack, before, "These entries do not open a screen")
    }

    func testShowFromGuideAchievements() {
        let model = AppModel()
        model.startDemo()
        var game = model.games[0]
        game.titleId = "1907796436"
        model.games[0] = game
        model.showFromGuide(.achievements, gameID: game.id)
        XCTAssertEqual(model.screen, .achievements("1907796436"))
        model.showFromGuide(.achievements, gameID: game.id)
        XCTAssertEqual(model.stack.filter { $0 == .achievements("1907796436") }.count, 1)
        let count = model.stack.count
        model.showFromGuide(.achievements, gameID: "unknown")
        XCTAssertEqual(model.stack.count, count)
    }

    func testStopRunningGameWithoutGameDoesNothing() {
        let model = AppModel()
        model.startDemo()
        model.stopRunningGame()
        XCTAssertEqual(model.playState, .idle)
    }

    func testViewAndMenuTogetherOpenTheMenuOnce() {
        var pair = GuideButtonPair()
        XCTAssertFalse(pair.change(.view, pressed: true), "View alone does nothing")
        XCTAssertTrue(pair.change(.menu, pressed: true), "Menu while View is down completes the pair")
        XCTAssertFalse(pair.change(.menu, pressed: true), "A repeat while both stay down does not count again")
        XCTAssertFalse(pair.change(.menu, pressed: false))
        XCTAssertTrue(pair.change(.menu, pressed: true), "A new press of Menu with View down counts again")
        XCTAssertFalse(pair.change(.view, pressed: false))
        XCTAssertFalse(pair.change(.menu, pressed: false))
        XCTAssertFalse(pair.change(.menu, pressed: true), "Menu alone does nothing")
    }
}

final class InputGateTests: XCTestCase {
    func testOnlyRuntimesWithTheFlagHaveTheGate() throws {
        let json = #"{"id":"w11","name":"W","wineVersion":"11.0","wine":"bin/wine","wineserver":"bin/wineserver","components":[],"overrides":{},"inputGate":true}"#
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(json.utf8))
        let prefix = URL(fileURLWithPath: "/nonexistent/prefix")
        let gated = GameRuntime.from(manifest: manifest, root: URL(fileURLWithPath: "/nonexistent/w11"), prefix: prefix,
                                     usesBundle: false)
        XCTAssertTrue(gated.inputGate)
        XCTAssertEqual(gated.inputGateFile.path, "/nonexistent/prefix/drive_c/.iodus-input-gate")

        var old = manifest
        old.inputGate = nil
        XCTAssertFalse(GameRuntime.from(manifest: old, root: URL(fileURLWithPath: "/nonexistent/w11"), prefix: prefix,
                                        usesBundle: false).inputGate, "Release 2 and older: no gate")
        XCTAssertFalse(GameRuntime.gptk(root: URL(fileURLWithPath: "/nonexistent/gptk"), prefix: prefix).inputGate)
    }
}
