import CryptoKit
import Foundation

/// Microsoft's Visual C++ 2015-2022 runtime (x64) in the game prefix.
/// Wine has its own copies of these DLLs, but some are not complete
/// (concrt140, msvcp140_atomic_wait). Some games need Microsoft's DLLs.
enum VCRuntime {
    /// Microsoft's permanent link to the newest installer.
    static let downloadURL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!
    static let downloadHost = "download.visualstudio.microsoft.com"

    /// The DLLs that Wine must load from the prefix first (the list of winetricks vcrun2022).
    static let overrides = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                            "msvcp140_codecvt_ids", "vcamp140", "vcomp140", "vcruntime140", "vcruntime140_1"]

    /// Exit codes of the installer that mean success: 0, 3010 (restart needed;
    /// not for Wine), and 1638 (the same or a newer version is installed).
    static let successCodes: Set<Int32> = [0, 3010, 1638]

    static func system32(_ prefix: URL) -> URL {
        prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
    }

    /// True when system32 has Microsoft's vcruntime140.dll, not the Wine copy.
    static func isInstalled(prefix: URL) -> Bool {
        guard let data = try? Data(contentsOf: system32(prefix).appendingPathComponent("vcruntime140.dll")) else {
            return false
        }
        return !isWineBuiltin(data)
    }

    /// Wine writes "Wine builtin DLL" into the DOS stub of its own DLLs.
    static func isWineBuiltin(_ data: Data) -> Bool {
        data.prefix(4096).range(of: Data("Wine builtin DLL".utf8)) != nil
    }

    /// The SHA-256 in Microsoft's download address:
    /// https://download.visualstudio.microsoft.com/download/pr/<id>/<SHA-256>/VC_redist.x64.exe
    /// Nil for another host or form.
    static func expectedHash(finalURL: URL) -> String? {
        guard finalURL.scheme == "https", finalURL.host?.lowercased() == downloadHost,
              finalURL.lastPathComponent.lowercased() == "vc_redist.x64.exe" else { return nil }
        let parts = finalURL.pathComponents
        guard parts.count >= 3 else { return nil }
        let hash = parts[parts.count - 2]
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash.lowercased()
    }

    static func sha256(of file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }
}

extension GameRuntime {
    /// Downloads Microsoft's installer, checks it, and installs it in the prefix.
    func installVCRuntime(session: URLSession = .shared, log: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        if let problem { throw BackendError.failed(problem) }
        guard FileManager.default.fileExists(atPath: VCRuntime.system32(prefix).path) else {
            throw BackendError.failed("The game prefix does not exist yet. Start a game one time first.")
        }
        log("Downloading the installer from Microsoft")
        let (temporary, response) = try await session.download(from: VCRuntime.downloadURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let final = response.url,
              let expected = VCRuntime.expectedHash(finalURL: final) else {
            throw BackendError.failed("The download did not come from Microsoft's download server.")
        }
        guard try VCRuntime.sha256(of: temporary) == expected else {
            throw BackendError.failed("The installer does not match Microsoft's checksum.")
        }
        // Wine needs the .exe name. Use a new folder that only iOdus writes to.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-vcredist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let installer = folder.appendingPathComponent("VC_redist.x64.exe")
        try FileManager.default.copyItem(at: temporary, to: installer)

        log("Installing the Visual C++ runtime")
        let result = try await XodusCLI.runProcess(wine64, [Self.windowsPath(installer), "/install", "/quiet", "/norestart"],
                                                   environment: environment(), timeout: 600)
        if result.timedOut { throw BackendError.failed("The installer did not finish in time.") }
        guard VCRuntime.successCodes.contains(result.status) else {
            throw BackendError.failed("The installer stopped with code \(result.status).")
        }
        for name in VCRuntime.overrides {
            try await wine(["reg", "add", #"HKCU\Software\Wine\DllOverrides"#, "/v", name, "/d", "native,builtin", "/f"])
        }
        _ = try await XodusCLI.runProcess(wineserver, ["-w"], environment: environment(), timeout: 120)
        guard VCRuntime.isInstalled(prefix: prefix) else {
            throw BackendError.failed("The installer ended, but the prefix still has the Wine copies.")
        }
        log("The Visual C++ runtime is installed")
    }
}
