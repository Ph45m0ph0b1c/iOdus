import Foundation

enum DownloadStatus: String, Codable {
    case queued, running, paused, stopped, complete, failed
}

struct DownloadTask: Identifiable, Codable, Equatable {
    let id: String            // Store product ID
    let title: String
    let contentId: String
    let destination: String
    var tileArt: URL?
    var status: DownloadStatus = .queued
    var phase = "Waiting in the queue"
    var error: String?
    var completed: Int64 = 0
    var total: Int64?
    var rate: Int64 = 0
    var canPause = false

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    var isActive: Bool { status != .complete }
}

struct InstalledGame: Codable, Equatable {
    let productId: String
    let title: String
    let contentId: String
    let path: String
    let installedAt: Date
}

/// The install queue. One download runs at a time, like in Nexus.
/// State is saved in ~/Library/Application Support/iOdus/state.json.
@MainActor
final class DownloadManager {
    private(set) var tasks: [DownloadTask] = []
    private(set) var installs: [String: InstalledGame] = [:]
    var onChange: (() -> Void)?
    /// Called when a download is complete or failed (not when it stops).
    var onFinished: ((DownloadTask) -> Void)?

    var cli: XodusCLI?
    var market = "US"
    let parallel = 4

    private var process: StreamingProcess?
    private var runningID: String?
    private var lastSequence: Int64 = -1
    private var terminalPhase: String?
    private var stopping = Set<String>()

    nonisolated static let installRootKey = "installRoot"

    /// The folder from Settings, or ~/Games/iOdus.
    nonisolated static var installRoot: URL {
        if let path = UserDefaults.standard.string(forKey: installRootKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/iOdus", isDirectory: true)
    }

    nonisolated static var defaultStateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iOdus/state.json")
    }

    private let stateFile: URL
    private(set) var installRoot: URL

