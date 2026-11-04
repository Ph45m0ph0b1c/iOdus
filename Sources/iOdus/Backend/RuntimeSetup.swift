import CryptoKit
import Darwin
import Foundation

/// The pinned Game Porting Toolkit build: the Gcenx binary release of Apple's
/// toolkit. iOdus downloads it from GitHub and checks the SHA-256 before it
/// extracts the archive.
struct GPTKRelease: Sendable, Equatable {
    let version: String
    let url: URL
    let sha256: String
    let size: Int64
    /// The folder in the runtime root. GameRuntime.wineBundle starts with it.
    let folder: String

    static let appName = "Game Porting Toolkit.app"

    static let pinned = GPTKRelease(
        version: "3.0-3",
        url: URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz")!,
        sha256: "d377683937340f914823dbb2e1252b329cbf834ff58907d0293db8cebf0e392e",
        size: 239_200_808,
        folder: "gptk-3.0-3")

    /// The size on disk after the extraction (about 785 MB), plus the archive.
    var neededBytes: Int64 { size + 850_000_000 }

    /// Apple's license for D3DMetal, as the Gcenx release notes link it.
    static let licenseURL = URL(string: "https://github.com/user-attachments/files/23971305/License.pdf")!
    /// Apple's page for the Game Porting Toolkit.
    static let appleURL = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
    /// The release page with the notes and the source.
    static let releaseURL = URL(string: "https://github.com/Gcenx/game-porting-toolkit/releases/tag/Game-Porting-Toolkit-3.0-3")!

    /// The app in the runtime root, for example Runtime/gptk-3.0-3/Game Porting Toolkit.app.
    func installedApp(in root: URL) -> URL {
        root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(Self.appName, isDirectory: true)
    }

    static func wine64(inApp app: URL) -> URL {
        app.appendingPathComponent("Contents/Resources/wine/bin/wine64")
    }

    func isInstalled(in root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: Self.wine64(inApp: installedApp(in: root)).path)
    }
}

/// A Game Porting Toolkit app that is already on this Mac.
struct ExistingGPTK: Equatable, Sendable {
    let app: URL
    let version: String?

    /// Only the pinned version is known to work with the iOdus runtime DLLs.
    var matches: Bool { version == GPTKRelease.pinned.version }
}

enum RuntimeSetupError: LocalizedError, Equatable {
    case checksum(expected: String, actual: String)
    case notEnoughSpace(needed: Int64, free: Int64)
    case badArchive(String)
    case alreadyInstalled(String)
    case download(String)
    case tool(String)

    var errorDescription: String? {
        switch self {
        case .checksum:
            return "The downloaded file is not the expected file (the SHA-256 is different). iOdus deleted it. Try again."
        case .notEnoughSpace(let needed, let free):
            return "There is not enough free space. The runtime needs \(Bytes.text(needed)), and \(Bytes.text(free)) is free."
        case .badArchive(let detail):
            return "The archive does not contain the Game Porting Toolkit app. \(detail)"
        case .alreadyInstalled(let path):
            return "A runtime is already in \(path). iOdus does not replace it."
        case .download(let detail):
            return "The download failed. \(detail)"
        case .tool(let detail):
            return detail
        }
    }
}

/// The steps that put the Game Porting Toolkit into the runtime root. The root
/// is a parameter, so that tests use a temporary folder.
enum RuntimeSetup {
    // MARK: SHA-256

