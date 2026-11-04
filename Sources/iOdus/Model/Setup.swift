import AppKit

/// A step of the first-start setup. The sign-in comes before these steps.
enum SetupStep: Equatable {
    case rosetta
    case runtime        // The Game Porting Toolkit (it also gives D3DMetal to the other runtimes)
    case wineRuntime    // Optional: the Wine 11 runtime (RuntimeDownload.catalog[0])
    case vcRuntime      // Optional, recommended: Microsoft's Visual C++ runtime

    /// The name in the step bar.
    var title: String {
        switch self {
        case .rosetta: return "Rosetta"
        case .runtime: return "Game Porting Toolkit"
        case .wineRuntime: return "Wine 11 runtime"
        case .vcRuntime: return "Visual C++"
        }
    }

    /// The optional steps have Skip in place of Not now.
    var isOptional: Bool { self == .wineRuntime || self == .vcRuntime }
}

/// The focusable items of the setup screen, in focus order.
enum SetupItem: Equatable {
    case installRosetta
    case checkRosetta
    case openLicense            // Opens Apple's license PDF in the browser
    case license
    case useExisting(Int)       // Index in SetupFlow.existing
    case download
    case cancel
    case notNow
    case install                // Optional steps: install the item of the step
    case skip                   // Optional steps: go to the next step
}

/// The state of the setup screen after the sign-in: Rosetta, then the game
/// runtime, then the library. Steps that are done do not show.
struct SetupFlow: Equatable {
    enum RuntimeStage: Equatable {
        case choose
        case downloading(done: Int64, total: Int64)
        case verifying
        case extracting
        case copying
    }

    var steps: [SetupStep]
    var index = 0
    var focus = 0
    var rosetta: RosettaStatus
    var rosettaBusy = false
    var licenseAccepted = false
    var existing: [ExistingGPTK] = []
    var runtime: RuntimeStage = .choose
    var error: String?
    /// The runtime of the Wine 11 step, and whether its install can start (it needs GPTK).
    var wineDownload: RuntimeDownload?
    var wineReady = true
    /// The Visual C++ step: true when a game prefix exists, so that the install starts now.
    var vcInstallsNow = false

    var step: SetupStep? { index < steps.count ? steps[index] : nil }

    /// The steps that are still to do. On an Intel Mac, the runtime step stays,
    /// so that the screen can tell why games do not start.
    /// The optional steps show only when `wineRuntime` or `vcRuntime` is true,
    /// and never on an Intel Mac.
    static func steps(rosetta: RosettaStatus, runtimeInstalled: Bool,
                      wineRuntime: Bool = false, vcRuntime: Bool = false) -> [SetupStep] {
        var list: [SetupStep] = []
        if rosetta == .missing { list.append(.rosetta) }
        if !runtimeInstalled || rosetta == .notAppleSilicon { list.append(.runtime) }
        guard rosetta != .notAppleSilicon else { return list }
        if wineRuntime { list.append(.wineRuntime) }
        if vcRuntime { list.append(.vcRuntime) }
        return list
    }

    var items: [SetupItem] {
        switch step {
        case .rosetta:
            return rosettaBusy ? [] : [.installRosetta, .checkRosetta, .notNow]
        case .runtime:
            if rosetta == .notAppleSilicon { return [.notNow] }
            switch runtime {
            case .choose:
                let copies = existing.indices.filter { existing[$0].matches }.map { SetupItem.useExisting($0) }
                return [.openLicense, .license] + copies + [.download, .notNow]
            case .downloading: return [.cancel]
            case .verifying, .extracting, .copying: return []
            }
        case .wineRuntime:
            switch runtime {
            case .choose: return wineReady ? [.install, .skip] : [.skip]
            case .downloading: return [.cancel]
            case .verifying, .extracting, .copying: return []
            }
        case .vcRuntime:
            return [.install, .skip]
        case nil:
            return []
        }
    }

    var focusedItem: SetupItem? {
        let list = items
        return list.indices.contains(focus) ? list[focus] : nil
    }
}

