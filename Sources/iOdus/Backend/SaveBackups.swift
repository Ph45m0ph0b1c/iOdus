import Foundation

/// One copy of the Mac saves of a title, in SaveBackups/<titleId>-<yyyyMMdd-HHmmss>/<xuid>/.
/// CloudSaveStatus.backup makes them before a cloud download or a restore.
struct SaveBackup: Identifiable, Equatable {
    let url: URL
    let titleId: String
    let date: Date
    let accounts: [String]          // XUID folders in the backup
    let bytes: Int64

    var id: String { url.lastPathComponent }
}

/// Lists, restores, and deletes save backups. All paths are parameters, so
/// that tests can use temporary folders.
enum SaveBackups {
    static var standardRoot: URL { GameRuntime.support.appendingPathComponent("SaveBackups", isDirectory: true) }

    /// The backups of one title, newest first.
    static func list(titleId: String, root: URL = standardRoot) -> [SaveBackup] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return folders.compactMap { folder -> SaveBackup? in
            let name = folder.lastPathComponent
            guard name.hasPrefix(titleId + "-") else { return nil }
            let accounts = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
                .filter(CloudSaveStatus.isXUID)
                // An account folder holds container folders. A folder with an
                // index file is a container: the backup has a wrong layout.
                .filter { !fm.fileExists(atPath: folder.appendingPathComponent($0).appendingPathComponent("index").path) }
                .sorted()
            guard !accounts.isEmpty else { return nil }
            let stamp = String(name.dropFirst(titleId.count + 1))
            let date = parseStamp(stamp)
                ?? (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return SaveBackup(url: folder, titleId: titleId, date: date, accounts: accounts, bytes: size(of: folder))
        }
        .sorted { $0.date > $1.date }
    }

    static func hasBackups(titleId: String, root: URL = standardRoot) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { $0.hasPrefix(titleId + "-") } && !list(titleId: titleId, root: root).isEmpty
    }

    static func parseStamp(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.date(from: stamp)
    }

    private static func size(of folder: URL) -> Int64 {
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let file = files?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Restore

    enum RestoreResult: Equatable {
        case willUpload             // The cloud did not change since the backup: the next start uploads it
        case willAsk                // The cloud changed: the next Play asks which save to keep
    }

    /// Replaces the Mac saves of the title with the backup.
    ///
    /// 1. The current Mac saves go into a new backup first, so that the restore can be undone.
    /// 2. The backup replaces the save folder of each account in it.
    /// 3. Each container gets "dirty 1", and a stale sync-conflict file is removed.
    /// 4. If the cloud changed after the backup, iOdus writes a sync-conflict file.
    ///
    /// Why dirty 1: with "dirty 0" and a newer cloud save, the runtime downloads
    /// the cloud save at the next start and silently replaces the restored save.
    /// With "dirty 1", the runtime uploads the restored save when the cloud did not
    /// change, and it never overwrites a changed cloud save (it reports a
    /// conflict). iOdus does not force an upload, because that could replace
    /// newer progress in the cloud without a question. When the cloud changed
    /// (the current Mac save knows a newer cloud time than the backup), iOdus
    /// writes the sync-conflict file itself, so that the next Play asks at once,
    /// and the player does not lose a session with cloud saves off.
    @discardableResult
    static func restore(_ backup: SaveBackup, prefix: URL, root: URL = standardRoot) throws -> RestoreResult {
        guard let scid = CloudSaveStatus.scid(titleId: backup.titleId) else {
            throw BackendError.failed("The backup has no valid title ID.")
        }
        let fm = FileManager.default
        let current = CloudSaveStatus.titleFolders(scid: scid, prefix: prefix)
        let currentCloud = newestRemote(in: current)

        // Undo copy. A failure here stops the restore before anything changes.
        try CloudSaveStatus.backup(titleId: backup.titleId, prefix: prefix, into: root)

        var restored: [URL] = []
        for account in backup.accounts where CloudSaveStatus.isXUID(account) {
            let target = current.first { $0.deletingLastPathComponent().lastPathComponent == account }
                ?? saveRoot(prefix: prefix).appendingPathComponent(account, isDirectory: true)
                    .appendingPathComponent(scid, isDirectory: true)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: backup.url.appendingPathComponent(account, isDirectory: true), to: target)
            try? fm.removeItem(at: target.appendingPathComponent(CloudSaveStatus.conflictFile))
            try markDirty(title: target)
            restored.append(target)
        }

        let backupCloud = newestRemote(in: restored)
        if let currentCloud, backupCloud.map({ currentCloud.date > $0.date }) ?? true {
            let local = newestTime(in: restored)
            for target in restored {
                let text = "container -\nlocal \(Int64(local?.timeIntervalSince1970 ?? 0))\nremote \(currentCloud.text)\n"
                try text.write(to: target.appendingPathComponent(CloudSaveStatus.conflictFile), atomically: true, encoding: .utf8)
            }
            return .willAsk
        }
        return .willUpload
    }

    static func delete(_ backup: SaveBackup, root: URL = standardRoot) throws {
        // Only a folder inside the backup root can be deleted.
        guard backup.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw BackendError.failed("The backup is not in the backup folder.")
        }
        try FileManager.default.removeItem(at: backup.url)
    }

    /// The XodusGameSave folder of the Wine user that has saves, else of "crossover".
    static func saveRoot(prefix: URL) -> URL {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let fm = FileManager.default
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let saves = user.appendingPathComponent("AppData/Local/XodusGameSave", isDirectory: true)
            if fm.fileExists(atPath: saves.path) { return saves }
        }
        return users.appendingPathComponent("crossover/AppData/Local/XodusGameSave", isDirectory: true)
    }

    // MARK: Index files

    private static func indexes(in titles: [URL]) -> [URL] {
        titles.flatMap { title in
            CloudSaveStatus.containers(in: title)
                .map { $0.appendingPathComponent("index") }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private static func values(_ key: String, in titles: [URL]) -> [String] {
        indexes(in: titles).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap { text in
            text.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[0] == key ? parts[1] : nil
            }
        }
    }

    /// The newest cloud time in the index files, with its original text.
    static func newestRemote(in titles: [URL]) -> (date: Date, text: String)? {
        values("remote", in: titles)
            .compactMap { text in CloudSaveStatus.parseRemote(text).map { (date: $0, text: text) } }
            .max { $0.date < $1.date }
    }

    private static func newestTime(in titles: [URL]) -> Date? {
        values("time", in: titles).compactMap(TimeInterval.init).filter { $0 > 0 }.max()
            .map { Date(timeIntervalSince1970: $0) }
    }

    /// Sets "dirty 1" in each container index of the title folder.
    static func markDirty(title: URL) throws {
        for index in indexes(in: [title]) {
            let text = try String(contentsOf: index, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            if let i = lines.firstIndex(where: { $0.hasPrefix("dirty ") }) {
                lines[i] = "dirty 1"
            } else {
                lines.insert("dirty 1", at: max(0, lines.count - 1))
            }
            try lines.joined(separator: "\n").write(to: index, atomically: true, encoding: .utf8)
        }
    }
}
