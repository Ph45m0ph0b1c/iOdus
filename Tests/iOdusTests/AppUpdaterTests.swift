import XCTest
@testable import iOdus

final class ReleaseAssetTests: XCTestCase {
    private let json = #"""
    {"tag_name":"v0.1.2","html_url":"https://github.com/o/r/releases/tag/v0.1.2","draft":false,"prerelease":false,
     "assets":[
      {"name":"iOdus-0.1.2.dmg","browser_download_url":"https://example.invalid/iOdus-0.1.2.dmg","size":10,"digest":null},
      {"name":"iOdus-0.1.2.zip","browser_download_url":"https://example.invalid/iOdus-0.1.2.zip","size":20,
       "digest":"sha256:40FA2C746CADEF396597624F449651D3154471D240C0B8B7F7835B3155833A37"}]}
    """#

    func testTheAppArchiveAndItsChecksum() throws {
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        let zip = try XCTUnwrap(release.appArchive)
        XCTAssertEqual(zip.name, "iOdus-0.1.2.zip")
        XCTAssertEqual(zip.size, 20)
        XCTAssertEqual(zip.sha256, "40fa2c746cadef396597624f449651d3154471d240c0b8b7f7835b3155833a37")
        XCTAssertNil(release.assets[0].sha256, "No digest")
    }

    func testBadDigestsGiveNoChecksum() {
        let short = ReleaseAsset(name: "a", url: "u", size: 1, digest: "sha256:abc")
        let other = ReleaseAsset(name: "a", url: "u", size: 1, digest: "sha512:" + String(repeating: "a", count: 64))
        XCTAssertNil(short.sha256)
        XCTAssertNil(other.sha256)
    }

    func testAReleaseWithoutAssetsHasNoArchive() throws {
        let release = ReleaseInfo(tagName: "v1.0.0", htmlURL: "h", draft: false, prerelease: false)
        XCTAssertNil(release.appArchive)
    }
}

final class AppUpdaterTests: XCTestCase {
    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBlockReasons() {
        XCTAssertNotNil(AppUpdater.blockReason(playing: true, downloading: false))
        XCTAssertNotNil(AppUpdater.blockReason(playing: false, downloading: true))
        XCTAssertNil(AppUpdater.blockReason(playing: false, downloading: false))
    }

    func testATranslocatedAppCannotUpdate() {
        let app = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/iOdus.app")
        XCTAssertThrowsError(try AppUpdater.checkReplaceable(app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .translocated)
        }
    }

    func testAReadOnlyFolderCannotUpdate() throws {
        let folder = try tempFolder()
        let app = folder.appendingPathComponent("iOdus.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        XCTAssertThrowsError(try AppUpdater.checkReplaceable(app)) { error in
            XCTAssertEqual(error as? AppUpdateError, .notWritable(folder.path))
        }
    }

    func testInstallReplacesTheBundleInPlace() throws {
        let folder = try tempFolder()
        let current = folder.appendingPathComponent("iOdus.app")
        let new = folder.appendingPathComponent("download/iOdus.app")
        for (app, text) in [(current, "old"), (new, "new")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: app.appendingPathComponent("Contents/marker"))
        }
        try AppUpdater.install(new, replacing: current)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".iOdus-update") }
        XCTAssertEqual(left, [], "No staged copy stays")
    }

    func testChecksumMismatchStopsBeforeUnpack() throws {
        let folder = try tempFolder()
        let zip = folder.appendingPathComponent("iOdus-9.9.9.zip")
        try Data("not the release".utf8).write(to: zip)
        let asset = ReleaseAsset(name: zip.lastPathComponent, url: "u", size: 15,
                                 digest: "sha256:" + String(repeating: "0", count: 64))
        XCTAssertThrowsError(try AppUpdater.prepare(zip: zip, asset: asset, version: "9.9.9", team: "ABCDE12345",
                                                    into: folder)) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksum)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unpacked").path))

        let none = ReleaseAsset(name: zip.lastPathComponent, url: "u", size: 15, digest: nil)
        XCTAssertThrowsError(try AppUpdater.prepare(zip: zip, asset: none, version: "9.9.9", team: "ABCDE12345",
                                                    into: folder), "No checksum, no install")
    }

    func testSha256() throws {
        let file = try tempFolder().appendingPathComponent("f")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try AppUpdater.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAnAppOfAnotherSignerIsRefused() throws {
        // An Apple app is validly signed, but not with the iOdus identifier and team.
        // The check only reads the app, so it can stay where it is.
        let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: app.path))
        XCTAssertThrowsError(try AppUpdater.verify(app: app, version: "1.0", team: "3YULF6FJ6W")) { error in
            XCTAssertEqual(error as? AppUpdateError, .wrongSigner)
        }
    }

    func testAnUnsignedAppIsRefused() throws {
        let app = try tempFolder().appendingPathComponent("iOdus.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: app.appendingPathComponent("Contents/MacOS/iOdus"))
        XCTAssertThrowsError(try AppUpdater.verify(app: app, version: "1.0", team: "3YULF6FJ6W")) { error in
            XCTAssertEqual(error as? AppUpdateError, .notSigned)
        }
    }

    func testTheRequirementRefusesOddTeamText() {
        XCTAssertNotNil(AppUpdater.requirement(team: "3YULF6FJ6W"))
        XCTAssertNil(AppUpdater.requirement(team: "X\" or anchor apple"))
        XCTAssertNil(AppUpdater.requirement(team: ""))
    }
}
