import XCTest
@testable import iOdus

/// All tests use temporary folders. They never touch the real prefix or the real backups.
final class SaveBackupTests: XCTestCase {
    private let titleId = "2129637901"
    private let scid = "00000000-0000-0000-0000-00007eefb20d"
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("savebackups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private var prefix: URL { temp.appendingPathComponent("prefix") }
    private var root: URL { temp.appendingPathComponent("SaveBackups") }

    private func titleFolder(xuid: String = "42") -> URL {
        prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local/XodusGameSave/\(xuid)/\(scid)")
    }

    /// Writes one container "root" with a blob and an index.
    private func writeSave(in title: URL, blob: String, remote: String, dirty: Int = 0, time: Int = 100) throws {
        let container = title.appendingPathComponent("726f6f74")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data(blob.utf8).write(to: container.appendingPathComponent("b_1"))
        try "display x\ntime \(time)\nremote \(remote)\ndirty \(dirty)\nrevision 1\nblob 31 4 -\n"
            .write(to: container.appendingPathComponent("index"), atomically: true, encoding: .utf8)
    }

    private func makeBackup(stamp: String, blob: String, remote: String) throws -> URL {
        let folder = root.appendingPathComponent("\(titleId)-\(stamp)")
        try writeSave(in: folder.appendingPathComponent("42"), blob: blob, remote: remote)
        return folder
    }

    private func blob(_ title: URL) throws -> String {
        String(decoding: try Data(contentsOf: title.appendingPathComponent("726f6f74/b_1")), as: UTF8.self)
    }

    private func index(_ title: URL) throws -> String {
        try String(contentsOf: title.appendingPathComponent("726f6f74/index"), encoding: .utf8)
    }

    func testListNewestFirstAndSkipsOtherTitles() throws {
        _ = try makeBackup(stamp: "20261101-230000", blob: "old", remote: "2026-11-01T22:00:00.0000000Z")
        _ = try makeBackup(stamp: "20261102-230000", blob: "new", remote: "2026-11-02T22:00:00.0000000Z")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("\(titleId)-empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("1907796436-20261102-230000/42"),
                                                withIntermediateDirectories: true)
        let list = SaveBackups.list(titleId: titleId, root: root)
        XCTAssertEqual(list.map(\.id), ["\(titleId)-20261102-230000", "\(titleId)-20261101-230000"],
                       "Newest first; an empty folder and another title do not show")
        XCTAssertEqual(list[0].accounts, ["42"])
        XCTAssertGreaterThan(list[0].bytes, 0)
        XCTAssertTrue(SaveBackups.hasBackups(titleId: titleId, root: root))
        XCTAssertFalse(SaveBackups.hasBackups(titleId: "1", root: root))
    }

    func testManualFolderNameUsesTheFolderDate() throws {
        let folder = root.appendingPathComponent("\(titleId)-manual-test/42")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let list = SaveBackups.list(titleId: titleId, root: root)
        XCTAssertEqual(list.count, 1)
        XCTAssertGreaterThan(list[0].date, Date().addingTimeInterval(-60))
    }

    /// A backup without the account level (<backup>/726f6f74/index) is not a
    /// backup. Before this check, a restore made a false account folder "726f6f74".
    func testBackupWithoutAccountFolderIsSkipped() throws {
        let wrong = root.appendingPathComponent("\(titleId)-manual-test")
        try writeSave(in: wrong, blob: "old", remote: "2026-11-03T03:59:04.0000000Z")
        let digits = root.appendingPathComponent("\(titleId)-20260101-000000/12345678")
        try FileManager.default.createDirectory(at: digits, withIntermediateDirectories: true)
        try "display x\n".write(to: digits.appendingPathComponent("index"), atomically: true, encoding: .utf8)
        XCTAssertTrue(SaveBackups.list(titleId: titleId, root: root).isEmpty)
    }

    func testStatusIgnoresFoldersThatAreNotAccounts() throws {
        try writeSave(in: titleFolder(), blob: "a", remote: "2026-11-03T03:59:04.0000000Z")
        let falseAccount = titleFolder(xuid: "726f6f74")
        try writeSave(in: falseAccount, blob: "b", remote: "2026-11-03T03:59:04.0000000Z")
        try "container -\nlocal 0\nremote 2026-11-03T03:59:04.0000000Z\n"
            .write(to: falseAccount.appendingPathComponent(CloudSaveStatus.conflictFile), atomically: true, encoding: .utf8)
        XCTAssertEqual(CloudSaveStatus.titleFolders(scid: scid, prefix: prefix).map { $0.deletingLastPathComponent().lastPathComponent }, ["42"])
        if case .conflict = CloudSaveStatus.read(titleId: titleId, prefix: prefix) { XCTFail("false conflict") }
    }

    /// The runtime keeps the old container in ".recovery-<name>-<guid>" after a
    /// replacement. Its old "dirty 1" must not make the status "waiting".
    func testRecoveryFoldersDoNotCount() throws {
        try writeSave(in: titleFolder(), blob: "new", remote: "2026-11-03T12:52:46.0000000Z", dirty: 0, time: 1793710366)
        let recovery = titleFolder().appendingPathComponent(".recovery-726f6f74-{322C78C8-0C56-449D-8E67-5DDCEBD93138}")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try "display x\ntime 100\nremote 2026-11-03T03:59:04.0000000Z\ndirty 1\nrevision 2\n"
            .write(to: recovery.appendingPathComponent("index"), atomically: true, encoding: .utf8)
        guard case .synced = CloudSaveStatus.read(titleId: titleId, prefix: prefix) else {
            return XCTFail("expected synced, got \(CloudSaveStatus.read(titleId: titleId, prefix: prefix))")
        }
    }

    func testRestoreWhenTheCloudDidNotChangeUploads() throws {
        let remote = "2026-11-01T22:00:00.0000000Z"
        try writeSave(in: titleFolder(), blob: "current", remote: remote)
        _ = try makeBackup(stamp: "20261101-230000", blob: "restored", remote: remote)
        let backup = try XCTUnwrap(SaveBackups.list(titleId: titleId, root: root).first)

        XCTAssertEqual(try SaveBackups.restore(backup, prefix: prefix, root: root), .willUpload)
        XCTAssertEqual(try blob(titleFolder()), "restored")
        XCTAssertTrue(try index(titleFolder()).contains("dirty 1\n"), "The next start uploads the restored save")
        XCTAssertEqual(CloudSaveStatus.read(titleId: titleId, prefix: prefix), .waiting(Date(timeIntervalSince1970: 100)))

        // The undo copy holds the save from before the restore.
        let all = SaveBackups.list(titleId: titleId, root: root)
        XCTAssertEqual(all.count, 2)
        let undo = try XCTUnwrap(all.first { $0.id != backup.id })
        XCTAssertEqual(try blob(undo.url.appendingPathComponent("42")), "current")
    }

    func testRestoreWhenTheCloudIsNewerAsksAtPlay() throws {
        try writeSave(in: titleFolder(), blob: "current", remote: "2026-11-03T03:59:04.0000000Z")
        _ = try makeBackup(stamp: "20261101-230000", blob: "restored", remote: "2026-11-01T22:00:00.0000000Z")
        // A stale conflict file in the backup must not come back.
        try "container root\nlocal 1\nremote -\n".write(
            to: root.appendingPathComponent("\(titleId)-20261101-230000/42/sync-conflict"), atomically: true, encoding: .utf8)
        let backup = try XCTUnwrap(SaveBackups.list(titleId: titleId, root: root).first)

        XCTAssertEqual(try SaveBackups.restore(backup, prefix: prefix, root: root), .willAsk)
        XCTAssertEqual(try blob(titleFolder()), "restored")
        XCTAssertEqual(CloudSaveStatus.read(titleId: titleId, prefix: prefix),
                       .conflict(local: Date(timeIntervalSince1970: 100),
                                 cloud: CloudSaveStatus.parseRemote("2026-11-03T03:59:04.0000000Z")),
                       "Play asks which save to keep, with the cloud time of the replaced Mac save")
    }

    func testRestoreWithoutAMacSaveMakesTheFolder() throws {
        _ = try makeBackup(stamp: "20261101-230000", blob: "restored", remote: "2026-11-01T22:00:00.0000000Z")
        let backup = try XCTUnwrap(SaveBackups.list(titleId: titleId, root: root).first)
        XCTAssertEqual(try SaveBackups.restore(backup, prefix: prefix, root: root), .willUpload)
        XCTAssertEqual(try blob(titleFolder()), "restored")
        XCTAssertEqual(SaveBackups.list(titleId: titleId, root: root).count, 1, "No Mac save: no undo copy")
    }

    func testDeleteOnlyInsideTheRoot() throws {
        _ = try makeBackup(stamp: "20261101-230000", blob: "x", remote: "-")
        let backup = try XCTUnwrap(SaveBackups.list(titleId: titleId, root: root).first)
        let outside = SaveBackup(url: temp.appendingPathComponent("prefix"), titleId: titleId, date: Date(),
                                 accounts: [], bytes: 0)
        XCTAssertThrowsError(try SaveBackups.delete(outside, root: root))
        try SaveBackups.delete(backup, root: root)
        XCTAssertTrue(SaveBackups.list(titleId: titleId, root: root).isEmpty)
    }
}

@MainActor
final class SaveBackupPageTests: XCTestCase {
    func testPageAndPrompts() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("savepage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("SaveBackups")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("2129637901-20261101-230000/42/726f6f74"),
                                                withIntermediateDirectories: true)
        try "time 5\nremote -\ndirty 0\n".write(
            to: root.appendingPathComponent("2129637901-20261101-230000/42/726f6f74/index"), atomically: true, encoding: .utf8)

