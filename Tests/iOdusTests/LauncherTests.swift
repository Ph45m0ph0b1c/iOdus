import Darwin
import XCTest
@testable import iOdus

final class GameConfigTests: XCTestCase {
    func testPrefersTheGameExecutable() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <Game configVersion="1">
          <ExecutableList>
            <Executable Name="Tools\\Editor.exe" Id="Editor" />
            <Executable Name="DREDGE.exe" Id="Game" />
          </ExecutableList>
        </Game>
        """
        XCTAssertEqual(GameConfig.executable(fromConfig: Data(xml.utf8)), "DREDGE.exe")
    }

    func testFallsBackToTheFirstExecutable() {
        let xml = #"<Game><ExecutableList><Executable Name="bin\Game.exe" Id="Main"/></ExecutableList></Game>"#
        XCTAssertEqual(GameConfig.executable(fromConfig: Data(xml.utf8)), #"bin\Game.exe"#)
    }

    func testRefusesUnsafePaths() {
        for name in [#"..\..\evil.exe"#, "/bin/sh", #"C:\Windows\x.exe"#, ""] {
            let xml = #"<Game><Executable Name="\#(name)" Id="Game"/></Game>"#
            XCTAssertNil(GameConfig.executable(fromConfig: Data(xml.utf8)), name)
        }
        XCTAssertNil(GameConfig.executable(fromConfig: Data("<Game/>".utf8)))
    }

    func testReadsTheConfigFileInAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"<Game><Executable Name="Game.exe" Id="Game"/></Game>"#
            .write(to: folder.appendingPathComponent("MicrosoftGame.Config"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameConfig.executable(in: folder), "Game.exe")
    }
}

final class GameRuntimeTests: XCTestCase {
    func testRosettaReportsAVX() {
        let runtime = GameRuntime.gptk(root: URL(fileURLWithPath: "/tmp/r"), prefix: URL(fileURLWithPath: "/tmp/p"))
        XCTAssertEqual(runtime.environment()["ROSETTA_ADVERTISE_AVX"], "1")
        XCTAssertNil(runtime.environment(extra: [:]).keys.first { $0 == "IODUS_ROSETTA_AVX" })
    }

    func testSaveSyncHelperPaths() throws {
        XCTAssertEqual(GameRuntime.windowsPath(URL(fileURLWithPath: "/Users/a/Games/iOdus/DREDGE/MicrosoftGame.config")),
                       "Z:\\Users\\a\\Games\\iOdus\\DREDGE\\MicrosoftGame.config")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(GameConfig.configFile(in: folder))
        try Data().write(to: folder.appendingPathComponent("microsoftgame.CONFIG"))
        XCTAssertEqual(GameConfig.configFile(in: folder)?.lastPathComponent, "microsoftgame.CONFIG")
    }

    func testNamesTheMissingParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = GameRuntime.gptk(root: root, prefix: root.appendingPathComponent("Prefix"))
        XCTAssertTrue(runtime.problem?.contains("Wine is missing") == true)

        let bin = runtime.wine64.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: runtime.wine64, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.wine64.path)
        XCTAssertTrue(runtime.problem?.contains("xgameruntime.dll") == true)

        try FileManager.default.createDirectory(at: runtime.componentFolder, withIntermediateDirectories: true)
        for name in GameRuntime.components {
            try Data(name.utf8).write(to: runtime.componentFolder.appendingPathComponent(name))
        }
        XCTAssertNil(runtime.problem)
        XCTAssertFalse(runtime.isPrepared, "No marker yet")
        try FileManager.default.createDirectory(at: runtime.prefix, withIntermediateDirectories: true)
        try runtime.componentHash().write(to: runtime.marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(runtime.isPrepared)
        try Data("new build".utf8).write(to: runtime.componentFolder.appendingPathComponent("xgameruntime.dll"))
        XCTAssertFalse(runtime.isPrepared, "A new DLL build needs a new setup")
    }
}

final class XodusBridgeTests: XCTestCase {
    /// A Unix socket server that echoes one message in upper case.
    private func startEchoServer(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        listen(fd, 4)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = read(client, &buffer, buffer.count)
                if count > 0 {
                    let reply = Array(String(decoding: buffer[0..<count], as: UTF8.self).uppercased().utf8)
                    _ = write(client, reply, reply.count)
                }
                close(client)
            }
        }
        return fd
    }

    private func connectBridge(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(result, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func readAll(_ fd: Int32) -> String {
        var result = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            result += buffer[0..<count]
        }
        return String(decoding: result, as: UTF8.self)
    }

    func testForwardsAfterTheKeyAndRefusesAWrongKey() throws {
        let path = "/tmp/iodus-bridge-\(getpid()).sock"
        let server = try startEchoServer(at: path)
        defer { close(server); unlink(path) }
        let bridge = try XodusBridge(socketPath: path)
        defer { bridge.stop() }
        XCTAssertEqual(bridge.key.count, 64)
        XCTAssertGreaterThan(bridge.port, 0)

        let good = connectBridge(bridge.port)
        let message = Array((bridge.key + "hello").utf8)
        _ = write(good, message, message.count)
        XCTAssertEqual(readAll(good), "HELLO")
        close(good)

        let bad = connectBridge(bridge.port)
        let wrong = Array((String(repeating: "0", count: 64) + "hello").utf8)
        _ = write(bad, wrong, wrong.count)
        XCTAssertEqual(readAll(bad), "", "A wrong key gets no data")
        close(bad)
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(XodusBridge.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(XodusBridge.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(XodusBridge.constantTimeEqual([1, 2], [1, 2, 3]))
    }
}

final class OrphanTests: XCTestCase {
    func testFindsOnlyOrphansOfTheSameCommand() {
        let cli = URL(fileURLWithPath: "/x/xodus-cli")
        let list = Orphans.parse("""
          101     1 /x/xodus-cli streaming 9N4PT8HGCDHQ /Games/Gears of War --parallel 4
          102   500 /x/xodus-cli streaming 9N4PT8HGCDHQ /Games/Gears of War --parallel 4
          103     1 /x/xodus-cli streaming 9MSVVM5NS9L6 /Games/DREDGE
          104     1 /x/xodus-cli service
          105     1 /other/xodus-cli service
        """)
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(Orphans.find(cli: cli, arguments: ["streaming", "9N4PT8HGCDHQ"], in: list), [101],
                       "Only orphans (parent 1) of the same game")
        XCTAssertEqual(Orphans.find(cli: cli, arguments: ["service"], in: list), [104])
    }
}

final class UnityGameTests: XCTestCase {
    func testReadsAppInfoAndBuildsTheRegistryKey() {
        let game = UnityGame.parse(appInfo: "Black Salt Games\nDREDGE")
        XCTAssertEqual(game, UnityGame(company: "Black Salt Games", product: "DREDGE"))
        XCTAssertEqual(game?.registryKey, #"HKCU\Software\Black Salt Games\DREDGE"#)
        XCTAssertNil(UnityGame.parse(appInfo: "OnlyOneLine"))
        XCTAssertNil(UnityGame.parse(appInfo: "Bad\\Company\nGame"))
    }

    func testReadsTheModeFromRegQuery() {
        let output = """

