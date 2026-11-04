import XCTest
@testable import iOdus

/// Prints the real save state of three games. Runs only with IODUS_LIVE=1.
final class CloudSaveLiveTests: XCTestCase {
    func testPrintRealStatus() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IODUS_LIVE"] == "1")
        for (name, id) in [("Shelldiver", "2129637901"), ("DREDGE", "1907796436"), ("Well Dweller", "1682153445")] {
            print("LIVE \(name): \(CloudSaveStatus.read(titleId: id, prefix: GameRuntime.standard.prefix))")
        }
    }
}
