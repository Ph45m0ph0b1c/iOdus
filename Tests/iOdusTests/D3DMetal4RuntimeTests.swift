import XCTest
@testable import iOdus

final class D3DMetal4RuntimeTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-d3dm4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A minimal runtime package folder: runtime.json, an executable Wine, the lib folders.
    private func makeBaseRuntime(in folder: URL, id: String) throws {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(id)
        for dir in ["bin", "lib/wine/x86_64-windows", "lib/wine/x86_64-unix"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("bin/wine"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("bin/wine").path)
        let manifest = RuntimeManifest(id: id, name: "CrossOver 26.3 Wine", wineVersion: "11.0", wine: "bin/wine",
                                       wineserver: "bin/wineserver", libraries: "lib", components: [], overrides: [:],
                                       register: nil, propertySet: nil,
                                       environment: ["CX_APPLEGPTK_LIBD3DSHARED_PATH": "{root}/lib/external/libd3dshared.dylib"],
                                       release: 4, d3dmetal: nil, inputGate: true)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("runtime.json"))
    }

    func testTheBetaRuntimeIsAVariantOfTheWinePackage() {
        let beta = RuntimeDownload.crossoverD3DMetal4
        XCTAssertEqual(beta.id, "crossover-26.3-d3dm4")
        XCTAssertEqual(beta.baseID, RuntimeDownload.crossover.id)
        XCTAssertEqual(beta.url, RuntimeDownload.crossover.url, "The same Wine package")
        XCTAssertEqual(beta.minimumMacOS, 27)
        XCTAssertTrue(beta.isBeta)
        XCTAssertTrue(beta.name.contains("beta"))
        XCTAssertEqual(GameCompat.requiredRuntime(for: "9nr1r1xwlcnb"), beta.id)
        XCTAssertNil(GameCompat.requiredRuntime(for: "9PJGM0T0827V"), "DIRT 5 has no required runtime")
    }

    func testInstallMakesTheD3DMetal4Runtime() throws {
        // Apple's signed redist folder from Game Porting Toolkit 4, if this Mac has a copy.
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/iodus-runtimes/gptk-4.0b3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.appendingPathComponent("redist").path),
                          "No GPTK 4 redist folder on this Mac")
        let work = try tempFolder()
        try makeBaseRuntime(in: work.appendingPathComponent("base"), id: "crossover-26.3")
        let archive = work.appendingPathComponent("runtime.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", archive.path, "-C", work.appendingPathComponent("base").path, "crossover-26.3"])
        let package = work.appendingPathComponent("pkg/d3dmetal-4.0b3")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try RuntimeSetup.run("/usr/bin/ditto", [source.appendingPathComponent("redist").path, package.appendingPathComponent("redist").path])
        try Data("Apple license".utf8).write(to: package.appendingPathComponent("License.rtf"))
        let d3dmetalArchive = work.appendingPathComponent("d3dmetal.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", d3dmetalArchive.path, "-C", work.appendingPathComponent("pkg").path, "d3dmetal-4.0b3"])
        let shim = work.appendingPathComponent("shim.dll")
        try Data("LAYER".utf8).write(to: shim)

        let runtimes = work.appendingPathComponent("Runtimes")
        try RuntimeInstaller.install(archive: archive, download: RuntimeDownload.crossoverD3DMetal4, runtimes: runtimes,
                                     d3dmetalArchive: d3dmetalArchive, shim: shim)

        let root = runtimes.appendingPathComponent("crossover-26.3-d3dm4")
        let pe = root.appendingPathComponent("lib/wine/x86_64-windows")
        XCTAssertEqual(try String(contentsOf: pe.appendingPathComponent("d3d12.dll"), encoding: .utf8), "LAYER")
        XCTAssertEqual(try Data(contentsOf: pe.appendingPathComponent("d3d12_d3dmetal.dll")),
                       try Data(contentsOf: source.appendingPathComponent("redist/lib/wine/x86_64-windows/d3d12.dll")),
                       "Apple's d3d12.dll is only renamed")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: root.appendingPathComponent("lib/wine/x86_64-unix/d3d12_d3dmetal.so").path), "../../external/libd3dshared.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/external/D3DMetal.framework").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("LICENSES/D3DMetal/License.rtf").path))
        let manifest = try JSONDecoder().decode(RuntimeManifest.self, from: Data(contentsOf: root.appendingPathComponent("runtime.json")))
        XCTAssertEqual(manifest.id, "crossover-26.3-d3dm4")
        XCTAssertEqual(manifest.environment?["D3DM_MTL4"], "0")
        XCTAssertEqual(manifest.environment?["WINE_BUILTIN_BY_FILE_NAME"], "d3d12_d3dmetal.dll")
        XCTAssertEqual(manifest.environment?["CX_APPLEGPTK_LIBD3DSHARED_PATH"], "{root}/lib/external/libd3dshared.dylib")
        XCTAssertTrue(manifest.d3dmetal?.windows.contains("d3d12core.dll") ?? false)
        XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: runtimes.path).first { $0.hasPrefix(".install") },
                     "No staging folder stays")
    }

    func testAPackageWithoutApplesSignatureIsRefused() throws {
        let work = try tempFolder()
        try makeBaseRuntime(in: work.appendingPathComponent("base"), id: "crossover-26.3")
        let archive = work.appendingPathComponent("runtime.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", archive.path, "-C", work.appendingPathComponent("base").path, "crossover-26.3"])
        let framework = work.appendingPathComponent("pkg/d3dmetal-4.0b3/redist/lib/external/D3DMetal.framework")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let d3dmetalArchive = work.appendingPathComponent("d3dmetal.tar")
        try RuntimeSetup.run("/usr/bin/tar", ["-cf", d3dmetalArchive.path, "-C", work.appendingPathComponent("pkg").path, "d3dmetal-4.0b3"])
        let shim = work.appendingPathComponent("shim.dll")
        try Data("LAYER".utf8).write(to: shim)
        let runtimes = work.appendingPathComponent("Runtimes")
        XCTAssertThrowsError(try RuntimeInstaller.install(archive: archive, download: RuntimeDownload.crossoverD3DMetal4,
                                                          runtimes: runtimes, d3dmetalArchive: d3dmetalArchive, shim: shim))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimes.appendingPathComponent("crossover-26.3-d3dm4").path))
    }
}