        HKEY_CURRENT_USER\\Software\\Black Salt Games\\DREDGE
            Screenmanager Fullscreen mode_h3630240806    REG_DWORD    0x0

        """
        XCTAssertEqual(UnityGame.mode(fromQuery: output), 0)
        XCTAssertEqual(UnityGame.mode(fromQuery: output.replacingOccurrences(of: "0x0", with: "0x3")), 3)
        XCTAssertNil(UnityGame.mode(fromQuery: "ERROR: not found"))
    }

    func testDetectsTheRealDredgeFolder() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/iOdus/DREDGE")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(UnityGame.detect(in: folder)?.product, "DREDGE")
    }
}

@MainActor
final class GameCloseTests: XCTestCase {
    func testImageNameForTaskkill() {
        XCTAssertEqual(GameLauncher.imageName("Shelldiver.exe"), "Shelldiver.exe")
        XCTAssertEqual(GameLauncher.imageName(#"bin\x64\Game.exe"#), "Game.exe")
        XCTAssertEqual(GameLauncher.imageName("bin/Game.exe"), "Game.exe")
        XCTAssertNil(GameLauncher.imageName(""))
    }

    func testRuntimeInstallsTheWinhttpProxy() {
        XCTAssertTrue(GameRuntime.components.contains("winhttp.dll"),
                      "The winhttp proxy adds WINHTTP_OPTION_URL for the Xbox Live requests of games")
    }
}