        let model = AppModel()
        model.account = .ready
        model.saveBackupRoot = root
        model.savePrefixOverride = temp.appendingPathComponent("prefix")
        var game = MockLibrary.games[0]
        game.titleId = "2129637901"
        var other = MockLibrary.games[1]
        other.titleId = "1"
        model.games = [game, other]

        XCTAssertEqual(model.detailActions(for: game).last, .saves)
        XCTAssertFalse(model.detailActions(for: other).contains(.saves), "No backups: no button")

        model.openSaveBackups(game)
        XCTAssertEqual(model.screen, .saveBackups(game.id))
        XCTAssertEqual(model.saveBackupList.count, 1)

        // X asks before a delete, with the focus on Cancel.
        model.requestDelete(gameID: game.id)
        XCTAssertEqual(model.installPrompt?.focus, 1)
        model.tapPrompt(1)
        XCTAssertEqual(model.saveBackupList.count, 1, "Cancel keeps the backup")

        // A asks before a restore; Restore replaces the Mac save.
        model.requestRestore(gameID: game.id)
        model.tapPrompt(0)
        XCTAssertNil(model.installPrompt)
        let restored = temp.appendingPathComponent(
            "prefix/drive_c/users/crossover/AppData/Local/XodusGameSave/42/00000000-0000-0000-0000-00007eefb20d/726f6f74/index")
        XCTAssertTrue(try String(contentsOf: restored, encoding: .utf8).contains("dirty 1"))
    }
}
