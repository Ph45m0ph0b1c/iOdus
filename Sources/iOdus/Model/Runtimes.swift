import Foundation

/// The installed runtimes: the built-in GPTK runtime, then each folder in
/// `Runtimes/` with a valid runtime.json. Each runtime has its own prefix in
/// `Prefixes/<id>`.
enum RuntimeCatalog {
    static var runtimesFolder: URL { GameRuntime.support.appendingPathComponent("Runtimes", isDirectory: true) }
    static var prefixesFolder: URL { GameRuntime.support.appendingPathComponent("Prefixes", isDirectory: true) }

    static func discover(folder: URL = runtimesFolder, prefixes: URL = prefixesFolder,
                         standard: GameRuntime = .standard) -> [GameRuntime] {
        // A test passes its own GPTK runtime; then the other runtimes use its DLL folder too.
        let testing = standard.root != GameRuntime.standard.root
        var list = [standard]
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for root in folders {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("runtime.json")),
                  let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data),
                  isValidID(manifest.id), manifest.id == root.lastPathComponent,
                  !list.contains(where: { $0.id == manifest.id }) else { continue }
            list.append(.from(manifest: manifest, root: root,
                              prefix: prefixes.appendingPathComponent(manifest.id, isDirectory: true),
                              componentRoot: standard.componentRoot, usesBundle: !testing))
        }
        return list
    }

    /// Letters, digits, ".", "-", and "_" only: the ID is a folder name.
    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && !id.hasPrefix(".")
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }
}

/// The default runtime and the runtime of each game (product ID), in UserDefaults.
struct RuntimeChoice {
    static let defaultKey = "defaultRuntime"
    static let gamesKey = "gameRuntimes"
    let defaults: UserDefaults

    var defaultID: String? {
        get { defaults.string(forKey: Self.defaultKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.defaultKey) }
    }

    func gameID(_ productId: String) -> String? {
        (defaults.dictionary(forKey: Self.gamesKey) as? [String: String])?[productId.uppercased()]
    }

    /// nil: the game uses the default runtime.
    func setGame(_ productId: String, _ runtimeID: String?) {
        var map = (defaults.dictionary(forKey: Self.gamesKey) as? [String: String]) ?? [:]
        map[productId.uppercased()] = runtimeID
        defaults.set(map, forKey: Self.gamesKey)
    }

    /// The default runtime: the saved one if it is installed, else the first (GPTK).
    func defaultRuntime(in list: [GameRuntime]) -> GameRuntime {
        list.first { $0.id == defaultID } ?? list[0]
    }

    /// The runtime of a game: its own choice if installed, else the default.
    func runtime(for productId: String, in list: [GameRuntime]) -> GameRuntime {
        if let id = gameID(productId), let runtime = list.first(where: { $0.id == id }) { return runtime }
        return defaultRuntime(in: list)
    }
}

/// One row of the Runtimes page.
enum RuntimeRow: Equatable {
    case useDefault                     // Game page only: the game uses the default
    case installed(GameRuntime)
    case available(RuntimeDownload)     // Settings only: not installed, or a newer release
}

/// A runtime download in progress.
struct RuntimeDownloadState: Equatable {
    let id: String
    var done: Int64 = 0
    var total: Int64 = 0
    var installing = false
}

/// The Runtimes page: from Settings it sets the default runtime and offers
/// downloads; from a game page it sets the runtime of that game.
extension AppModel {
    var defaultRuntime: GameRuntime { runtimeChoice.defaultRuntime(in: runtimes) }

    func runtime(for game: Game) -> GameRuntime {
        runtimeChoice.runtime(for: game.id, in: runtimes)
    }

    /// The prefix with the saves of a game (tests can override all prefixes).
    func savePrefix(for game: Game) -> URL {
        savePrefixOverride ?? runtime(for: game).prefix
    }

    func reloadRuntimes() {
        guard !demo else { return }
        runtimes = RuntimeCatalog.discover()
    }

    /// The release of an installed runtime (from its runtime.json), or nil.
    func installedRelease(_ id: String) -> Int? {
        guard let runtime = runtimes.first(where: { $0.id == id }),
              let data = try? Data(contentsOf: runtime.root.appendingPathComponent("runtime.json")),
              let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else { return nil }
        return manifest.release ?? 0
    }

    /// Downloads that are not installed, or that have a newer release.
    var availableDownloads: [RuntimeDownload] {
        guard !demo else { return [] }
        return runtimeDownloadCatalog.filter { download in
            guard runtimes.contains(where: { $0.id == download.id }) else { return true }
            return (installedRelease(download.id) ?? 0) < download.release
        }
    }

    func runtimeRows(for gameID: Game.ID?) -> [RuntimeRow] {
        if gameID == nil {
            return runtimes.map { .installed($0) } + availableDownloads.map { .available($0) }
        }
        return [.useDefault] + runtimes.map { .installed($0) }
    }

    /// The row that the game or the default uses now.
    func selectedRuntimeRow(for gameID: Game.ID?) -> Int {
        let rows = runtimeRows(for: gameID)
        let chosen = gameID.map { runtimeChoice.gameID($0) } ?? defaultRuntime.id
        guard let chosen else { return 0 }
        return rows.firstIndex { if case .installed(let r) = $0 { return r.id == chosen }; return false } ?? 0
    }

    func openRuntimes(gameID: Game.ID?) {
        reloadRuntimes()
        runtimeIndex = selectedRuntimeRow(for: gameID)
        stack.append(.runtimes(gameID))
    }

