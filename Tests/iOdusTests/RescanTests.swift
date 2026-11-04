import XCTest
@testable import iOdus

@MainActor
final class RescanTests: XCTestCase {
    private var temp: URL!
    private var games: URL { temp.appendingPathComponent("Games") }
    private var state: URL { temp.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("rescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: games, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    @discardableResult
    private func folder(_ name: String, storeIds: [String]?) throws -> URL {
        let url = games.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let storeIds {
            let ids = storeIds.map { "<StoreId>\($0)</StoreId>" }.joined(separator: "\n")
            try "<Game><Identity Name=\"X\"/>\n\(ids)\n</Game>".write(to: url.appendingPathComponent("MicrosoftGame.Config"),
                                                                    atomically: true, encoding: .utf8)
        }
        return url
    }

    func testStoreIdSkipsThePlaceholder() {
        XCTAssertEqual(DownloadManager.storeId(inConfig: "<StoreId>000000000000</StoreId>\n<StoreId>9msvvm5ns9l6</StoreId>"),
                       "9MSVVM5NS9L6")
        XCTAssertEqual(DownloadManager.storeId(inConfig: "<StoreId> 9PCR3Z2MSM4T </StoreId>"), "9PCR3Z2MSM4T")
        XCTAssertNil(DownloadManager.storeId(inConfig: "<StoreId>000000000000</StoreId>"))
        XCTAssertNil(DownloadManager.storeId(inConfig: "<TitleId>70cd4db4</TitleId>"))
    }

    func testRescanAddsUnknownGamesAndReportsCopies() throws {
        let hades = try folder("Hades II (9PCR3Z2MSM4T)", storeIds: ["9PCR3Z2MSM4T"])
        try folder("Hades II", storeIds: ["9PCR3Z2MSM4T"])
        try folder("DREDGE", storeIds: ["000000000000", "9MSVVM5NS9L6"])
        try folder("Mystery", storeIds: ["9ZZZZZZZZZZZ"])
        try folder("Notes", storeIds: nil)
        try FileManager.default.createDirectory(at: games.appendingPathComponent(".xodus-mounts-x"), withIntermediateDirectories: true)
        let record = """
        {"installs":{"9PCR3Z2MSM4T":{"productId":"9PCR3Z2MSM4T","title":"Hades II","contentId":"c","path":"\(hades.path)","installedAt":0}},"tasks":[]}
        """
        try record.write(to: state, atomically: true, encoding: .utf8)
        let manager = DownloadManager(stateFile: state, installRoot: games)
        var changes = 0
        manager.onChange = { changes += 1 }

        let result = manager.rescan(titles: ["9MSVVM5NS9L6": "DREDGE"])
        XCTAssertEqual(result.added.map(\.productId), ["9MSVVM5NS9L6", "9ZZZZZZZZZZZ"])
        XCTAssertEqual(result.added.map(\.title), ["DREDGE", "Mystery"], "An unknown game keeps its folder name")
        XCTAssertEqual(result.copies, ["Hades II"], "The known folder stays; the copy is only reported")
        XCTAssertEqual(manager.installs["9PCR3Z2MSM4T"]?.path, hades.path)
        XCTAssertEqual(changes, 1)

        let again = DownloadManager(stateFile: state, installRoot: games)
        XCTAssertNotNil(again.installs["9MSVVM5NS9L6"], "The state file keeps the new records")
        XCTAssertEqual(again.rescan(titles: [:]).added, [], "A second rescan adds nothing")
    }

    func testRescanForgetsGoneFoldersOnlyInTheInstallFolder() throws {
        let gone = games.appendingPathComponent("Gone").path
        let elsewhere = temp.appendingPathComponent("OtherDrive/Game").path
        let record = """
        {"installs":{"AAAAAAAAAAAA":{"productId":"AAAAAAAAAAAA","title":"Gone","contentId":"c","path":"\(gone)","installedAt":0},\
        "BBBBBBBBBBBB":{"productId":"BBBBBBBBBBBB","title":"Elsewhere","contentId":"c","path":"\(elsewhere)","installedAt":0}},"tasks":[]}
        """
        try record.write(to: state, atomically: true, encoding: .utf8)
        // The load drops records without a folder, so the folders exist at the load.
        try FileManager.default.createDirectory(atPath: gone, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let manager = DownloadManager(stateFile: state, installRoot: games)
        // Then the user deletes both while iOdus runs.
        try FileManager.default.removeItem(atPath: gone)
        try FileManager.default.removeItem(atPath: elsewhere)
        let result = manager.rescan(titles: [:])
        XCTAssertEqual(result.forgotten, ["Gone"])
        XCTAssertNil(manager.installs["AAAAAAAAAAAA"])
        XCTAssertNotNil(manager.installs["BBBBBBBBBBBB"], "A game outside the install folder stays")

        let unmounted = DownloadManager(stateFile: temp.appendingPathComponent("none.json"),
                                        installRoot: temp.appendingPathComponent("Missing"))
        XCTAssertEqual(unmounted.rescan(titles: [:]), DownloadManager.RescanResult(), "No install folder: no change")
    }

    func testMessage() {
        let game = InstalledGame(productId: "A", title: "DREDGE", contentId: "", path: "/x", installedAt: Date())
        XCTAssertEqual(AppModel.rescanMessage(.init()), "iOdus found no new games.")
        XCTAssertEqual(AppModel.rescanMessage(.init(added: [game], copies: ["Hades II"])),
                       "iOdus found 1 game: DREDGE. Not added, because iOdus already uses another folder for the game: Hades II.")
    }
}
