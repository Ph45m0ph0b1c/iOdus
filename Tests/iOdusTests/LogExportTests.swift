import XCTest
@testable import iOdus

final class LogExportTests: XCTestCase {
    func testRedaction() {
        let text = """
        user: 2533274800000001 signed in as player.one@example.com
        Authorization: XBL3.0 x=1234567890;eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl
        header XBL3.0 x=999;abcDEF next
        {"access_token":"abc.def-ghi","refresh_token": "zzz"}
        Bearer QWERTY12345==
        Player One logged in from /Users/tester/Library/Logs
        product 9NBLGGH4R315 and 1234567890123456 stay
        """
        let out = LogExport.redact(text, account: "Player One", home: "/Users/tester")
        XCTAssertFalse(out.contains("2533274800000001"))
        XCTAssertTrue(out.contains("user: <xuid>"))
        XCTAssertFalse(out.contains("player.one@example.com"))
        XCTAssertFalse(out.contains("eyJ"))
        XCTAssertFalse(out.contains("1234567890;"))
        XCTAssertFalse(out.contains("abcDEF"))
        XCTAssertFalse(out.contains("abc.def-ghi"))
        XCTAssertFalse(out.contains("zzz"))
        XCTAssertFalse(out.contains("QWERTY12345"))
        XCTAssertFalse(out.contains("Player One"))
        XCTAssertTrue(out.contains("<account> logged in from ~/Library/Logs"))
        XCTAssertTrue(out.contains("9NBLGGH4R315"), "Product IDs stay")
        XCTAssertTrue(out.contains("1234567890123456"), "Other 16-digit numbers stay")
    }

    /// Lines from a real export: the Wine form of the home folder, the user name
    /// from hdiutil, and the per-user temporary folder.
    func testRedactsUserNameAndPaths() {
        let text = """
        /dev/disk6 on /private/var/folders/h1/g69lzr314sxgv8mv9303w1ww0000gn/T/.tmp7oK0M7 (hfs, nobrowse, mounted by tester)
        Reading File Z:\\Users\\tester\\Games\\iOdus\\.xodus-chain-6oEtLt\\data.win took 0 ms
        z:\\users\\TESTER\\Games
        testers and tester2 stay
        """
        let out = LogExport.redact(text, account: "", home: "/Users/tester")
        XCTAssertFalse(out.contains("g69lzr314sxgv8mv9303w1ww0000gn"))
        XCTAssertTrue(out.contains("on <tmp>/T/.tmp7oK0M7"))
        XCTAssertTrue(out.contains("mounted by <user>)"))
        XCTAssertTrue(out.contains("Reading File ~\\Games\\iOdus"))
        XCTAssertFalse(out.lowercased().contains("users\\tester"))
        XCTAssertTrue(out.contains("testers and tester2 stay"), "Only the whole name is replaced")
    }

    func testTitleIdFromScid() {
        XCTAssertEqual(LogExport.titleId(fromScid: "00000000-0000-0000-0000-00007eefb20d"), "2129637901")
        XCTAssertNil(LogExport.titleId(fromScid: "abc"))
    }

    func testCollectAndZip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("logexport-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try "User 2533274800000001 signed in\n".write(to: logs.appendingPathComponent("Shelldiver.log"), atomically: true, encoding: .utf8)
        try "not a log".write(to: logs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let prefix = root.appendingPathComponent("prefix")
        let title = prefix.appendingPathComponent(
            "drive_c/users/crossover/AppData/Local/XodusGameSave/2533274800000001/00000000-0000-0000-0000-00007eefb20d")
        let container = title.appendingPathComponent("726f6f74")
        try fm.createDirectory(at: container, withIntermediateDirectories: true)
        try "time 5\nremote -\ndirty 1\n".write(to: container.appendingPathComponent("index"), atomically: true, encoding: .utf8)
        try Data("SECRET SAVE DATA".utf8).write(to: container.appendingPathComponent("b_626c6f62"))
        try "container root\nlocal 5\nremote -\n".write(to: title.appendingPathComponent("sync-conflict"), atomically: true, encoding: .utf8)

        let runtime = root.appendingPathComponent("Runtime/gptk-3.0-3")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        let lock = root.appendingPathComponent("lock.json")
        try #"{"commit":"53ea781"}"#.write(to: lock, atomically: true, encoding: .utf8)

        let sources = LogExport.Sources(
            logFolder: logs, prefix: prefix, runtimeRoot: root.appendingPathComponent("Runtime"), lockFile: lock,
            games: [.init(title: "Shelldiver", productId: "9P1", titleId: "2129637901", path: "/Users/tester/Games/Shelldiver")],
            accountName: "player.one@example.com", appVersion: "0.1.0 (build 8)", backendVersion: "xodus-cli 0.1.0",
            runtimeStatus: ["Wine ready"], home: "/Users/tester")

        let staging = root.appendingPathComponent("out")
        let files = Set(try LogExport.collect(sources, into: staging))
        XCTAssertEqual(files, ["logs/Shelldiver.log", "system.txt", "backend-source.lock.json", "games.txt",
                               "saves/2129637901/account-1/sync-conflict", "saves/2129637901/account-1/726f6f74/index"])
        let log = try String(contentsOf: staging.appendingPathComponent("logs/Shelldiver.log"), encoding: .utf8)
        XCTAssertEqual(log, "User <xuid> signed in\n")
        let system = try String(contentsOf: staging.appendingPathComponent("system.txt"), encoding: .utf8)
        XCTAssertTrue(system.contains("GPTK gptk-3.0-3"))
        XCTAssertTrue(system.contains("Backend xodus-cli 0.1.0"))
        let games = try String(contentsOf: staging.appendingPathComponent("games.txt"), encoding: .utf8)
        XCTAssertTrue(games.contains("Shelldiver\tproduct 9P1\ttitle 2129637901\t~/Games/Shelldiver"))

        // The zip file: the right name, and no save data and no XUID inside.
        let date = Date(timeIntervalSince1970: 1_793_678_344)
        let zip = try LogExport.export(sources, to: root.appendingPathComponent("Desktop"), date: date)
        XCTAssertEqual(zip.lastPathComponent, LogExport.fileName(date: date))
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("iOdus-logs-"))
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-Z1", zip.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        unzip.waitUntilExit()
        let listing = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(listing.contains("logs/Shelldiver.log"))
        XCTAssertFalse(listing.contains("b_626c6f62"), "No save data")
        XCTAssertFalse(listing.contains("2533274800000001"), "No XUID in file names")
    }
}