    func moveRuntimes(_ d: Direction) {
        guard case .runtimes(let gameID) = screen else { return }
        let count = runtimeRows(for: gameID).count
        switch d {
        case .up: runtimeIndex = max(0, runtimeIndex - 1)
        case .down: runtimeIndex = min(count - 1, runtimeIndex + 1)
        default: break
        }
    }

    func tapRuntime(_ index: Int) {
        runtimeIndex = index
        chooseRuntime()
    }

    /// A: use the focused runtime, or download it.
    func chooseRuntime() {
        guard case .runtimes(let gameID) = screen else { return }
        let rows = runtimeRows(for: gameID)
        guard runtimeIndex < rows.count else { return }
        switch rows[runtimeIndex] {
        case .available(let download):
            downloadRuntime(download)
        case .useDefault:
            guard let gameID, let game = game(gameID) else { return }
            useRuntime(nil, for: game)
        case .installed(let runtime):
            if let problem = runtime.problem {
                showToast(problem, seconds: 8)
                return
            }
            if let gameID, let game = game(gameID) {
                useRuntime(runtime, for: game)
            } else {
                runtimeChoice.defaultID = runtime.id
                objectWillChange.send()
                showToast("New games use \(runtime.displayName).")
            }
        }
    }

    private func useRuntime(_ runtime: GameRuntime?, for game: Game) {
        let target = runtime ?? defaultRuntime
        if let reason = runtimeSwitchBlock(game, to: target) {
            showToast(reason, seconds: 8)
            return
        }
        runtimeChoice.setGame(game.id, runtime?.id)
        objectWillChange.send()
        showToast("\(game.title) uses \(target.displayName).")
    }

    /// A save that is not in the cloud stays in the prefix of the old runtime.
    /// The switch waits until it is uploaded, so that the new prefix gets it.
    func runtimeSwitchBlock(_ game: Game, to target: GameRuntime) -> String? {
        let current = runtime(for: game)
        if playState.gameID == game.id { return "Stop \(game.title) first." }
        guard target.id != current.id, let titleId = game.titleId, savePrefixOverride == nil else { return nil }
        switch CloudSaveStatus.read(titleId: titleId, prefix: current.prefix) {
        case .waiting:
            return "A save of \(game.title) is not uploaded yet. Play it once on \(current.name), so that the save uploads, then switch."
        case .conflict:
            return "\(game.title) has a save conflict. Choose a save at the next start on \(current.name), then switch."
        default:
            return nil
        }
    }

    /// X on the Settings page of runtimes: prepare the focused runtime again.
    func prepareFocusedRuntime() {
        guard case .runtimes(nil) = screen else { return }
        let rows = runtimeRows(for: nil)
        guard runtimeIndex < rows.count, case .installed(let runtime) = rows[runtimeIndex] else { return }
        prepareRuntime(runtime)
    }

    // MARK: Download

    func downloadRuntime(_ download: RuntimeDownload) {
        guard runtimeDownload == nil else {
            showToast("A runtime download is running.")
            return
        }
        guard playState == .idle else {
            showToast("Stop the game first.")
            return
        }
        guard gptkHasD3DMetal else {
            showToast(RuntimeInstallError.noGPTK.errorDescription ?? "", seconds: 8)
            return
        }
        runtimeDownload = RuntimeDownloadState(id: download.id, total: download.size)
        Task {
            do {
                try await fetchRuntime(download, progress: { done, total in
                    guard self.runtimeDownload?.id == download.id else { return }
                    self.runtimeDownload?.done = done
                    if total > 0 { self.runtimeDownload?.total = total }
                }, installing: { self.runtimeDownload?.installing = true })
                showToast("\(download.displayName) is installed. Choose it as the default or on a game page.", seconds: 6)
            } catch {
                showToast(error.localizedDescription, seconds: 8)
            }
            runtimeDownload = nil
        }
    }

    /// True when the Game Porting Toolkit has D3DMetal for a downloaded runtime.
    var gptkHasD3DMetal: Bool {
        FileManager.default.fileExists(atPath: RuntimeInstaller.gptkWine.appendingPathComponent("lib/external/D3DMetal.framework").path)
    }

    /// Downloads, checks, and installs a runtime, then reloads the list.
    /// Settings and the setup use it. The archive is removed in all cases.
    func fetchRuntime(_ download: RuntimeDownload,
                      progress: @escaping @MainActor (Int64, Int64) -> Void,
                      installing: @escaping @MainActor () -> Void) async throws {
        guard gptkHasD3DMetal else { throw RuntimeInstallError.noGPTK }
        if let free = Bytes.freeSpace(at: GameRuntime.support), free < download.neededBytes {
            throw RuntimeSetupError.notEnoughSpace(needed: download.neededBytes, free: free)
        }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("iodus-\(download.id)-\(download.release).tar.xz")
        defer { try? FileManager.default.removeItem(at: archive) }
        try await RuntimeSetup.download(url: download.url, size: download.size, to: archive) { done, total in
            Task { @MainActor in progress(done, total) }
        }
        try Task.checkCancellation()
        installing()
        let runtimesFolder = RuntimeCatalog.runtimesFolder
        try await Task.detached {
            try RuntimeSetup.verify(archive, sha256: download.sha256)
            try RuntimeInstaller.install(archive: archive, download: download, runtimes: runtimesFolder)
        }.value
        reloadRuntimes()
    }
}