    /// Changes the folder for new installs. Games that are installed stay where they are.
    func setInstallRoot(_ url: URL) {
        installRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.installRootKey)
    }

    init(stateFile: URL = DownloadManager.defaultStateFile, installRoot: URL = DownloadManager.installRoot) {
        self.stateFile = stateFile
        self.installRoot = installRoot
        load()
    }

    // MARK: - Queries

    func installState(for productId: String) -> InstallState {
        if installs[productId] != nil { return .installed }
        if let task = tasks.first(where: { $0.id == productId && $0.isActive }) {
            return .downloading(progress: task.fraction ?? 0)
        }
        return .notInstalled
    }

    func task(_ productId: String) -> DownloadTask? { tasks.first { $0.id == productId } }

    /// A folder name from the title, unique in the install root.
    func destination(for title: String, productId: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " -_.&'()"))
        var name = String(title.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.hasPrefix(".") { name = productId }
        let used = Set(tasks.map(\.destination) + installs.values.map(\.path))
        var url = installRoot.appendingPathComponent(name, isDirectory: true)
        if used.contains(url.path) || (FileManager.default.fileExists(atPath: url.path) && installs[productId] == nil) {
            url = installRoot.appendingPathComponent("\(name) (\(productId))", isDirectory: true)
        }
        return url
    }

    // MARK: - Actions

    func enqueue(game: Game, choice: InstallChoice) {
        if let index = tasks.firstIndex(where: { $0.id == game.id }) {
            if tasks[index].status == .complete { tasks.remove(at: index) } else { resume(game.id); return }
        }
        let task = DownloadTask(id: game.id, title: game.title, contentId: choice.contentId,
                                destination: destination(for: game.title, productId: game.id).path,
                                tileArt: game.tileArt, total: choice.downloadBytes)
        tasks.append(task)
        changed()
        startNext()
    }

    /// A on a download: pause, resume, or start again.
    func toggle(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        switch tasks[index].status {
        case .running:
            guard tasks[index].canPause, runningID == id else { return }
            process?.send(#"{"schema":1,"command":"pause"}"#)
            tasks[index].phase = "Pausing…"
            changed()
        case .paused:
            if runningID == id {
                process?.send(#"{"schema":1,"command":"resume"}"#)
                tasks[index].phase = "Resuming…"
                changed()
            } else {
                resume(id)
            }
        case .stopped, .failed:
            resume(id)
        case .queued, .complete:
            break
        }
    }

    /// X on a download: stop it (files stay), or remove a stopped one from the list.
    func stopOrRemove(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        switch tasks[index].status {
        case .running, .paused, .queued:
            if runningID == id {
                // The CLI stops on SIGINT and keeps the files for a later resume.
                stopping.insert(id)
                tasks[index].phase = "Stopping…"
                process?.interrupt()
            } else {
                tasks[index].status = .stopped
                tasks[index].phase = "Stopped. The files are kept."
            }
            changed()
        case .stopped, .failed, .complete:
            tasks.remove(at: index)
            changed()
        }
    }

    /// At app quit: stop the running download so that it can resume later.
    func stopForQuit() {
        if let id = runningID {
            stopping.insert(id)
            process?.interrupt()
        }
        save()
    }

    // MARK: - Running

    private func resume(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = .queued
        tasks[index].error = nil
        tasks[index].phase = "Waiting in the queue"
        changed()
        startNext()
    }

    private func startNext() {
        guard runningID == nil, let cli,
              let index = tasks.firstIndex(where: { $0.status == .queued }) else { return }
        let task = tasks[index]
        // A download from an earlier iOdus (for example after a force quit) can
        // still run and hold the lock of the folder. Stop it first; its files stay.
        let orphans = Orphans.find(cli: cli.url, arguments: ["streaming", task.id])
        if !orphans.isEmpty {
            runningID = task.id
            tasks[index].status = .running
            tasks[index].phase = "Stopping an earlier download of this game…"
            changed()
            Task { [weak self] in
                _ = await Orphans.stop(orphans)
                guard let self else { return }
                self.runningID = nil
                if let i = self.tasks.firstIndex(where: { $0.id == task.id }), self.tasks[i].status == .running {
                    if self.stopping.remove(task.id) != nil {
                        self.tasks[i].status = .stopped
                        self.tasks[i].phase = "Stopped. The files are kept."
                    } else {
                        self.tasks[i].status = .queued
                    }
                }
                self.changed()
                self.startNext()
            }
            return
        }
        try? FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let args = ["streaming", task.id, task.destination,
                    "--parallel", String(parallel), "--market", market,
                    "--selected-content-id", task.contentId,
                    "--progress-json", "--control-stdin"]
        let process = StreamingProcess(url: cli.url, arguments: args)
        lastSequence = -1
        terminalPhase = nil
        tasks[index].status = .running
        tasks[index].phase = "Starting…"
        runningID = task.id
        self.process = process
        changed()
        do {
            try process.start(
                onLine: { [weak self] line in self?.handle(line: line, id: task.id) },
                onExit: { [weak self] code, stderr in self?.finish(id: task.id, code: code, stderr: stderr) })
        } catch {
            runningID = nil
            self.process = nil
            tasks[index].status = .failed
            tasks[index].error = error.localizedDescription
            tasks[index].phase = "The download could not start"
            changed()
            startNext()
        }
    }

    private static let phaseText = [
        "initializing": "Preparing download",
        "metadata": "Reading package data",
        "downloading": "Downloading",
        "finalizing": "Finishing the installation",
        "complete": "Installed",
        "failed": "The installation failed",
    ]

    private func handle(line: String, id: String) {
        guard let record = ProgressRecord.parse(line), record.sequence > lastSequence, terminalPhase == nil,
              let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        lastSequence = record.sequence
        if record.phase == "complete" || record.phase == "failed" { terminalPhase = record.phase }
        var task = tasks[index]
        task.completed = record.completedBytes
        task.total = record.totalBytes ?? task.total
        task.rate = record.paused ? 0 : record.bytesPerSecond
        task.canPause = record.canPause && record.phase == "downloading"
        if !stopping.contains(id) {
            task.status = record.paused ? .paused : .running
            task.phase = record.paused ? "Paused" : Self.phaseText[record.phase] ?? record.phase
        }
        tasks[index] = task
        changed(save: false)
    }

    private func finish(id: String, code: Int32, stderr: String) {
        process = nil
        runningID = nil
        let stopped = stopping.remove(id) != nil
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            var task = tasks[index]
            task.rate = 0
            task.canPause = false
            if stopped || code == 130 {
                task.status = .stopped
                task.phase = "Stopped. The files are kept."
            } else if code == 0 && terminalPhase == "complete" {
                task.status = .complete
                task.phase = "Installed"
                task.completed = task.total ?? task.completed
                installs[id] = InstalledGame(productId: id, title: task.title, contentId: task.contentId,
                                             path: task.destination, installedAt: Date())
            } else {
                task.status = .failed
                task.error = XodusCLI.message(from: stderr)
                task.phase = code == 0 ? "The backend did not confirm the installation" : "The download failed"
            }
            tasks[index] = task
            if task.status == .complete || task.status == .failed { onFinished?(task) }
        }
        changed()
        startNext()
    }

    // MARK: - State

    private func changed(save: Bool = true) {
        if save { self.save() }
        onChange?()
    }

    private struct SavedState: Codable {
        var installs: [String: InstalledGame]
        var tasks: [DownloadTask]
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        // A game folder that the user deleted is not installed.
        installs = state.installs.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        tasks = state.tasks.map { task in
            var task = task
            if [.queued, .running, .paused].contains(task.status) {
                task.status = .stopped
                task.phase = "Stopped. Press A to resume."
            }
            task.rate = 0
            task.canPause = false
            return task
        }
    }

    // MARK: Uninstall

    /// Why a game folder must not be deleted, or nil when it is safe.
    /// The folder must be the recorded install folder, a real game folder
    /// (MicrosoftGame.config), and not the home folder, a top-level folder,
    /// or the install root itself.
    nonisolated static func uninstallProblem(path: String, home: String = NSHomeDirectory(),
                                             installRoot: String? = nil) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let clean = url.path
        let parts = url.pathComponents.filter { $0 != "/" }
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath()
        if !path.hasPrefix("/") || parts.count < 3 || clean == homeURL.path
            || clean == installRoot.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }) {
            return "iOdus does not delete \(clean)."
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: clean, isDirectory: &isFolder), isFolder.boolValue else {
            return "The game folder does not exist."
        }
        guard GameConfig.configFile(in: url) != nil else {
            return "\(clean) has no MicrosoftGame.config, so iOdus does not delete it."
        }
        return nil
    }

    /// Deletes the game folder and forgets the install. The saves are not in it.
    func uninstall(_ productId: String) throws {
        guard let install = installs[productId] else { throw BackendError.failed("The game is not installed.") }
        if let task = task(productId), task.status != .complete {
            throw BackendError.failed("A download of this game is in the list. Remove it first.")
        }
        if FileManager.default.fileExists(atPath: install.path) {
            if let problem = Self.uninstallProblem(path: install.path, installRoot: installRoot.path) {
                throw BackendError.failed(problem)
            }
            try FileManager.default.removeItem(atPath: install.path)
        }
        installs[productId] = nil
        tasks.removeAll { $0.id == productId && $0.status == .complete }
        save()
        onChange?()
    }

    // MARK: Rescan

    /// What a rescan of the install folder changed.
    struct RescanResult: Equatable {
        var added: [InstalledGame] = []
        var copies: [String] = []       // Folders of a game that has a record with another folder
        var forgotten: [String] = []    // Titles whose folder in the install folder is gone
    }

    /// The product ID in MicrosoftGame.Config: the first <StoreId> that is not
    /// the zero placeholder.
    nonisolated static func storeId(inConfig text: String) -> String? {
        let pattern = #"<StoreId>\s*([A-Za-z0-9]{12})\s*</StoreId>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let id = text[r].uppercased()
            if id != "000000000000" { return id }
        }
        return nil
    }

    /// Finds game folders in the install folder that have no record, for
    /// example after a fresh install of iOdus. It also forgets records whose
    /// folder in the install folder is gone. It never deletes files.
    /// `titles` gives the library names; a folder of an unknown game keeps its folder name.
    func rescan(titles: [String: String]) -> RescanResult {
        let fm = FileManager.default
        var result = RescanResult()
        let root = installRoot.standardizedFileURL.resolvingSymlinksInPath()
        // An unmounted drive: do not forget the games on it.
        guard fm.fileExists(atPath: root.path) else { return result }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"

        for (id, install) in installs.sorted(by: { $0.key < $1.key }) {
            let path = URL(fileURLWithPath: install.path).standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath), !fm.fileExists(atPath: path) {
                installs[id] = nil
                result.forgotten.append(install.title)
            }
        }

        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true,
                  let text = try? String(contentsOf: folder.appendingPathComponent("MicrosoftGame.Config"), encoding: .utf8),
                  let id = Self.storeId(inConfig: text) else { continue }
            // A download writes into its folder: leave it alone.
            if let task = task(id), task.status != .complete { continue }
            if let install = installs[id] {
                let known = URL(fileURLWithPath: install.path).standardizedFileURL.resolvingSymlinksInPath().path
                if known != folder.standardizedFileURL.resolvingSymlinksInPath().path {
                    result.copies.append(folder.lastPathComponent)
                }
                continue
            }
            let game = InstalledGame(productId: id, title: titles[id] ?? folder.lastPathComponent, contentId: "",
                                     path: folder.path, installedAt: values?.creationDate ?? Date())
            installs[id] = game
            result.added.append(game)
        }
        if !result.added.isEmpty || !result.forgotten.isEmpty {
            save()
            onChange?()
        }
        return result
    }

    /// The size of a folder on disk, for the uninstall prompt.
    nonisolated static func folderSize(_ path: String) -> Int64 {
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: URL(fileURLWithPath: path),
                                                   includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        while let file = files?.nextObject() as? URL {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    func save() {
        let state = SavedState(installs: installs, tasks: tasks.filter { $0.status != .complete })
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }
}

enum Bytes {
    static func text(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func rate(_ value: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: value, countStyle: .file))/s"
    }

    /// Free space on the volume of a folder. The folder can be missing:
    /// then the nearest parent folder that exists gives the volume.
    static func freeSpace(at url: URL) -> Int64? {
        var folder = url
        while !FileManager.default.fileExists(atPath: folder.path), folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
