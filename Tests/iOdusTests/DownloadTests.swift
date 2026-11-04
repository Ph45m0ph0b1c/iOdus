import XCTest
@testable import iOdus

final class ProgressRecordTests: XCTestCase {
    private func line(_ json: String) -> String { "NEXUS_PROGRESS " + json }

    func testValidRecord() throws {
        let record = try XCTUnwrap(ProgressRecord.parse(line(
            #"{"schema":1,"event":"progress","sequence":3,"phase":"downloading","paused":false,"canPause":true,"completedBytes":50,"totalBytes":200,"bytesPerSecond":10}"#)))
        XCTAssertEqual(record.completedBytes, 50)
        XCTAssertEqual(record.totalBytes, 200)
    }

    func testRejectsBadRecords() {
        XCTAssertNil(ProgressRecord.parse("50% done"))
        XCTAssertNil(ProgressRecord.parse(line(
            #"{"schema":2,"event":"progress","sequence":1,"phase":"downloading","paused":false,"canPause":true,"completedBytes":1,"totalBytes":2,"bytesPerSecond":0}"#)))
        XCTAssertNil(ProgressRecord.parse(line(
            #"{"schema":1,"event":"progress","sequence":1,"phase":"exploding","paused":false,"canPause":true,"completedBytes":1,"totalBytes":2,"bytesPerSecond":0}"#)))
        XCTAssertNil(ProgressRecord.parse(line(
            #"{"schema":1,"event":"progress","sequence":1,"phase":"downloading","paused":false,"canPause":true,"completedBytes":5,"totalBytes":2,"bytesPerSecond":0}"#)))
    }
}

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fake `xodus-cli streaming` that prints progress and then the given end.
    private func fakeCLI(exit code: Int, final phase: String) throws -> XodusCLI {
        let url = root.appendingPathComponent("fake-cli")
        let p = { (seq: Int, phase: String, done: Int) in
            #"echo 'NEXUS_PROGRESS {"schema":1,"event":"progress","sequence":\#(seq),"phase":"\#(phase)","paused":false,"canPause":true,"completedBytes":\#(done),"totalBytes":100,"bytesPerSecond":5}'"#
        }
        let script = """
        #!/bin/sh
        # $3 is the destination folder.
        mkdir -p "$3"
        \(p(1, "metadata", 0))
        echo "a log line"
        \(p(2, "downloading", 40))
        \(p(3, "downloading", 100))
        \(p(4, phase, 100))
        exit \(code)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return XodusCLI(url: url)
    }

    private func manager(_ cli: XodusCLI) -> DownloadManager {
        let manager = DownloadManager(stateFile: root.appendingPathComponent("state.json"),
                                      installRoot: root.appendingPathComponent("Games"))
        manager.cli = cli
        return manager
    }

    private let game = Game(id: "9MSVVM5NS9L6", title: "DREDGE", publisher: "Team17")
    private let choice = InstallChoice(productId: "9MSVVM5NS9L6", contentId: "90a21577-f88b-45f2-bebf-584b301426ca",
                                       title: "DREDGE", platform: "Windows.Desktop", packageFormat: "MSIXVC",
                                       kind: "Game", supported: true, downloadBytes: 100, installBytes: nil)

    private func waitUntil(_ manager: DownloadManager, _ condition: @escaping (DownloadTask?) -> Bool) async throws {
        for _ in 0..<100 {
            if condition(manager.task(game.id)) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out. Task: \(String(describing: manager.task(game.id)))")
    }

    func testCompleteDownloadBecomesInstalledAndPersists() async throws {
        let manager = manager(try fakeCLI(exit: 0, final: "complete"))
        manager.enqueue(game: game, choice: choice)
        try await waitUntil(manager) { $0?.status == .complete }
        XCTAssertEqual(manager.installState(for: game.id), .installed)
        XCTAssertTrue(manager.task(game.id)!.destination.hasSuffix("Games/DREDGE"))

        // A new manager reads the install from the state file.
        let again = DownloadManager(stateFile: root.appendingPathComponent("state.json"),
                                    installRoot: root.appendingPathComponent("Games"))
        XCTAssertEqual(again.installState(for: game.id), .installed)
        XCTAssertNil(again.task(game.id), "Complete tasks are not saved")
    }

    func testExitZeroWithoutCompleteIsAFailure() async throws {
        let manager = manager(try fakeCLI(exit: 0, final: "downloading"))
        manager.enqueue(game: game, choice: choice)
        try await waitUntil(manager) { $0?.status == .failed }
        XCTAssertEqual(manager.installState(for: game.id), .downloading(progress: 1))
    }

    func testFailureKeepsTheStderrMessage() async throws {
        let url = root.appendingPathComponent("fail-cli")
        try "#!/bin/sh\necho 'License check failed.' >&2\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let manager = manager(XodusCLI(url: url))
        manager.enqueue(game: game, choice: choice)
        try await waitUntil(manager) { $0?.status == .failed }
        XCTAssertEqual(manager.task(game.id)?.error, "License check failed.")
    }

    func testStopKeepsTaskAndRestartAfterReload() async throws {
        let url = root.appendingPathComponent("slow-cli")
        try "#!/bin/sh\ntrap 'exit 130' INT\nwhile true; do sleep 0.1; done\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let manager = manager(XodusCLI(url: url))
        manager.enqueue(game: game, choice: choice)
        try await waitUntil(manager) { $0?.status == .running }
        try await Task.sleep(for: .milliseconds(200))
        manager.stopOrRemove(game.id)
        try await waitUntil(manager) { $0?.status == .stopped }

        let again = DownloadManager(stateFile: root.appendingPathComponent("state.json"),
                                    installRoot: root.appendingPathComponent("Games"))
        XCTAssertEqual(again.task(game.id)?.status, .stopped)
        again.stopOrRemove(game.id)
        XCTAssertNil(again.task(game.id), "X on a stopped task removes it from the list")
    }
}
