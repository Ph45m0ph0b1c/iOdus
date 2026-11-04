import XCTest
@testable import iOdus

/// All folders are temporary. No real game or the real state file is touched.
@MainActor
final class UninstallTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func makeGame(_ name: String, config: Bool = true) throws -> URL {
        let folder = temp.appendingPathComponent("Games/\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 5000).write(to: folder.appendingPathComponent("Game.exe"))
        if config { try Data("<Game/>".utf8).write(to: folder.appendingPathComponent("MicrosoftGame.config")) }
        return folder
    }

    func testSafetyRules() throws {
        let game = try makeGame("DREDGE")
        XCTAssertNil(DownloadManager.uninstallProblem(path: game.path, installRoot: temp.appendingPathComponent("Games").path))
        let noConfig = try makeGame("Other", config: false)
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: noConfig.path), "Only real game folders")
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: "/"))
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: "/Users"))
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: NSHomeDirectory()))
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: "relative/Game"))
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: temp.appendingPathComponent("Games").path,
                                                         installRoot: temp.appendingPathComponent("Games").path),
                        "Never the install root")
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: temp.appendingPathComponent("Games/Missing").path))
        // A path with ".." resolves first: it must not escape to a parent folder.
        XCTAssertNotNil(DownloadManager.uninstallProblem(path: game.path + "/.."))
    }

    func testUninstallDeletesTheFolderAndForgetsTheGame() throws {
        let game = try makeGame("DREDGE")
        let keep = try makeGame("Shelldiver")
        let state = temp.appendingPathComponent("state.json")
        let record = """
        {"installs":{"9MSVVM5NS9L6":{"productId":"9MSVVM5NS9L6","title":"DREDGE","contentId":"x","path":"\(game.path)","installedAt":0}},"tasks":[]}
        """
        try record.write(to: state, atomically: true, encoding: .utf8)
        let manager = DownloadManager(stateFile: state, installRoot: temp.appendingPathComponent("Games"))
        XCTAssertEqual(manager.installState(for: "9MSVVM5NS9L6"), .installed)
        XCTAssertGreaterThan(DownloadManager.folderSize(game.path), 0)
        try manager.uninstall("9MSVVM5NS9L6")
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path), "Other games stay")
        XCTAssertEqual(manager.installState(for: "9MSVVM5NS9L6"), .notInstalled)
        let again = DownloadManager(stateFile: state, installRoot: temp.appendingPathComponent("Games"))
        XCTAssertNil(again.installs["9MSVVM5NS9L6"], "The state file forgets it too")
        XCTAssertThrowsError(try manager.uninstall("9MSVVM5NS9L6"))
    }
}
