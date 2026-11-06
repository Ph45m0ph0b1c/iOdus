import XCTest
@testable import iOdus

final class GameStubTests: XCTestCase {
    private let steep = """
        <Game configVersion="1">
          <Identity Name="Ubisoft.PCSteep" Publisher="CN=C3139357" Version="1.0.0.0" />
          <ExecutableList>
            <Executable Name="GDKStubGame.exe" TargetDeviceFamily="PC" />
          </ExecutableList>
          <ShellVisuals DefaultDisplayName="Steep" PublisherDisplayName="Ubisoft" />
        </Game>
        """

    func testAStarterPackageIsAStub() throws {
        let stub = try XCTUnwrap(GameStub.parse(config: steep))
        XCTAssertEqual(stub.publisher, "Ubisoft")
        XCTAssertEqual(stub.launcher, "Ubisoft Connect")
        XCTAssertTrue(stub.note(for: "Steep").contains("only a starter for Ubisoft Connect"))
    }

    func testARealGameIsNotAStub() {
        let dredge = """
            <Game><ExecutableList><Executable Name="DREDGE.exe" /></ExecutableList>
            <ShellVisuals PublisherDisplayName="Team17" /></Game>
            """
        XCTAssertNil(GameStub.parse(config: dredge))
        let mixed = """
            <Game><ExecutableList><Executable Name="GDKStubGame.exe" /><Executable Name="Game.exe" /></ExecutableList></Game>
            """
        XCTAssertNil(GameStub.parse(config: mixed), "A package with a real executable is not a stub")
        XCTAssertNil(GameStub.parse(config: "<Game></Game>"))
    }

    func testLauncherNames() {
        XCTAssertEqual(GameStub(publisher: "Electronic Arts").launcher, "the EA app")
        XCTAssertEqual(GameStub(publisher: "Activision").launcher, "Battle.net")
        XCTAssertEqual(GameStub(publisher: "Contoso").launcher, "Contoso's launcher")
        XCTAssertEqual(GameStub(publisher: "").launcher, "the publisher's launcher")
    }

    func testTheRealSteepPackageIsDetected() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/iOdus/STEEP")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path), "STEEP is not installed")
        XCTAssertEqual(GameStub.detect(in: folder)?.launcher, "Ubisoft Connect")
    }
}

@MainActor
final class SignInAgainTests: XCTestCase {
    func testOnlySignInFailuresAskForANewSignIn() {
        XCTAssertTrue(AppModel.isSignInFailure(
            "Account library unavailable (ticket-interaction-required); credentials and installed games are unchanged."))
        XCTAssertTrue(AppModel.isSignInFailure("Account library unavailable (ticket-refused); credentials and installed games are unchanged."))
        XCTAssertFalse(AppModel.isSignInFailure("Account library unavailable (ticket-network); credentials and installed games are unchanged."))
        let model = AppModel()
        model.account = .failed("Account library unavailable (ticket-interaction-required).")
        XCTAssertTrue(model.accountNeedsSignIn)
        model.account = .failed("The backend did not answer.")
        XCTAssertFalse(model.accountNeedsSignIn)
    }
}
