import Foundation

/// Makes one zip file with the information for a bug report: the game logs,
/// the versions, the cloud save state files, and the installed games. The
/// text is redacted: no tokens, no email address, no account name, no XUIDs.
/// Save data and Keychain data are never read.
struct LogExport {
    /// One installed game, for games.txt.
    struct GameEntry: Equatable {
        let title: String
        let productId: String
        let titleId: String?
        let path: String
    }

    /// The input of an export. Tests give temporary folders.
    struct Sources {
        var logFolder: URL
        var prefix: URL                 // The Wine prefix, for the cloud save state files
        var runtimeRoot: URL            // The GPTK runtime folder
        var lockFile: URL?              // backend-source.lock.json
        var games: [GameEntry]
        var accountName: String
        var appVersion: String
        var backendVersion: String?
        var runtimeStatus: [String]
        var home: String = NSHomeDirectory()
    }

    /// A log file can be large (Wine traces). Only the end of each file goes into the zip.
    static let maxLogBytes = 4 * 1024 * 1024

    // MARK: Redaction

    /// Removes secrets and personal data from a text.
    static func redact(_ text: String, account: String, home: String) -> String {
        var out = text
        if !account.isEmpty {
            out = out.replacingOccurrences(of: account, with: "<account>", options: .caseInsensitive)
        }
        let rules: [(String, String)] = [
            // Xbox Live authorization headers: "XBL3.0 x=<user hash>;<token>"
            (#"XBL3\.0 x=[^\s"',]+"#, "XBL3.0 x=<token>"),
            // JSON Web Tokens and other base64 tokens that start with a JSON header
            (#"eyJ[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+){0,2}"#, "<token>"),
            // "Authorization: ...", "Bearer ...", and "token=..." values
            (#"(?i)(authorization\s*[:=]\s*)[^\r\n"]+"#, "$1<token>"),
            (#"(?i)\bbearer\s+[A-Za-z0-9._\-~+/=]+"#, "Bearer <token>"),
            (#"(?i)("?(?:access_?token|refresh_?token|token|signature|password)"?\s*[:=]\s*"?)[^\s"',;&]+"#, "$1<token>"),
            // Email addresses
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),
            // XUIDs: 16 digits that start with 25 (for example 2533274800000001)
            (#"(?<![0-9])25[0-9]{14}(?![0-9])"#, "<xuid>"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        if !home.isEmpty && home != "/" {
            out = out.replacingOccurrences(of: home, with: "~")
            // The Wine form of the home folder: "Z:\\Users\\name" (any case).
            let wineHome = "Z:" + home.replacingOccurrences(of: "/", with: "\\")
            out = out.replacingOccurrences(of: wineHome, with: "~", options: .caseInsensitive)
            // The user name alone, for example "mounted by name" from hdiutil.
            let user = (home as NSString).lastPathComponent
            if user.count >= 3 {
                let pattern = "(?i)(?<![A-Za-z0-9_.-])" + NSRegularExpression.escapedPattern(for: user) + "(?![A-Za-z0-9_-])"
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<user>")
                }
            }
        }
        // The per-user temporary folder (/private/var/folders/xx/<id>/T/) identifies the Mac user.
        if let regex = try? NSRegularExpression(pattern: #"(/private)?/var/folders/[A-Za-z0-9_+-]{2}/[A-Za-z0-9_+-]+/"#) {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<tmp>/")
        }
        return out
    }

    // MARK: Collection

    /// Writes the report files into `folder`. Returns the relative paths of the files.
    @discardableResult
    static func collect(_ sources: Sources, into folder: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [String] = []
        func write(_ text: String, _ relative: String) throws {
            let url = folder.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let clean = redact(text, account: sources.accountName, home: sources.home)
            try Data(clean.utf8).write(to: url)
            written.append(relative)
        }

        // 1. The game logs (the end of each file).
        let logs = (try? fm.contentsOfDirectory(at: sources.logFolder, includingPropertiesForKeys: nil)) ?? []
        for log in logs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where log.pathExtension == "log" {
            guard let data = tail(of: log, bytes: maxLogBytes) else { continue }
            let name = redact(log.lastPathComponent, account: sources.accountName, home: sources.home)
            try write(String(decoding: data, as: UTF8.self), "logs/" + name)
        }

        // 2. The versions.
        try write(systemText(sources), "system.txt")
        if let lock = sources.lockFile, let text = try? String(contentsOf: lock, encoding: .utf8) {
            try write(text, "backend-source.lock.json")
        }

        // 3. The installed games.
        let games = sources.games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let lines = games.map { "\($0.title)\tproduct \($0.productId)\ttitle \($0.titleId ?? "-")\t\($0.path)" }
        try write((["Title\tProduct ID\tTitle ID\tFolder"] + lines).joined(separator: "\n") + "\n", "games.txt")

        // 4. The cloud save state files. Each account folder gets a number, not its XUID.
        written += try copySaveState(sources, into: folder)
        return written
    }

    /// The index and sync-conflict files of the cloud saves, never the save data.
    private static func copySaveState(_ sources: Sources, into folder: URL) throws -> [String] {
        let fm = FileManager.default
        let users = sources.prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        var written: [String] = []
        var accountNumbers: [String: Int] = [:]
        func list(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for user in list(users) {
            let saves = user.appendingPathComponent("AppData/Local/XodusGameSave", isDirectory: true)
            for account in list(saves) {
                let number: Int
                if let known = accountNumbers[account.lastPathComponent] { number = known } else {
                    number = accountNumbers.count + 1
                    accountNumbers[account.lastPathComponent] = number
                }
                for title in list(account) {
                    let titleName = titleId(fromScid: title.lastPathComponent) ?? "scid-" + title.lastPathComponent
                    let base = "saves/\(titleName)/account-\(number)"
                    for file in [CloudSaveStatus.conflictFile] where fm.fileExists(atPath: title.appendingPathComponent(file).path) {
                        written.append(try copyText(title.appendingPathComponent(file), to: folder, base + "/" + file, sources))
                    }
                    for container in list(title) {
                        let index = container.appendingPathComponent("index")
                        guard fm.fileExists(atPath: index.path) else { continue }
                        written.append(try copyText(index, to: folder, "\(base)/\(container.lastPathComponent)/index", sources))
                    }
                }
            }
        }
        return written
    }

    private static func copyText(_ source: URL, to folder: URL, _ relative: String, _ sources: Sources) throws -> String {
        let text = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        let url = folder.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(redact(text, account: sources.accountName, home: sources.home).utf8).write(to: url)
        return relative
    }

    /// "00000000-0000-0000-0000-00007eefb20d" → "2129637901"
    static func titleId(fromScid scid: String) -> String? {
        guard scid.hasPrefix("00000000-0000-0000-0000-0000"), let value = UInt32(scid.suffix(8), radix: 16) else { return nil }
        return String(value)
    }

    static func systemText(_ sources: Sources) -> String {
        let fm = FileManager.default
        let gptk = ((try? fm.contentsOfDirectory(atPath: sources.runtimeRoot.path)) ?? [])
            .filter { $0.hasPrefix("gptk-") }.sorted()
        var lines = [
            "iOdus \(sources.appVersion)",
            "Exported \(ISO8601DateFormatter().string(from: Date()))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac model \(sysctl("hw.model") ?? "unknown")",
            "Chip \(sysctl("machdep.cpu.brand_string") ?? "unknown")",
            "Memory \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB",
            "Backend \(sources.backendVersion ?? "unknown")",
            "GPTK \(gptk.isEmpty ? "not installed" : gptk.joined(separator: ", "))",
        ]
        lines.append("Game runtime:")
        lines += sources.runtimeStatus.map { "  " + $0 }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The last `bytes` of a file.
    static func tail(of url: URL, bytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        return try? handle.readToEnd()
    }

    // MARK: Zip

    static func fileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "iOdus-logs-\(formatter.string(from: date)).zip"
    }

    /// Collects the files and makes the zip file in `destination`. Returns the zip file.
    static func export(_ sources: Sources, to destination: URL, date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let zip = destination.appendingPathComponent(fileName(date: date))
        let staging = fm.temporaryDirectory.appendingPathComponent("iodus-logs-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(zip.deletingPathExtension().lastPathComponent, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try collect(sources, into: folder)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: zip.path) else {
            throw BackendError.failed("ditto could not make the zip file (status \(process.terminationStatus)).")
        }
        return zip
    }
}
