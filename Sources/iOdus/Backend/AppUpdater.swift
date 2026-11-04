import CryptoKit
import Foundation
import Security

enum AppUpdateError: LocalizedError, Equatable {
    case noArchive
    case download(String)
    case checksum
    case unpack
    case notSigned
    case wrongSigner
    case notNotarized
    case wrongVersion(String)
    case translocated
    case notWritable(String)
    case noTeam

    var errorDescription: String? {
        switch self {
        case .noArchive: "The release has no app file (iOdus-<version>.zip)."
        case .download(let text): "The download failed: \(text)"
        case .checksum: "The downloaded file does not match the checksum of the release."
        case .unpack: "iOdus could not unpack the downloaded file."
        case .notSigned: "The downloaded app has no valid signature."
        case .wrongSigner: "The downloaded app is not signed by the iOdus developer."
        case .notNotarized: "Apple did not notarize the downloaded app."
        case .wrongVersion(let version): "The downloaded app has a different version (\(version))."
        case .translocated:
            "macOS runs iOdus from a temporary location. Move iOdus to Applications, open it again, and update."
        case .notWritable(let folder): "iOdus cannot write to \(folder). Install the update from the release page."
        case .noTeam: "This build of iOdus is not signed with a Developer ID, so it cannot update itself."
        }
    }
}

/// Installs a new iOdus release from GitHub in place of the running app.
///
/// The order: download the zip, check its SHA-256 against the release, unpack
/// it, check that the new app is signed with a Developer ID of the same team
/// as the running app and notarized, replace the app bundle in one step, then
/// quit and open the new version.
enum AppUpdater {
    static let bundleID = "com.burghr.iodus"

    // MARK: Checks before an update

    /// The reason that an update cannot start now, or nil.
    static func blockReason(playing: Bool, downloading: Bool) -> String? {
        if playing { return "Stop the game first. iOdus restarts for the update." }
        if downloading { return "Pause or finish the downloads first. iOdus restarts for the update." }
        return nil
    }

    /// Checks that iOdus can replace the bundle at `app`.
    static func checkReplaceable(_ app: URL) throws {
        // App Translocation: macOS runs a quarantined app from a random read-only copy.
        if app.path.contains("/AppTranslocation/") { throw AppUpdateError.translocated }
        let folder = app.deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: app.path) else {
            throw AppUpdateError.notWritable(folder.path)
        }
    }

    /// The Team ID of the running app's signature, or nil (ad-hoc or a local identity).
    static func runningTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return teamID(of: staticCode)
    }

    static func teamID(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: Download

    /// Downloads `asset` into `folder`. `progress` gets 0...1.
    static func download(_ asset: ReleaseAsset, into folder: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let url = URL(string: asset.url) else { throw AppUpdateError.noArchive }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: target)
        let delegate = ProgressDelegate(expected: asset.size, progress: progress)
        let (temp, response): (URL, URLResponse)
        do {
            (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        } catch {
            throw AppUpdateError.download(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppUpdateError.download("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let expected: Int64
        let progress: @Sendable (Double) -> Void

        init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
            self.expected = expected
            self.progress = progress
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            guard total > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(total)))
        }

        // The async download(from:delegate:) call returns the file; nothing to do here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }

    // MARK: Checks of the download

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the zip, unpacks it into `folder`, and checks the app in it.
    /// Returns the URL of the new iOdus.app.
    static func prepare(zip: URL, asset: ReleaseAsset, version: String, team: String,
                        into folder: URL) throws -> URL {
        guard let expected = asset.sha256, try sha256(of: zip) == expected else { throw AppUpdateError.checksum }
        let unpacked = folder.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else { throw AppUpdateError.unpack }
        let app = unpacked.appendingPathComponent("iOdus.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw AppUpdateError.unpack }
        try verify(app: app, version: version, team: team)
        return app
    }

    /// The new app must be valid, signed by a Developer ID Application
    /// certificate of `team` with the iOdus identifier, notarized, and of `version`.
    static func verify(app: URL, version: String, team: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw AppUpdateError.notSigned
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw AppUpdateError.notSigned }
        guard let requirement = requirement(team: team),
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw AppUpdateError.wrongSigner
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let newVersion = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        guard newVersion == version else { throw AppUpdateError.wrongVersion(newVersion) }
        // Gatekeeper: a Developer ID app must also be notarized.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw AppUpdateError.notNotarized
        }
    }

    /// The code requirement for an iOdus release: Apple's Developer ID chain
    /// (Developer ID CA and a Developer ID Application leaf), the team, and the
    /// bundle identifier.
    static func requirement(team: String) -> SecRequirement? {
        guard team.allSatisfy({ $0.isLetter || $0.isNumber }), !team.isEmpty else { return nil }
        let text = """
            identifier "\(bundleID)" and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(team)"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    // MARK: Install

    /// Replaces the bundle at `current` with `newApp`. The copy goes next to
    /// `current` first, so that the replacement is one rename on the same disk.
    static func install(_ newApp: URL, replacing current: URL) throws {
        try checkReplaceable(current)
        let stage = current.deletingLastPathComponent()
            .appendingPathComponent(".iOdus-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [newApp.path, stage.path]) == 0 else {
            try? FileManager.default.removeItem(at: stage)
            throw AppUpdateError.notWritable(current.deletingLastPathComponent().path)
        }
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: stage)
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw AppUpdateError.notWritable(current.deletingLastPathComponent().path)
        }
    }

    /// Opens `app` after this process ends. A small shell waits for this
    /// process ID, so that the new app does not start next to the old one.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                             app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