extension AppModel {
    private static let postponedKey = "setupPostponed"
    /// The optional steps that the user skipped. The setup does not show them again.
    static let skippedWineKey = "setupSkippedWineRuntime"
    static let skippedVCKey = "setupSkippedVCRuntime"

    var setupRoot: URL { setupRootOverride ?? GameRuntime.standard.root }

    /// Opens the setup at the start when a step is left, unless the user chose
    /// "Not now" before. Play opens it again when the runtime is missing.
    func checkSetupAtStart() {
        guard !UserDefaults.standard.bool(forKey: Self.postponedKey) else { return }
        openSetup(optional: true)
    }

    /// Opens the setup with the steps that are still to do. Returns false when nothing is left.
    /// `optional` adds the Wine 11 and Visual C++ steps (at the start, not from Play).
    @discardableResult
    func openSetup(rosetta: RosettaStatus = RosettaStatus.detect(), optional: Bool = false) -> Bool {
        let release = GPTKRelease.pinned
        let defaults = UserDefaults.standard
        let wine = optional && !demo ? RuntimeDownload.catalog.first : nil
        let wineWanted = wine.map { download in
            !defaults.bool(forKey: Self.skippedWineKey)
                && !RuntimeCatalog.discover().contains { $0.id == download.id }
        } ?? false
        let vcWanted = optional && !demo && !AppSettings.vcRuntimeWanted && !defaults.bool(forKey: Self.skippedVCKey)
        let steps = SetupFlow.steps(rosetta: rosetta, runtimeInstalled: release.isInstalled(in: setupRoot),
                                    wineRuntime: wineWanted, vcRuntime: vcWanted)
        guard !steps.isEmpty else {
            setup = nil
            return false
        }
        var flow = SetupFlow(steps: steps, rosetta: rosetta)
        flow.wineDownload = wine
        flow.existing = RuntimeSetup.findExisting(in: RuntimeSetup.candidates())
        setup = flow
        return true
    }

    // MARK: Input

    func moveSetup(_ direction: Direction) {
        guard var flow = setup else { return }
        let count = flow.items.count
        guard count > 0 else { return }
        switch direction {
        case .up, .left: flow.focus = max(0, flow.focus - 1)
        case .down, .right: flow.focus = min(count - 1, flow.focus + 1)
        }
        setup = flow
    }

    func tapSetup(_ item: SetupItem) {
        guard let index = setup?.items.firstIndex(of: item) else { return }
        setup?.focus = index
        confirmSetup()
    }

    func confirmSetup() {
        guard let flow = setup, let item = flow.focusedItem else { return }
        setup?.error = nil
        switch item {
        case .installRosetta: installRosetta()
        case .checkRosetta: checkRosetta(announce: true)
        case .openLicense: NSWorkspace.shared.open(GPTKRelease.licenseURL)
        case .license: setup?.licenseAccepted.toggle()
        case .useExisting(let index):
            guard requireLicense() else { return }
            copyExistingRuntime(flow.existing[index])
        case .download:
            guard requireLicense() else { return }
            downloadRuntime()
        case .cancel:
            setupTask?.cancel()
        case .notNow:
            if flow.step == .runtime {
                // The other runtimes need D3DMetal from the toolkit, so the setup stops here.
                UserDefaults.standard.set(true, forKey: Self.postponedKey)
                setup?.steps = Array(flow.steps.prefix(flow.index + 1))
            }
            advanceSetup()
        case .install:
            if flow.step == .wineRuntime { downloadWineRuntime() }
            if flow.step == .vcRuntime {
                installVCRuntime()
                advanceSetup()
            }
        case .skip:
            if flow.step == .wineRuntime { UserDefaults.standard.set(true, forKey: Self.skippedWineKey) }
            if flow.step == .vcRuntime { UserDefaults.standard.set(true, forKey: Self.skippedVCKey) }
            advanceSetup()
        }
    }

    private func requireLicense() -> Bool {
        guard setup?.licenseAccepted == true else {
            setup?.error = "Accept the license before you continue."
            setup?.focus = setup?.items.firstIndex(of: .license) ?? 0
            return false
        }
        return true
    }

