import XCTest
@testable import iOdus

/// The real release package, installed into a temporary folder with D3DMetal
/// from the installed GPTK. Runs only with IODUS_RUNTIME_PACKAGE=<path of the .tar.xz>.
/// No download, no game prefix.
final class RuntimePackageLiveTests: XCTestCase {
    func testRealPackageInstalls() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["IODUS_RUNTIME_PACKAGE"] else { throw XCTSkip("IODUS_RUNTIME_PACKAGE is not set") }
        let archive = URL(fileURLWithPath: path)
        let download = RuntimeDownload.crossover
        try RuntimeSetup.verify(archive, sha256: download.sha256)
        let runtimes = URL(fileURLWithPath: env["IODUS_RUNTIME_TARGET"] ?? NSTemporaryDirectory())
            .appendingPathComponent("live-runtimes-\(UUID().uuidString)")
        try RuntimeInstaller.install(archive: archive, download: download, runtimes: runtimes)
        let list = RuntimeCatalog.discover(folder: runtimes, prefixes: runtimes.appendingPathComponent("Prefixes"))
        let runtime = try XCTUnwrap(list.first { $0.id == download.id })
        XCTAssertNil(runtime.problem.flatMap { $0.contains("Wine") ? $0 : nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal").path))
        print("LIVE runtime folder: \(runtime.root.path)")
    }
}
