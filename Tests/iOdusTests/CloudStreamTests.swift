import JavaScriptCore
import XCTest
@testable import iOdus

final class CloudStreamURLTests: XCTestCase {
    func testLaunchURL() {
        XCTAssertEqual(CloudStream.launchURL(productId: "9nwz9jd5bh8n", title: "DREDGE: Deluxe Edition").absoluteString,
                       "https://www.xbox.com/en-US/play/launch/dredge-deluxe-edition/9NWZ9JD5BH8N")
        XCTAssertEqual(CloudStream.launchURL(productId: "9P8LR42PTRGJ", title: "Pokémon™ Café", locale: "de-DE").absoluteString,
                       "https://www.xbox.com/de-DE/play/launch/pokemon-cafe/9P8LR42PTRGJ")
        XCTAssertEqual(CloudStream.launchURL(productId: "9P8LR42PTRGJ", title: "日本").absoluteString,
                       "https://www.xbox.com/en-US/play/launch/9P8LR42PTRGJ", "No ASCII name: the short route")
        XCTAssertEqual(CloudStream.launchURL(productId: "../9P8L?x", title: "A").path,
                       "/en-US/play/launch/a/9P8LX", "Only letters and digits in the ID")
    }

    func testLocale() {
        XCTAssertEqual(CloudStream.locale(from: "en_US"), "en-US")
        XCTAssertEqual(CloudStream.locale(from: "fr_CA@calendar=gregorian"), "fr-CA")
        XCTAssertEqual(CloudStream.locale(from: "en"), "en-US")
    }

    func testCloudListParse() throws {
        let json = #"[{"siglId":"x","title":"All games"},{"id":"9npdn9r45jx4"},{"id":"9P8LR42PTRGJ"}]"#
        XCTAssertEqual(try StoreCatalog.cloudIDs(from: Data(json.utf8)), ["9NPDN9R45JX4", "9P8LR42PTRGJ"])
        XCTAssertThrowsError(try StoreCatalog.cloudIDs(from: Data("{}".utf8)))
    }

    /// Forza Horizon 6 (9NR1R1XWLCNB) is not in the cloud list; its editions are.
    func testCloudEditionOfAGame() throws {
        let suggest = Data("""
        {"Results":[{"ProductFamilyName":"Games","Products":[
          {"ProductId":"9N431PX143P8","Title":"Forza Horizon 6 Standard Edition"},
          {"ProductId":"9NR1R1XWLCNB","Title":"Forza Horizon 6"},
          {"ProductId":"9N03HPMVD65G","Title":"Forza Horizon 6 Deluxe Edition"}]}]}
        """.utf8)
        XCTAssertEqual(StoreCatalog.suggestedIDs(from: suggest), ["9N431PX143P8", "9NR1R1XWLCNB", "9N03HPMVD65G"])
        let products = Data("""
        {"Products":[
          {"ProductId":"9N03HPMVD65G","DisplaySkuAvailabilities":[{"Sku":{"Properties":{"BundledSkus":[
            {"BigId":"9NR1R1XWLCNB"},{"BigId":"9NTBFBZMB84T"},{"BigId":"9MSTD1ZC25D7"}]}}}]},
          {"ProductId":"9N431PX143P8","DisplaySkuAvailabilities":[{"Sku":{"Properties":{"BundledSkus":[
            {"BigId":"9NR1R1XWLCNB"}]}}}]},
          {"ProductId":"9OTHERGAME01","DisplaySkuAvailabilities":[{"Sku":{"Properties":{}}}]}]}
        """.utf8)
        XCTAssertEqual(StoreCatalog.edition(containing: "9nr1r1xwlcnb", in: products), "9N431PX143P8",
                       "The smallest edition that contains the game")
        XCTAssertNil(StoreCatalog.edition(containing: "9MSVVM5NS9L6", in: products))
        XCTAssertEqual(StoreCatalog.searchTitle("Forza Horizon™ 6"), "Forza Horizon 6")
    }

    func testPageScriptCompiles() throws {
        let context = try XCTUnwrap(JSContext())
        var error: String?
        context.exceptionHandler = { _, value in error = value?.toString() }
        // Compile only: the script needs a page to run.
        context.evaluateScript("new Function(\(try jsonString(StreamPage.script())));")
        XCTAssertNil(error)
        XCTAssertTrue(StreamPage.script().contains("\"playTexts\":[\"play\""), "The selectors are in the script")
    }

    private func jsonString(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode([text]), as: UTF8.self).dropFirst().dropLast().description
    }
}