    /// The next step, or the library after the last step.
    func advanceSetup() {
        guard var flow = setup else { return }
        flow.index += 1
        flow.focus = 0
        flow.error = nil
        prepareStep(&flow)
        if flow.step == nil {
            setup = nil
            setupTask = nil
            if GPTKRelease.pinned.isInstalled(in: setupRoot) && RosettaStatus.detect() != .missing {
                UserDefaults.standard.removeObject(forKey: Self.postponedKey)
                showToast("The setup is complete. You can play your installed games now.", seconds: 5)
            }
        } else {
            setup = flow
        }
    }

    // MARK: Rosetta

    private func installRosetta() {
        setup?.rosettaBusy = true
        setupTask = Task {
            do {
                try await RosettaStatus.install()
                setup?.rosettaBusy = false
                checkRosetta(announce: true)
            } catch {
                setup?.rosettaBusy = false
                setup?.error = "Rosetta was not installed. \(error.localizedDescription)"
            }
        }
    }

    private func checkRosetta(announce: Bool) {
        let status = RosettaStatus.detect()
        setup?.rosetta = status
        if status == .installed {
            advanceSetup()
        } else if announce {
            setup?.error = "Rosetta is still missing."
        }
    }

    // MARK: Game runtime

    private func downloadRuntime() {
        let release = GPTKRelease.pinned
        let root = setupRoot
        let archive = root.appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent("\(release.folder).tar.xz")
        setup?.runtime = .downloading(done: 0, total: release.size)
        setup?.focus = 0
        setupTask = Task {
            do {
                try RuntimeSetup.checkSpace(for: release, at: root)
                try await RuntimeSetup.download(release, to: archive) { done, total in
                    Task { @MainActor in
                        guard case .downloading = self.setup?.runtime else { return }
                        self.setup?.runtime = .downloading(done: done, total: total)
                    }
                }
                try Task.checkCancellation()
                setup?.runtime = .verifying
                try await Task.detached {
                    do {
                        try RuntimeSetup.verify(archive, sha256: release.sha256)
                    } catch {
                        try? FileManager.default.removeItem(at: archive)
                        throw error
                    }
                }.value
                setup?.runtime = .extracting
                try await Task.detached { try RuntimeSetup.extract(archive: archive, release: release, into: root) }.value
                try? FileManager.default.removeItem(at: archive)
                runtimeInstalled()
            } catch {
                runtimeFailed(error)
            }
        }
    }

    private func copyExistingRuntime(_ existing: ExistingGPTK) {
        let release = GPTKRelease.pinned
        let root = setupRoot
        setup?.runtime = .copying
        setupTask = Task {
            do {
                try await Task.detached { try RuntimeSetup.copyExisting(existing, release: release, into: root) }.value
                runtimeInstalled()
            } catch {
                runtimeFailed(error)
            }
        }
    }

    /// Reads the state that a step needs when it shows.
    private func prepareStep(_ flow: inout SetupFlow) {
        switch flow.step {
        case .wineRuntime: flow.wineReady = gptkHasD3DMetal || setupRootOverride != nil
        case .vcRuntime: flow.vcInstallsNow = vcRuntimeCount.total > 0
        default: break
        }
    }

    // MARK: Wine 11 runtime

    private func downloadWineRuntime() {
        guard let download = setup?.wineDownload else { return }
        setup?.runtime = .downloading(done: 0, total: download.size)
        setup?.focus = 0
        setupTask = Task {
            do {
                try await fetchRuntime(download, progress: { done, total in
                    guard case .downloading = self.setup?.runtime else { return }
                    self.setup?.runtime = .downloading(done: done, total: total > 0 ? total : download.size)
                }, installing: { self.setup?.runtime = .extracting })
                // The setup offers this runtime for most games, so it becomes the default.
                runtimeChoice.defaultID = download.id
                runtimeInstalled()
            } catch {
                runtimeFailed(error)
            }
        }
    }

    private func runtimeInstalled() {
        setup?.runtime = .choose
        objectWillChange.send()
        advanceSetup()
    }

    private func runtimeFailed(_ error: Error) {
        setup?.runtime = .choose
        setup?.focus = 0
        // A cancel is the user's choice, not an error.
        if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
        setup?.error = error.localizedDescription
    }
}
