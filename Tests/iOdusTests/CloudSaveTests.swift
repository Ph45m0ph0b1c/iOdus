import XCTest
@testable import iOdus

final class CloudSaveTests: XCTestCase {
    func testScidIsTheTitleIdInHex() {
        XCTAssertEqual(CloudSaveStatus.scid(titleId: "2129637901"), "00000000-0000-0000-0000-00007eefb20d")
        XCTAssertNil(CloudSaveStatus.scid(titleId: "x"))
    }

    func testStatusFromIndexFiles() throws {
        let synced = "display x\ntime 1793678344\nremote 2026-11-03T03:59:04.0000000Z\ndirty 0\nrevision 2\n"
        let dirty = "display x\ntime 1793677467\nremote 2026-10-28T13:53:15.0000000Z\ndirty 1\nrevision 32\n"
        let remote = try XCTUnwrap(CloudSaveStatus.parseRemote("2026-11-03T03:59:04.0000000Z"))
        XCTAssertEqual(CloudSaveStatus.combine([synced]), .synced(remote))
        XCTAssertEqual(CloudSaveStatus.combine([synced, dirty]), .waiting(Date(timeIntervalSince1970: 1793678344)),
                       "One container not uploaded: the title waits")
        XCTAssertEqual(CloudSaveStatus.combine([]), CloudSaveStatus.noSaves)
    }

    func testReadFindsTheSaveFolder() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        XCTAssertEqual(CloudSaveStatus.read(titleId: "2129637901", prefix: prefix), CloudSaveStatus.noSaves)
        let folder = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local/XodusGameSave/1/00000000-0000-0000-0000-00007eefb20d/726f6f74")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "time 5\nremote -\ndirty 1\n".write(to: folder.appendingPathComponent("index"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CloudSaveStatus.read(titleId: "2129637901", prefix: prefix), .waiting(Date(timeIntervalSince1970: 5)))
    }
}

final class SaveConflictTests: XCTestCase {
    private func makePrefix() throws -> (URL, URL) {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(UUID().uuidString)")
        let title = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local/XodusGameSave/42/00000000-0000-0000-0000-00007eefb20d")
        let container = title.appendingPathComponent("726f6f74")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try "time 5\nremote -\ndirty 1\n".write(to: container.appendingPathComponent("index"), atomically: true, encoding: .utf8)
        try Data("save".utf8).write(to: container.appendingPathComponent("b_1"))
        return (prefix, title)
    }

    func testConflictFileWins() throws {
        let (prefix, title) = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        try "container root\nlocal 1793677467\nremote 2026-11-03T03:59:04.0000000Z\n"
            .write(to: title.appendingPathComponent("sync-conflict"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CloudSaveStatus.read(titleId: "2129637901", prefix: prefix),
                       .conflict(local: Date(timeIntervalSince1970: 1793677467),
                                 cloud: CloudSaveStatus.parseRemote("2026-11-03T03:59:04.0000000Z")))
    }

    func testBackupCopiesTheMacSave() throws {
        let (prefix, _) = try makePrefix()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix); try? FileManager.default.removeItem(at: root) }
        let backup = try XCTUnwrap(CloudSaveStatus.backup(titleId: "2129637901", prefix: prefix, into: root))
        let copied = backup.appendingPathComponent("42/726f6f74/b_1")
        XCTAssertEqual(try Data(contentsOf: copied), Data("save".utf8))
        XCTAssertNil(try CloudSaveStatus.backup(titleId: "1", prefix: prefix, into: root), "No saves: no backup")
    }
}

@MainActor
final class SaveConflictPromptTests: XCTestCase {
    func testThreeButtonsAndCancel() {
        let model = AppModel()
        model.startDemo()
        var prompt = InstallPrompt(game: model.games[1])
        prompt.stage = .saveConflict(local: nil, cloud: nil)
        model.installPrompt = prompt
        model.move(.right); model.move(.right); model.move(.right)
        XCTAssertEqual(model.installPrompt?.focus, 2, "Three buttons; focus stops at Cancel")
        model.confirm()
        XCTAssertNil(model.installPrompt, "Cancel closes the prompt")
    }
}
