import XCTest
@testable import iOdus

@MainActor
final class LibraryTests: XCTestCase {
    private func model() -> AppModel {
        let model = AppModel()
        model.startDemo()
        model.stack = [.home, .library]
        return model
    }

    func testSearchMatchesTitleAndPublisherWithoutCaseOrAccents() {
        let game = Game(id: "9X", title: "Pokémon Café", publisher: "Kite Games")
        XCTAssertTrue(AppModel.matches(game, "pokemon"))
        XCTAssertTrue(AppModel.matches(game, "CAFE kite"))
        XCTAssertFalse(AppModel.matches(game, "cafe forge"))
    }

    func testLibraryHidesBundlesAndConsoleCopiesOfTheSameGame() {
        func product(_ id: String, _ title: String, titleId: String? = nil, bundle: Set<String> = [],
                     console: Bool = false) -> CatalogProduct {
            CatalogProduct(id: id, kind: "Game", title: title, publisher: nil, tileArt: nil, heroArt: nil,
                           titleId: titleId, bundledIds: bundle, consoleOnly: console)
        }
        let products = [
            "9GAME0000001": product("9GAME0000001", "Lantern Road", titleId: "100"),
            "9EDITION0001": product("9EDITION0001", "Lantern Road Deluxe", bundle: ["9GAME0000001"]),
            "9CONSOLE0001": product("9CONSOLE0001", "Lantern Road", titleId: "100", console: true),
            "9EDITION0002": product("9EDITION0002", "Kite Hill", bundle: ["9NOTOWNED001"]),
            "9CONSOLE0002": product("9CONSOLE0002", "Quiet Harbor", titleId: "200", console: true),
        ]
        let access: [String: Access] = [
            "9GAME0000001": .gamePass, "9EDITION0001": .owned, "9CONSOLE0001": .gamePass,
            "9EDITION0002": .gamePass, "9CONSOLE0002": .owned,
        ]
        let shown = LibraryRules.withoutDuplicates(access, products: products)
        // The bundle goes, and its game keeps the better access of the two.
        XCTAssertEqual(shown, ["9GAME0000001": .owned, "9EDITION0002": .gamePass, "9CONSOLE0002": .owned])
    }

    func testLauncherGameHasNoInstallButton() {
        let model = model()
        var game = Game(id: "9LAUNCHER001", title: "Lantern Road", publisher: "Studio")
        game.launcher = "the EA app"
        XCTAssertFalse(model.detailActions(for: game).contains(.primary))
        game.launcher = nil
        XCTAssertEqual(model.detailActions(for: game).first, .primary)
    }

    func testFailedInstallPromptHasOnlyClose() {
        var prompt = InstallPrompt(game: Game(id: "9X", title: "X", publisher: ""))
        prompt.stage = .failed("No package.")
        XCTAssertEqual(prompt.buttonCount, 1)
    }

    func testFiltersAndSearchCombine() {
        let model = model()
        let all = model.games(in: .all).count
        XCTAssertEqual(model.games(in: .owned).count + model.games(in: .gamePass).count, all)
        XCTAssertEqual(model.games(in: .installed).count,
                       model.games.filter { $0.installState != .notInstalled }.count)
        model.focusSearch()
        "harbor".forEach { model.type(String($0)) }
        XCTAssertEqual(model.libraryGames.map(\.title), ["Harbor Lights"])
        model.deleteKey()
        XCTAssertEqual(model.librarySearch, "harbo")
        model.back()
        XCTAssertEqual(model.librarySearch, "", "B first clears the text")
        model.back()
        XCTAssertEqual(model.libraryFocus, .filters, "B then leaves the search box")
        XCTAssertEqual(model.screen, .library)
    }

    func testDpadReachesFiltersAndSearch() {
        let model = model()
        XCTAssertEqual(model.libraryFocus, .grid)
        model.move(.left)
        XCTAssertEqual(model.libraryFocus, .filters, "Left from the first column")
        model.move(.down)
        XCTAssertEqual(model.libraryFilter, .owned, "Down changes the filter at once")
        model.move(.up)
        model.move(.up)
        XCTAssertEqual(model.libraryFocus, .search, "Up from the first filter")
        model.move(.down)
        model.move(.right)
        XCTAssertEqual(model.libraryFocus, .grid)
        model.shiftLibraryFilter(-1)
        XCTAssertEqual(model.libraryFilter, .installed, "LB wraps to the last filter")
    }
}

final class PlayHistoryTests: XCTestCase {
    func testKeepsTheNewerDateAndPersists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("played-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var history = PlayHistory(file: file)
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        history.record("9MSVVM5NS9L6", at: new)
        history.record("9P0000000002", at: old)

        var dredge = Game(id: "9MSVVM5NS9L6", title: "DREDGE", publisher: "")
        var other = Game(id: "9P0000000002", title: "Other", publisher: "")
        other.lastPlayed = new   // Microsoft knows a newer date
        dredge.lastPlayed = nil  // Microsoft does not know the game

        let merged = PlayHistory(file: file).merged(into: [dredge, other])
        XCTAssertEqual(merged[0].lastPlayed, new, "The local date fills the gap")
        XCTAssertEqual(merged[1].lastPlayed, new, "The newer Microsoft date stays")
    }
}

@MainActor
final class ScrollTests: XCTestCase {
    func testScrollMovesTheFocusLikeTheDpad() {
        let model = AppModel()
        model.startDemo()

        // Home: the vertical wheel moves along the horizontal game row.
        model.scroll(vertical: true, forward: true)
        XCTAssertEqual(model.homeIndex[0], 1)

        // Library grid: it scrolls natively, so the wheel does not move the focus.
        model.stack = [.home, .library]
        model.scroll(vertical: true, forward: true)
        model.scroll(vertical: false, forward: true)
        XCTAssertEqual(model.libraryIndex, 0)

        // Store rows: a horizontal swipe moves along the row.
        model.stack = [.home, .store]
        model.storeFocus = .rows
        model.scroll(vertical: false, forward: true)
        XCTAssertEqual(model.storeIndex[0], 1)

        // A game page ignores vertical scrolling.
        model.stack = [.home, .detail(model.games[0].id)]
        model.scroll(vertical: true, forward: true)
        XCTAssertEqual(model.detailIndex, 0)

        // Settings: the wheel moves through the category list.
        model.stack = [.home, .settings]
        model.scroll(vertical: true, forward: true)
        XCTAssertEqual(model.settingsCategory, 1)
    }
}

@MainActor
final class TopSearchTests: XCTestCase {
    func testHomeSearchOpensTheLibraryAndTheGridReachesTheSearch() {
        let model = AppModel()
        model.startDemo()
        model.focusSearch()   // Y on the home screen
        XCTAssertEqual(model.screen, .library)
        XCTAssertEqual(model.libraryFocus, .search)
        model.move(.down)
        XCTAssertEqual(model.libraryFocus, .grid, "Down goes to the grid below the search box")
        model.move(.up)
        XCTAssertEqual(model.libraryFocus, .search, "Up from the first row goes to the search box")
        model.move(.left)
        XCTAssertEqual(model.libraryFocus, .filters)
    }
}
