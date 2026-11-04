import Foundation

/// The cloud save state of one game, from the local save folders of the Xbox
/// runtime: <prefix>/drive_c/users/*/AppData/Local/XodusGameSave/<xuid>/<scid>/<container>/index.
/// Each index file has "dirty 1" while a change is not uploaded, and "remote"
/// with the time of the cloud copy.
enum CloudSaveStatus: Equatable {
    case noSaves                    // No saves from iOdus on this Mac
    case synced(Date?)              // All containers are uploaded; the newest cloud time
    case waiting(Date?)             // A change is not uploaded yet; the time of the local change
    case conflict(local: Date?, cloud: Date?)   // Both sides changed; the player must choose

    /// The save folder of a title: the SCID is the title ID in hex, at the end.
    static func scid(titleId: String) -> String? {
        guard let id = UInt32(titleId) else { return nil }
        return String(format: "00000000-0000-0000-0000-0000%08x", id)
    }

    static func read(titleId: String, prefix: URL) -> CloudSaveStatus {
        guard let scid = scid(titleId: titleId) else { return .noSaves }
        let fm = FileManager.default
        var indexes: [URL] = []
        for title in titleFolders(scid: scid, prefix: prefix) {
            // The runtime writes this file when both sides changed (iOdus runtime patch).
            if let text = try? String(contentsOf: title.appendingPathComponent(conflictFile), encoding: .utf8) {
                return parseConflict(text)
            }
            for container in containers(in: title) {
                indexes.append(container.appendingPathComponent("index"))
            }
        }
        return combine(indexes.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
    }

    static let conflictFile = "sync-conflict"

    /// The save folders of one title, one for each Wine user and Xbox account.
    /// The container folders of a title folder. Folders that start with a dot
    /// (".recovery-…", ".incoming-…") are transaction copies of the runtime.
    /// The runtime does not sync them, so their "dirty" lines do not count.
    static func containers(in title: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: title, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    /// The runtime names the account folders with the XUID: decimal digits only.
    /// Other folders (for example "726f6f74", a container name) are not accounts.
    static func isXUID(_ name: String) -> Bool {
        (1...20).contains(name.count) && name.allSatisfy { $0.isASCII && $0.isNumber } && !name.allSatisfy { $0 == "0" }
    }

    static func titleFolders(scid: String, prefix: URL) -> [URL] {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        var folders: [URL] = []
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let saves = user.appendingPathComponent("AppData/Local/XodusGameSave", isDirectory: true)
            for xuid in (try? fm.contentsOfDirectory(at: saves, includingPropertiesForKeys: nil)) ?? []
            where isXUID(xuid.lastPathComponent) {
                let title = xuid.appendingPathComponent(scid, isDirectory: true)
                if fm.fileExists(atPath: title.path) { folders.append(title) }
            }
        }
        return folders
    }

    /// "container root\nlocal 1793677467\nremote 2026-11-03T03:59:04.0000000Z\n"
    static func parseConflict(_ text: String) -> CloudSaveStatus {
        var local: Date?, cloud: Date?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "local", let seconds = TimeInterval(parts[1]), seconds > 0 {
                local = Date(timeIntervalSince1970: seconds)
            }
            if parts[0] == "remote" { cloud = parseRemote(parts[1]) }
        }
        return .conflict(local: local, cloud: cloud)
    }

    /// Copies the Mac saves of a title to SaveBackups, before a cloud download
    /// replaces them. Returns the backup folder.
    @discardableResult
    static func backup(titleId: String, prefix: URL, into root: URL = GameRuntime.support.appendingPathComponent("SaveBackups")) throws -> URL? {
        guard let scid = scid(titleId: titleId) else { return nil }
        let folders = titleFolders(scid: scid, prefix: prefix)
        guard !folders.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = root.appendingPathComponent("\(titleId)-\(formatter.string(from: Date()))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for folder in folders {
            let account = folder.deletingLastPathComponent().lastPathComponent
            try fm.copyItem(at: folder, to: target.appendingPathComponent(account, isDirectory: true))
        }
        return target
    }

    /// Combines the index files of all containers of one title.
    static func combine(_ files: [String]) -> CloudSaveStatus {
        var dirty = false, local: Date?, remote: Date?
        var any = false
        for text in files {
            any = true
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "dirty": if parts[1] != "0" { dirty = true }
                case "time":
                    if let seconds = TimeInterval(parts[1]), seconds > 0 {
                        local = max(local ?? .distantPast, Date(timeIntervalSince1970: seconds))
                    }
                case "remote":
                    if let date = parseRemote(parts[1]) { remote = max(remote ?? .distantPast, date) }
                default: break
                }
            }
        }
        guard any else { return .noSaves }
        return dirty ? .waiting(local) : .synced(remote)
    }

    /// "2026-11-03T03:59:04.0000000Z": seven fraction digits, so the fraction is removed.
    static func parseRemote(_ text: String) -> Date? {
        guard text.count >= 19 else { return nil }
        return ISO8601DateFormatter().date(from: String(text.prefix(19)) + "Z")
    }
}
