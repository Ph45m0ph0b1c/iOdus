import XCTest
@testable import iOdus

final class LibraryRulesTests: XCTestCase {
    private let gamePass = "CFQ7TTC0KGQ8"
    private let now = LibraryRules.parseDate("2026-11-02T12:00:00Z")!

    private func row(_ id: String, parent: String? = nil, status: String = "Active", trial: Bool = false,
                     sharing: String = "None", end: String = "9999-12-31T23:59:59.9999999Z",
                     special: Bool = false, positron: Bool? = nil) -> Entitlement {
        Entitlement(productId: id, status: status, isTrial: trial, sharingSource: sharing, endDate: end,
                    satisfiedByProductId: parent, special: special, isPositron: positron)
    }

    func testOwnedGame() {
        let access = LibraryRules.accessByProduct([row("9AAAAAAAAAAA")], now: now)
        XCTAssertEqual(access["9AAAAAAAAAAA"], .owned)
    }

    func testGamePassGameAndPlanItself() {
        let access = LibraryRules.accessByProduct([row(gamePass), row("9AAAAAAAAAAA", parent: gamePass)], now: now)
        XCTAssertEqual(access["9AAAAAAAAAAA"], .gamePass)
        XCTAssertNil(access[gamePass], "The plan is not a game")
    }

    func testInactiveTrialSharedAndExpiredAreExcluded() {
        let rows = [
            row("9AAAAAAAAAAA", status: "Revoked"),
            row("9BBBBBBBBBBB", trial: true),
            row("9CCCCCCCCCCC", sharing: "Family"),
            row("9DDDDDDDDDDD", end: "2000-01-01T00:00:00Z"),
        ]
        XCTAssertTrue(LibraryRules.accessByProduct(rows, now: now).isEmpty)
    }

    func testChildOfUnavailableParentIsExcluded() {
        let rows = [row("9AAAAAAAAAAA", status: "Revoked"), row("9BBBBBBBBBBB", parent: "9AAAAAAAAAAA")]
        XCTAssertNil(LibraryRules.accessByProduct(rows, now: now)["9BBBBBBBBBBB"])
    }

    func testSpecialNeedsExplicitPositron() {
        XCTAssertNil(LibraryRules.accessByProduct([row("9AAAAAAAAAAA", special: true)], now: now)["9AAAAAAAAAAA"])
        XCTAssertEqual(LibraryRules.accessByProduct([row("9AAAAAAAAAAA", special: true, positron: true)], now: now)["9AAAAAAAAAAA"], .owned)
    }

    func testCycleAndDuplicatesAreExcluded() {
        let cycle = [row("9AAAAAAAAAAA", parent: "9BBBBBBBBBBB"), row("9BBBBBBBBBBB", parent: "9AAAAAAAAAAA")]
        XCTAssertTrue(LibraryRules.accessByProduct(cycle, now: now).isEmpty)
        let duplicate = [row("9AAAAAAAAAAA"), row("9AAAAAAAAAAA")]
        XCTAssertTrue(LibraryRules.accessByProduct(duplicate, now: now).isEmpty)
    }

    func testDateWithSevenFractionDigits() {
        XCTAssertNotNil(LibraryRules.parseDate("9999-12-31T23:59:59.9999999Z"))
        XCTAssertNotNil(LibraryRules.parseDate("2026-11-02T12:00:00+00:00"))
        XCTAssertNil(LibraryRules.parseDate("not-a-date"))
    }
}

final class CatalogTests: XCTestCase {
    func testParseUsesSquareBoxArtAndHttps() {
        let product: [String: Any] = [
            "ProductId": "9msvvm5ns9l6", "ProductKind": "Game",
            "LocalizedProperties": [[
                "ProductTitle": "Example", "PublisherName": "Studio",
                "Images": [
                    ["ImagePurpose": "Poster", "Uri": "//store-images.s-microsoft.com/poster", "Width": 720, "Height": 1080],
                    ["ImagePurpose": "BoxArt", "Uri": "//store-images.s-microsoft.com/box", "Width": 1080, "Height": 1080],
                    ["ImagePurpose": "SuperHeroArt", "Uri": "//store-images.s-microsoft.com/hero", "Width": 1920, "Height": 1080],
                    ["ImagePurpose": "Hero", "Uri": "https://evil.example.com/x", "Width": 1920, "Height": 1080],
                ],
            ]],
        ]
        let parsed = Catalog.parse(product)
        XCTAssertEqual(parsed?.id, "9MSVVM5NS9L6")
        XCTAssertEqual(parsed?.tileArt?.absoluteString, "https://store-images.s-microsoft.com/box")
        XCTAssertEqual(parsed?.heroArt?.absoluteString, "https://store-images.s-microsoft.com/hero")
    }

