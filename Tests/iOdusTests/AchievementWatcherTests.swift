import XCTest
@testable import iOdus

/// The watcher only reads. These tests use a fake reader, not Xbox Live.
@MainActor
final class AchievementWatcherTests: XCTestCase {
    private func item(_ id: String, _ state: String = "locked") -> Achievement {
        Achievement(id: id, name: "A\(id)", description: "", gamerscore: 10, iconUrl: nil, state: state,
                    progress: nil, secret: false, revoked: false, unlockedAt: nil)
    }

    private func list(_ unlocked: Set<String>, title: String = "1907796436") -> AchievementList {
        AchievementList(titleId: title, partial: false,
                        items: ["1", "2", "3"].map { item($0, unlocked.contains($0) ? "unlocked" : "locked") })
    }

    func testNoBaselineMeansNothingNew() {
        XCTAssertTrue(AchievementWatcher.newUnlocks(known: nil, list: list(["1"])).isEmpty)
        XCTAssertEqual(AchievementWatcher.newUnlocks(known: ["1"], list: list(["1", "2"])).map(\.id), ["2"])
    }

    func testEachUnlockIsAnnouncedOneTime() async {
        var answers = [list(["1"]), list(["1", "2"]), list(["1", "2"]), list(["1", "2", "3"])]
        var got: [[String]] = []
        let watcher = AchievementWatcher(titleId: "1907796436",
                                         read: { answers.removeFirst() },
                                         stamp: { 0 },
                                         onUnlock: { got.append($0.map(\.id)) })
        let counts = [await watcher.check(), await watcher.check(), await watcher.check(), await watcher.check()]
        XCTAssertEqual(counts, [0, 1, 0, 1])           // The first read is the baseline.
        XCTAssertEqual(got, [["2"], ["3"]])
        XCTAssertEqual(watcher.announced, ["2", "3"])
    }

    func testFailedReadsAndOtherTitlesAreIgnored() async {
        struct Failure: Error {}
        var step = 0
        var got: [String] = []
        let watcher = AchievementWatcher(titleId: "1907796436", read: {
            step += 1
            switch step {
            case 1: throw Failure()
            case 2: return self.list(["1"])
            case 3: return self.list(["1", "2", "3"], title: "123")
            default: return self.list(["1", "2"])
            }
        }, stamp: { 0 }, onUnlock: { got += $0.map(\.id) })
        for _ in 0..<4 { await watcher.check() }
        // Read 1 failed, so read 2 is the baseline. Read 3 is for a different title.
        XCTAssertEqual(got, ["2"])
    }

    func testSignalStartsAReadAndStopReadsAgain() async throws {
        var stamp: Int64 = 0
        var reads = 0
        var unlocked: Set<String> = ["1"]
        var got: [String] = []
        let watcher = AchievementWatcher(titleId: "1907796436", read: {
            reads += 1
            return self.list(unlocked)
        }, stamp: { stamp }, onUnlock: { got += $0.map(\.id) })
        watcher.start(poll: .milliseconds(20), retries: [.milliseconds(20)], fallback: 3600)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 1)                       // Only the baseline; no signal yet.
        unlocked.insert("2")
        stamp = 120                                    // The proxy wrote a line.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(got, ["2"])
        unlocked.insert("3")
        await watcher.stop()                           // The last read finds the rest.
        XCTAssertEqual(got, ["2", "3"])
    }

    func testSignalStampSumsTheFiles() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        XCTAssertEqual(AchievementSignal.stamp(prefix: prefix), 0)
        let folder = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local/iOdus")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let line = Data("1\thttps://achievements.xboxlive.com/x/update\n".utf8)
        try line.write(to: folder.appendingPathComponent("achievement-signal"))
        XCTAssertEqual(AchievementSignal.stamp(prefix: prefix), Int64(line.count))
    }
}