final class StreamSessionTests: XCTestCase {
    private func session() -> StreamSession {
        StreamSession(gameID: "G", title: "Harbor Lights", url: URL(string: "https://www.xbox.com/en-US/play/launch/g/G")!)
    }

    func testNormalStart() {
        var s = session()
        XCTAssertTrue(s.covered)
        XCTAssertEqual(s.apply(PageReport(state: "loading", path: "/en-US/play/launch/g/G")), .none)
        XCTAssertEqual(s.apply(PageReport(state: "queue", text: "Wait time is about 2 minutes")), .none)
        XCTAssertEqual(s.phase, .queue("Wait time is about 2 minutes"))
        XCTAssertTrue(s.covered)
        XCTAssertEqual(s.apply(PageReport(state: "streaming")), .none)
        XCTAssertFalse(s.covered, "The video plays: the cover goes away")
        s.timeout()
        XCTAssertEqual(s.phase, .streaming, "The timeout does nothing after the start")
        XCTAssertEqual(s.apply(PageReport(state: "ended")), .close("The stream of Harbor Lights ended."))
    }

    func testEndedBeforeAStreamDoesNotClose() {
        var s = session()
        XCTAssertEqual(s.apply(PageReport(state: "ended")), .none)
    }

    func testSignInShowsThePageAndReloadsTheStream() {
        var s = session()
        _ = s.apply(PageReport(state: "signIn", host: "login.live.com"))
        XCTAssertEqual(s.phase, .signIn)
        XCTAssertFalse(s.covered, "The sign-in page is never covered")
        s.timeout()
        XCTAssertEqual(s.phase, .signIn, "The timeout does not interrupt the sign-in")
        XCTAssertEqual(s.apply(PageReport(state: "loading", host: "www.xbox.com", path: "/en-US/play")), .reloadLaunch)
        XCTAssertEqual(s.phase, .loading)
    }

    /// "SIGN IN" opens www.xbox.com/<locale>/auth/msa first, and that page goes on
    /// to login.live.com. A report from it must not reload the stream address.
    func testXboxPagesBeforeTheMicrosoftPageDoNotReload() {
        var s = session()
        _ = s.apply(PageReport(state: "signIn", host: "www.xbox.com", path: "/en-US/play/games/g/G"))
        XCTAssertEqual(s.apply(PageReport(state: "loading", host: "www.xbox.com", path: "/en-US/auth/msa")), .none)
        XCTAssertEqual(s.phase, .signIn, "The page stays visible")
        _ = s.apply(PageReport(state: "signIn", host: "login.live.com", path: "/oauth20_authorize.srf"))
        XCTAssertEqual(s.apply(PageReport(state: "loading", host: "www.xbox.com", path: "/en-US/play/games/g/G")), .reloadLaunch)
        XCTAssertEqual(s.phase, .loading)
        // A second sign-in needs a second visit of the Microsoft page.
        _ = s.apply(PageReport(state: "signIn", host: "www.xbox.com", path: "/en-US/play/games/g/G"))
        XCTAssertEqual(s.apply(PageReport(state: "loading", host: "www.xbox.com", path: "/en-US/auth/msa")), .none)
    }

    /// The Xbox logo video while the stream connects is not the stream.
    func testOnlyAMediaStreamVideoCountsAsTheStream() {
        XCTAssertTrue(StreamPage.script().contains("v.srcObject instanceof MediaStream"))
        XCTAssertEqual(StreamPage.Selectors().endedAfterChecks, 10)
    }

    /// The stand-in for navigator.mediaDevices: only on xbox.com, only when it is
    /// missing, no devices, and no microphone access.
    func testMediaDevicesStandIn() throws {
        func run(host: String, existing: Bool) throws -> JSContext {
            let context = try XCTUnwrap(JSContext())
            var error: String?
            context.exceptionHandler = { _, value in error = value?.toString() }
            context.evaluateScript("""
            var location = { hostname: "\(host)" };
            class EventTarget { addEventListener() {} removeEventListener() {} dispatchEvent() { return true } }
            class DOMException extends Error { constructor(m, n) { super(m); this.name = n; } }
            function Navigator() {}
            var navigator = new Navigator();
            \(existing ? "navigator.mediaDevices = { mine: true };" : "")
            """)
            context.evaluateScript(StreamPage.mediaDevicesScript)
            XCTAssertNil(error)
            return context
        }
        let xbox = try run(host: "www.xbox.com", existing: false)
        XCTAssertEqual(xbox.evaluateScript("typeof navigator.mediaDevices.enumerateDevices")?.toString(), "function")
        XCTAssertEqual(try run(host: "login.live.com", existing: false)
            .evaluateScript("typeof navigator.mediaDevices")?.toString(), "undefined")
        XCTAssertEqual(try run(host: "www.xbox.com", existing: true)
            .evaluateScript("navigator.mediaDevices.mine")?.toBool(), true)
        XCTAssertEqual(try run(host: "evilxbox.com", existing: false)
            .evaluateScript("typeof navigator.mediaDevices")?.toString(), "undefined")
    }

