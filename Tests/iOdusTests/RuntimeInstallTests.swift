import XCTest
@testable import iOdus

/// A sample runtime package and a sample GPTK, in temporary folders only.
final class RuntimeInstallTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("rtinstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private let fm = FileManager.default

    private func download(_ id: String = "crossover-26.3") -> RuntimeDownload {
        RuntimeDownload(id: id, name: "CrossOver 26.3 Wine", wineVersion: "11.0", release: 1,
                        url: URL(fileURLWithPath: "/dev/null"), sha256: "", size: 1, unpackedBytes: 1)
    }

    /// A package folder <id>/ with runtime.json, bin/wine, and Wine's own d3d12.dll.
    private func makePackage(id: String = "crossover-26.3", windows: [String] = ["d3d12.dll"]) throws -> URL {
        let root = temp.appendingPathComponent("pkg/\(id)")
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: root.appendingPathComponent("bin/wine"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/wine").path)
        try Data("wine d3d12".utf8).write(to: root.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll"))
        let list = windows.map { "\"\($0)\"" }.joined(separator: ",")
        try """
        {"id":"\(id)","name":"CrossOver 26.3 Wine","wineVersion":"11.0","release":1,"wine":"bin/wine",
         "wineserver":"bin/wineserver","components":["xgameruntime.dll"],"overrides":{},
         "d3dmetal":{"windows":[\(list)],"unix":["d3d12.so"]}}
        """.write(to: root.appendingPathComponent("runtime.json"), atomically: true, encoding: .utf8)
        let archive = temp.appendingPathComponent("pkg.tar.xz")
        try RuntimeSetup.run("/usr/bin/tar", ["-cJf", archive.path, "-C", temp.appendingPathComponent("pkg").path, id])
        return archive
    }

    /// A GPTK wine folder with D3DMetal in the GPTK layout.
    private func makeGPTK() throws -> URL {
        let wine = temp.appendingPathComponent("gptk/wine")
        let framework = wine.appendingPathComponent("lib/external/D3DMetal.framework")
        try fm.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("apple".utf8).write(to: framework.appendingPathComponent("D3DMetal"))
        try Data("shared".utf8).write(to: wine.appendingPathComponent("lib/external/libd3dshared.dylib"))
        try fm.createDirectory(at: wine.appendingPathComponent("lib/wine/x86_64-windows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: wine.appendingPathComponent("lib/wine/x86_64-unix"), withIntermediateDirectories: true)
        try Data("metal d3d12".utf8).write(to: wine.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll"))
        try fm.createSymbolicLink(atPath: wine.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so").path,
                                  withDestinationPath: "../../external/libd3dshared.dylib")
        return wine
    }

    func testInstallAddsD3DMetalFromGPTK() throws {
        let archive = try makePackage()
        let gptk = try makeGPTK()
        let runtimes = temp.appendingPathComponent("Runtimes")
        try RuntimeInstaller.install(archive: archive, download: download(), runtimes: runtimes, gptkWine: gptk)
        let root = runtimes.appendingPathComponent("crossover-26.3")
        XCTAssertTrue(fm.isExecutableFile(atPath: root.appendingPathComponent("bin/wine").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll"), encoding: .utf8),
                       "metal d3d12", "The D3DMetal DLL replaces Wine's own")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so").path),
                       "../../external/libd3dshared.dylib", "The .so stays a link, as in GPTK")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("lib/external/D3DMetal.framework/D3DMetal").path))
        XCTAssertEqual((try fm.contentsOfDirectory(atPath: runtimes.path)).filter { $0.hasPrefix(".") }, [], "No staging folder stays")
        // A second install (an update) replaces the folder.
        try RuntimeInstaller.install(archive: archive, download: download(), runtimes: runtimes, gptkWine: gptk)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: runtimes.path), ["crossover-26.3"])
    }

    func testRefusals() throws {
        let gptk = try makeGPTK()
        let runtimes = temp.appendingPathComponent("Runtimes")
        let other = try makePackage(id: "other-runtime")
        XCTAssertThrowsError(try RuntimeInstaller.install(archive: other, download: download(), runtimes: runtimes, gptkWine: gptk)) {
            XCTAssertTrue(($0 as? RuntimeInstallError).map { if case .badPackage = $0 { return true }; return false } ?? false)
        }
        let archive = try makePackage()
        XCTAssertThrowsError(try RuntimeInstaller.install(archive: archive, download: download(), runtimes: runtimes,
                                                          gptkWine: temp.appendingPathComponent("no-gptk"))) {
            XCTAssertEqual($0 as? RuntimeInstallError, .noGPTK)
        }
        XCTAssertFalse(fm.fileExists(atPath: runtimes.appendingPathComponent("crossover-26.3").path), "Nothing is installed after a refusal")
        XCTAssertFalse(RuntimeInstaller.isPlainName("../evil.dll"))
        XCTAssertFalse(RuntimeInstaller.isPlainName("a/b.dll"))
        XCTAssertTrue(RuntimeInstaller.isPlainName("d3d12.dll"))
    }
}
