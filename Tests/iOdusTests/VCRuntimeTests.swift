import XCTest
@testable import iOdus

/// No download and no Wine: only the checks.
final class VCRuntimeTests: XCTestCase {
    func testExpectedHashOnlyFromMicrosoft() {
        let good = URL(string: "https://download.visualstudio.microsoft.com/download/pr/990c720a-46ce-4dc7-87b9-c2eb615d34b9/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!
        XCTAssertEqual(VCRuntime.expectedHash(finalURL: good),
                       "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b")
        let otherHost = URL(string: "https://download.visualstudio.microsoft.com.example.net/download/pr/x/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!
        XCTAssertNil(VCRuntime.expectedHash(finalURL: otherHost))
        let http = URL(string: "http://download.visualstudio.microsoft.com/download/pr/x/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!
        XCTAssertNil(VCRuntime.expectedHash(finalURL: http))
        let noHash = URL(string: "https://download.visualstudio.microsoft.com/download/pr/x/latest/VC_redist.x64.exe")!
        XCTAssertNil(VCRuntime.expectedHash(finalURL: noHash))
        let otherFile = URL(string: "https://download.visualstudio.microsoft.com/download/pr/x/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/other.exe")!
        XCTAssertNil(VCRuntime.expectedHash(finalURL: otherFile))
    }

    func testInstalledMeansNotTheWineCopy() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: prefix) }
        XCTAssertFalse(VCRuntime.isInstalled(prefix: prefix))
        let system32 = VCRuntime.system32(prefix)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        let dll = system32.appendingPathComponent("vcruntime140.dll")
        try Data("MZ\u{0}\u{0}Wine builtin DLL\u{0}".utf8).write(to: dll)
        XCTAssertFalse(VCRuntime.isInstalled(prefix: prefix))
        try Data("MZ\u{0}\u{0}This program cannot be run in DOS mode.".utf8).write(to: dll)
        XCTAssertTrue(VCRuntime.isInstalled(prefix: prefix))
    }
}