    func testPageScriptTreatsAuthPagesAsSignIn() {
        XCTAssertTrue(StreamPage.script().contains("\"authPaths\":[\"\\/auth\\/\"]") || StreamPage.script().contains("\"authPaths\":[\"/auth/\"]"))
    }

    func testTimeoutShowsThePage() {
        var s = session()
        s.timeout()
        XCTAssertEqual(s.phase, .pageShown)
        XCTAssertFalse(s.covered)
        _ = s.apply(PageReport(state: "queue", text: "x"))
        XCTAssertEqual(s.phase, .pageShown, "The page shows its own queue then")
    }

    func testErrorOpensTheMenu() {
        var s = session()
        _ = s.apply(PageReport(state: "error", text: "This game is not available in your region."))
        XCTAssertEqual(s.phase, .failed("This game is not available in your region."))
        XCTAssertTrue(s.menuOpen)
        XCTAssertEqual(s.menuItems, [.showPage, .stop])
        s.moveMenu(.down)
        XCTAssertTrue(s.chooseMenu(), "Stop")
    }

    func testMenu() {
        var s = session()
        s.openMenu()
        XCTAssertEqual(s.menuItems, [.resume, .showPage, .stop])
        XCTAssertEqual(s.menuTitle(.resume), "Keep waiting")
        s.moveMenu(.down)
        XCTAssertFalse(s.chooseMenu())
        XCTAssertEqual(s.phase, .pageShown, "Show the page")
        XCTAssertFalse(s.menuOpen)
        s.openMenu()
        s.moveMenu(.down); s.moveMenu(.down); s.moveMenu(.down)
        XCTAssertEqual(s.menuIndex, 1, "Two items when the page shows")
        XCTAssertTrue(s.chooseMenu())
    }
}

final class StreamInputGateTests: XCTestCase {
    func testRoutes() {
        let url = URL(string: "https://www.xbox.com")!
        XCTAssertEqual(StreamInputGate.route(.other, session: nil), .app)
        XCTAssertEqual(StreamInputGate.route(.holdB, session: nil), .app)
        var s = StreamSession(gameID: "G", title: "T", url: url)
        XCTAssertEqual(StreamInputGate.route(.other, session: s), .web)
        XCTAssertEqual(StreamInputGate.route(.holdB, session: s), .openMenu)
        XCTAssertEqual(StreamInputGate.route(.guide, session: s), .openMenu)
        XCTAssertEqual(StreamInputGate.route(.shiftEscape, session: s), .openMenu)
        s.openMenu()
        XCTAssertEqual(StreamInputGate.route(.other, session: s), .app, "The menu has the input")
    }
}

@MainActor
final class StreamModelTests: XCTestCase {
    func testStreamButtonAndInputPause() {
        let model = AppModel()
        model.startDemo()
        let cloud = model.games[0], local = model.games[2]
        // An installed game has Game settings (with Show in Finder and Uninstall); another game has Manage.
        let rest: (Game) -> [DetailAction] = { $0.installState == .installed ? [.achievements, .gameSettings] : [.manage, .achievements] }
        XCTAssertEqual(model.detailActions(for: cloud), [.primary, .stream] + rest(cloud))
        XCTAssertEqual(model.detailActions(for: local), [.primary] + rest(local))

        model.stack = [.home, .detail(cloud.id)]
        model.move(.right)
        XCTAssertEqual(model.detailIndex, 1)
        model.confirm()
        XCTAssertNotNil(model.stream, "A on Stream opens the stream screen")

        // The stream has the input: iOdus does not move, go back, or type.
        model.move(.right)
        model.back()
        model.xPressed()
        model.type("a")
        XCTAssertEqual(model.detailIndex, 1)
        XCTAssertEqual(model.stack, [.home, .detail(cloud.id)])
        XCTAssertNotNil(model.stream)

        // The Xbox button opens the menu; then the input goes to the menu.
        model.home()
        XCTAssertEqual(model.stream?.menuOpen, true)
        XCTAssertEqual(model.stack, [.home, .detail(cloud.id)], "Home does not leave the game page")
        model.move(.down); model.move(.down)
        model.confirm()
        XCTAssertNil(model.stream, "Stop streaming")
        model.move(.left)
        XCTAssertEqual(model.detailIndex, 0, "The input is back with iOdus")
    }
}
