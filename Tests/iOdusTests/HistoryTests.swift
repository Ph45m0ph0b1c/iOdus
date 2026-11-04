import XCTest
@testable import iOdus

final class HistoryTests: XCTestCase {
    private func played(_ id: String, _ name: String, _ date: String?) -> PlayedTitle {
        PlayedTitle(titleId: id, name: name, lastPlayed: date, currentGamerscore: 120, totalGamerscore: 1000)
    }

    func testCatalogReadsXboxTitleId() {
        let product: [String: Any] = [
            "ProductId": "9MSVVM5NS9L6",
            "AlternateIds": [["IdType": "LegacyWindowsStoreProductId", "Value": "92ae948c"],
                             ["IdType": "XboxTitleId", "Value": "1907796436"]],
        ]
        XCTAssertEqual(Catalog.parse(product)?.titleId, "1907796436")
        XCTAssertNil(Catalog.titleId(["AlternateIds": [["IdType": "XboxTitleId", "Value": "abc"]]]))
        XCTAssertNil(Catalog.titleId([:]))
    }

    func testHistoryDateWithOffsetAndNineFractionDigits() {
        XCTAssertNotNil(played("1", "A", "2026-11-02T02:20:36.152041500+00:00").lastPlayedDate)
    }

    func testApplyHistoryMatchesTitleIdThenName() {
        let games = [
            Game(id: "9A", title: "Alpha", publisher: "", titleId: "111"),
            Game(id: "9B", title: "Beta: The Game", publisher: "", titleId: nil),
            Game(id: "9C", title: "Gamma", publisher: "", titleId: "333"),
        ]
        let history = [played("111", "Alpha (PC)", "2026-11-01T10:00:00Z"),
                       played("999", "Beta - The Game", "2026-10-01T10:00:00Z")]
        let result = AppModel.applyHistory(history, to: games)
        XCTAssertNotNil(result[0].lastPlayed, "Match by title ID, also with a different name")
        XCTAssertEqual(result[0].gamerscore?.current, 120)
        XCTAssertNotNil(result[1].lastPlayed, "Match by name, without case and punctuation")
        XCTAssertNil(result[2].lastPlayed)
    }

    func testRecentOrder() {
        func game(_ id: String, _ state: InstallState, played days: Double? = nil) -> Game {
            var g = Game(id: id, title: id, publisher: "", installState: state)
            g.lastPlayed = days.map { Date(timeIntervalSince1970: 1_000_000 - $0 * 86_400) }
            return g
        }
        let games = [
            game("A", .notInstalled),
            game("B", .installed),
            game("C", .notInstalled, played: 5),
            game("D", .downloading(progress: 0.5)),
            game("E", .installed, played: 1),
        ]
        XCTAssertEqual(AppModel.recentOrder(games).map(\.id), ["D", "E", "C", "B", "A"])
    }
}

final class TitleHistoryCLITests: XCTestCase {
    private func fakeCLI(_ body: String) throws -> XodusCLI {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-history-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return XodusCLI(url: url)
    }

    func testSendsRequestOnStdinAndReadsItems() async throws {
        // The fake CLI answers only when the request on stdin is correct.
        let cli = try fakeCLI(#"""
        [ "$1 $2" = "native-social people" ] || exit 2
        read -r line
        case "$line" in *'"operation":"games"'*'"xuid":"me"'*|*'"xuid":"me"'*'"operation":"games"'*) ;; *) exit 3 ;; esac
        case "$line" in *'"account":"a@b.test"'*) ;; *) exit 4 ;; esac
        echo '{"schema":1,"kind":"people","account":"a@b.test","operation":"games","result":{"items":[{"titleId":"1907796436","name":"DREDGE","lastPlayed":"2026-11-01T10:00:00+00:00"}],"continuation":null,"truncated":false}}'
        """#)
        let items = try await cli.titleHistory(account: "a@b.test")
        XCTAssertEqual(items.map(\.titleId), ["1907796436"])
        XCTAssertNotNil(items[0].lastPlayedDate)
        XCTAssertNil(items[0].currentGamerscore)
    }

    func testRejectsOtherAccount() async throws {
        let cli = try fakeCLI(#"""
        cat >/dev/null
        echo '{"schema":1,"kind":"people","account":"other@b.test","operation":"games","result":{"items":[]}}'
        """#)
        do {
            _ = try await cli.titleHistory(account: "a@b.test")
            XCTFail("Expected an error")
        } catch {}
    }
}