    /// The SHA-256 of a file, read in parts, so that a large archive does not fill the memory.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ file: URL, sha256 expected: String) throws {
        let actual = try sha256(of: file)
        guard actual == expected.lowercased() else {
            throw RuntimeSetupError.checksum(expected: expected, actual: actual)
        }
    }

    // MARK: Extraction

    /// Extracts the archive into a new staging folder in `root`, checks that it
    /// contains the app with wine64, and then moves the app to its folder.
    /// An existing runtime folder is never replaced.
    static func extract(archive: URL, release: GPTKRelease, into root: URL) throws {
        let fm = FileManager.default
        let target = release.installedApp(in: root)
        if fm.fileExists(atPath: target.path) {
            throw RuntimeSetupError.alreadyInstalled(target.deletingLastPathComponent().path)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".setup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        // bsdtar refuses absolute paths and ".." entries by default.
        try run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])

        let app = staging.appendingPathComponent(GPTKRelease.appName, isDirectory: true)
        guard fm.isExecutableFile(atPath: GPTKRelease.wine64(inApp: app).path) else {
            throw RuntimeSetupError.badArchive("wine64 is missing.")
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: app, to: target)
    }

    /// Copies an existing app (for example from /Applications) into the runtime
    /// root. A copy, not a link, so that a later uninstall there does not break iOdus.
    static func copyExisting(_ existing: ExistingGPTK, release: GPTKRelease, into root: URL) throws {
        let fm = FileManager.default
        let target = release.installedApp(in: root)
        if fm.fileExists(atPath: target.path) {
            throw RuntimeSetupError.alreadyInstalled(target.deletingLastPathComponent().path)
        }
        guard fm.isExecutableFile(atPath: GPTKRelease.wine64(inApp: existing.app).path) else {
            throw RuntimeSetupError.badArchive("wine64 is missing in \(existing.app.path).")
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".copy-\(UUID().uuidString).app")
        defer { try? fm.removeItem(at: staging) }
        // ditto keeps the symbolic links, the permissions, and the signatures.
        try run("/usr/bin/ditto", [existing.app.path, staging.path])
        try fm.moveItem(at: staging, to: target)
    }

    // MARK: Detection

    /// The places where a Game Porting Toolkit app can be: the Gcenx Homebrew
    /// cask installs to /Applications; a manual copy can be in ~/Applications.
    static func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var list = [
            URL(fileURLWithPath: "/Applications/\(GPTKRelease.appName)"),
            home.appendingPathComponent("Applications/\(GPTKRelease.appName)"),
        ]
        for caskroom in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"] {
            let base = URL(fileURLWithPath: caskroom).appendingPathComponent("game-porting-toolkit")
            for version in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
                list.append(base.appendingPathComponent(version).appendingPathComponent(GPTKRelease.appName))
            }
        }
        return list
    }

    /// The Game Porting Toolkit apps in `candidates` that have wine64.
    static func findExisting(in candidates: [URL]) -> [ExistingGPTK] {
        let fm = FileManager.default
        var seen = Set<String>()
        return candidates.compactMap { app in
            let real = app.resolvingSymlinksInPath().path
            guard !seen.contains(real), fm.isExecutableFile(atPath: GPTKRelease.wine64(inApp: app).path) else { return nil }
            seen.insert(real)
            return ExistingGPTK(app: app, version: version(of: app))
        }
    }

    static func version(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    // MARK: Download

    /// Downloads the release archive to `destination`. `progress` gets the bytes
    /// so far and the total. The archive is checked with `verify` after this.
    static func download(_ release: GPTKRelease, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await download(url: release.url, size: release.size, to: destination, progress: progress)
    }

    static func download(url: URL, size: Int64, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        let delegate = DownloadDelegate(destination: destination, expected: size, progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Free space

    static func checkSpace(for release: GPTKRelease, at root: URL) throws {
        guard let free = Bytes.freeSpace(at: root) else { return }
        if free < release.neededBytes {
            throw RuntimeSetupError.notEnoughSpace(needed: release.neededBytes, free: free)
        }
    }

    // MARK: Tools

    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RuntimeSetupError.tool("\((tool as NSString).lastPathComponent) failed: \(text.isEmpty ? "exit \(process.terminationStatus)" : text)")
        }
    }
}

/// URLSession callbacks for one download. The finished file must move before
/// the callback returns, because URLSession then deletes its temporary file.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let expected: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private let lock = NSLock()

    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.expected = expected
        self.progress = progress
    }

    private var reported: Int64 = 0

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        // Report each 0.5 % only; URLSession calls this many times per second.
        let send = lock.withLock { () -> Bool in
            guard totalBytesWritten - reported >= max(1, total / 200) || totalBytesWritten >= total else { return false }
            reported = totalBytesWritten
            return true
        }
        if send { progress(totalBytesWritten, total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            lock.withLock { moveError = RuntimeSetupError.download("The server answered \(http.statusCode).") }
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error? = lock.withLock { error.map { RuntimeSetupError.download($0.localizedDescription) } ?? moveError }
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
    }
}

/// Rosetta 2 runs the Intel (x86_64) Wine of the Game Porting Toolkit.
enum RosettaStatus: Equatable {
    case installed
    case missing
    case notAppleSilicon    // An Intel Mac: the Game Porting Toolkit does not run.

    static let runtimeFile = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    /// The command that installs Rosetta. It needs an administrator password.
    static let installCommand = "/usr/sbin/softwareupdate --install-rosetta --agree-to-license"

    /// A test of the setup on a Mac that has Rosetta: the launch argument
    /// --simulate-missing-rosetta makes Rosetta show as missing until "Install
    /// Rosetta" runs. macOS cannot remove Rosetta, so this is the only way to see the step.
    nonisolated(unsafe) static var simulatedMissing = CommandLine.arguments.contains("--simulate-missing-rosetta")

    static func detect(appleSilicon: Bool = isAppleSilicon,
                       fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> RosettaStatus {
        guard appleSilicon else { return .notAppleSilicon }
        if simulatedMissing { return .missing }
        return fileExists(runtimeFile) ? .installed : .missing
    }

    /// True on Apple silicon, also when iOdus itself runs through Rosetta.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Installs Rosetta through the macOS administrator prompt. Call this only
    /// after the user selects "Install Rosetta".
    static func install() async throws {
        let script = "do shell script \"\(installCommand)\" with administrator privileges"
        try await Task.detached {
            try RuntimeSetup.run("/usr/bin/osascript", ["-e", script])
        }.value
        simulatedMissing = false
    }
}