    func testParseReadsBundlesAndConsoleOnlyPackages() {
        func sku(bundle: Bool, contents: [String] = [], platforms: [String] = []) -> [String: Any] {
            ["Sku": ["Properties": [
                "IsBundle": bundle,
                "BundledSkus": contents.map { ["BigId": $0] },
                "Packages": platforms.isEmpty ? [] : [["PlatformDependencies": platforms.map { ["PlatformName": $0] }]],
            ] as [String: Any]]]
        }
        func product(_ skus: [[String: Any]]) -> CatalogProduct? {
            Catalog.parse(["ProductId": "9AAAAAAAAAAA", "ProductKind": "Game", "DisplaySkuAvailabilities": skus])
        }
        let edition = product([sku(bundle: true, contents: ["9bbbbbbbbbbb"]), sku(bundle: true, contents: ["9BBBBBBBBBBB"])])
        XCTAssertEqual(edition?.bundledIds, ["9BBBBBBBBBBB"])
        XCTAssertEqual(product([sku(bundle: true, contents: ["9B"]), sku(bundle: false)])?.bundledIds, [])
        XCTAssertEqual(product([sku(bundle: false, platforms: ["Windows.Xbox"])])?.consoleOnly, true)
        XCTAssertEqual(product([sku(bundle: false, platforms: ["Windows.Xbox", "Windows.Desktop"])])?.consoleOnly, false)
        XCTAssertEqual(product([])?.consoleOnly, false)
    }

    func testParseNamesTheLauncherOfAGameWithNoStorePackage() {
        func product(_ family: String, packages: [Any], bundle: Bool = false) -> CatalogProduct? {
            Catalog.parse(["ProductId": "9AAAAAAAAAAA", "ProductKind": "Game",
                           "Properties": ["PackageFamilyName": family],
                           "DisplaySkuAvailabilities": [["Sku": ["Properties": [
                               "IsBundle": bundle, "Packages": packages] as [String: Any]]]]])
        }
        XCTAssertEqual(product("ElectronicArtsMobile.Example_abc", packages: [])?.launcher, "the EA app")
        XCTAssertEqual(product("Studio.Example_abc", packages: [])?.launcher, "the launcher of the publisher")
        XCTAssertNil(product("ElectronicArtsMobile.Example_abc", packages: [["PackageFormat": "MSIXVC"]])?.launcher)
        XCTAssertNil(product("Studio.Example_abc", packages: [], bundle: true)?.launcher)
        XCTAssertNil(Catalog.parse(["ProductId": "9AAAAAAAAAAA", "ProductKind": "Game"])?.launcher)
    }

    /// Live request to the Store. Run with IODUS_NETWORK_TESTS=1.
    func testLiveCatalog() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IODUS_NETWORK_TESTS"] == "1")
        let products = try await Catalog(session: .shared).products(ids: ["9MSVVM5NS9L6"], market: "US")
        let dredge = try XCTUnwrap(products["9MSVVM5NS9L6"])
        XCTAssertEqual(dredge.kind, "Game")
        XCTAssertEqual(dredge.title, "DREDGE")
        XCTAssertNotNil(dredge.tileArt)
        XCTAssertNotNil(dredge.heroArt)
    }
}

final class XodusCLITests: XCTestCase {
    /// Uses a shell script as a fake CLI, so that no account is necessary.
    private func fakeCLI(_ body: String) throws -> XodusCLI {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-xodus-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return XodusCLI(url: url)
    }

    func testReadsLastJSONLine() async throws {
        let cli = try fakeCLI(#"echo "log line"; echo '{"stored":true,"username":"a@b.test"}'"#)
        let status = try await cli.account()
        XCTAssertTrue(status.stored)
        XCTAssertEqual(status.username, "a@b.test")
    }

    func testFailureUsesLastStderrLine() async throws {
        let cli = try fakeCLI(#"echo "first" >&2; echo "Sign in again." >&2; exit 1"#)
        do {
            _ = try await cli.account()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Sign in again.")
        }
    }

    func testTimeoutStopsTheProcess() async throws {
        let cli = try fakeCLI("sleep 30")
        let result = try await cli.run([], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
    }
}
