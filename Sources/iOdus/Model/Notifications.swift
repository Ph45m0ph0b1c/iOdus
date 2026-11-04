import AppKit
import Foundation

/// One item in the notification hub.
struct AppNotification: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case installed, downloadFailed, achievements, update, message, info }
    enum Action: Codable, Equatable {
        case openGame(String)           // product ID
        case openDownloads
        case openAchievements(String)   // Xbox title ID
        case openConversation(String)   // XUID
        case openURL(String)
        case openUpdate                 // Settings > Updates
        case none
    }

    var id = UUID()
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    var action: Action = .none
    var read = false

    var symbol: String {
        switch kind {
        case .installed: return "checkmark.circle.fill"
        case .downloadFailed: return "exclamationmark.triangle.fill"
        case .achievements: return "trophy.fill"
        case .update: return "arrow.down.app.fill"
        case .message: return "bubble.left.fill"
        case .info: return "info.circle.fill"
        }
    }
}

/// The notifications, newest first. The last 50 stay saved after a restart.
struct NotificationStore {
    static let limit = 50
    private(set) var items: [AppNotification] = []
    let file: URL

    static var standardFile: URL { GameRuntime.support.appendingPathComponent("notifications.json") }

    init(file: URL = NotificationStore.standardFile) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([AppNotification].self, from: data) {
            items = saved
        }
    }

    var unread: Int { items.filter { !$0.read }.count }

    mutating func add(_ item: AppNotification) {
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    mutating func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        for i in items.indices { items[i].read = true }
        save()
    }

    mutating func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: file, options: .atomic) }
    }
}

extension AppModel {
    // MARK: Updates

    /// Checks for a new iOdus release now, and then every hour when the last
    /// check is older than one day.
    func startUpdateChecks() {
        guard updateTimer == nil, !demo else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                _ = Task { await AppModel.shared.checkForUpdates(force: false) }
            }
        }
        Task { await checkForUpdates(force: true) }
    }

    func checkForUpdates(force: Bool) async {
        guard !demo else { return }
        let item = await updateChecker.check(force: force)
        refreshUpdateState()
        guard let item else { return }
        notify(item)
        showToast(item.title, seconds: 5)
    }

    /// The Check now row: checks also when the automatic check is off.
    func checkForUpdatesNow() {
        guard !demo, !appUpdate.isBusy else { return }
        appUpdate = .checking
        Task {
            if let item = await updateChecker.check(force: true, manual: true) { notify(item) }
            refreshUpdateState(afterManualCheck: true)
        }
    }

    /// The update row shows the release that the last check found.
    func refreshUpdateState(afterManualCheck: Bool = false) {
        guard !appUpdate.isBusy || appUpdate == .checking else { return }
        if let release = updateChecker.available {
            appUpdate = .available(release.version)
        } else if afterManualCheck {
            appUpdate = .upToDate
        } else if appUpdate == .checking {
            appUpdate = .idle
        }
    }

    /// Settings > Updates, with the focus on the update row.
    func openUpdateSettings() {
        statusPanel = nil
        settingsCategory = SettingsCategory.updates.rawValue
        settingsFocus = .rows
        settingsIndex = 0
        if screen != .settings { stack.append(.settings) }
    }

    /// Downloads, checks, and installs the release that the last check found,
    /// then restarts iOdus. See AppUpdater for the checks.
    func installAppUpdate() {
        guard case .available(let version) = appUpdate, let release = updateChecker.available,
              release.version == version else { return }
        let downloading = downloads.tasks.contains { $0.status == .running || $0.status == .queued }
        if let reason = AppUpdater.blockReason(playing: playState != .idle, downloading: downloading) {
            showToast(reason, seconds: 5)
            return
        }
        let current = Bundle.main.bundleURL
        do {
            guard let asset = release.appArchive else { throw AppUpdateError.noArchive }
            guard let team = AppUpdater.runningTeamID() else { throw AppUpdateError.noTeam }
            try AppUpdater.checkReplaceable(current)
            let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iOdus/Updates/\(version)")
            appUpdate = .downloading(version, 0)
            Task {
                do {
                    let zip = try await AppUpdater.download(asset, into: folder) { fraction in
                        Task { @MainActor in
                            if case .downloading = AppModel.shared.appUpdate {
                                AppModel.shared.appUpdate = .downloading(version, fraction)
                            }
                        }
                    }
                    appUpdate = .verifying(version)
                    let app = try await Task.detached {
                        try AppUpdater.prepare(zip: zip, asset: asset, version: version, team: team, into: folder)
                    }.value
                    // A game can start during the download.
                    guard playState == .idle else {
                        appUpdate = .available(version)
                        showToast("Stop the game first. iOdus restarts for the update.", seconds: 5)
                        return
                    }
                    appUpdate = .installing(version)
                    try AppUpdater.install(app, replacing: current)
                    try? FileManager.default.removeItem(at: folder)
                    AppUpdater.relaunch(current)
                    NSApp.terminate(nil)
                } catch {
                    appUpdate = .failed(version, error.localizedDescription)
                }
            }
        } catch {
            appUpdate = .failed(version, error.localizedDescription)
        }
    }

    /// The release page on GitHub: the new version when the last check found
    /// one, else the version that runs, else the latest release.
    func openReleasePage() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    var releasePageURL: String {
        if let release = updateChecker.available { return release.htmlURL }
        let releases = "https://github.com/\(updateChecker.repository)/releases"
        if let current = UpdateCheck.currentVersion { return "\(releases)/tag/v\(current)" }
        return "\(releases)/latest"
    }

    func notify(_ item: AppNotification) {
        notificationStore.add(item)
        notifications = notificationStore.items
    }

    func openNotifications() {
        notificationIndex = 0
        statusPanel = .notifications
        notificationStore.markAllRead()
        notifications = notificationStore.items
    }

    func clearNotifications() {
        notificationStore.clear()
        notifications = []
        notificationIndex = 0
    }

    func moveNotifications(_ d: Direction) {
        switch d {
        case .up: notificationIndex = max(0, notificationIndex - 1)
        case .down: notificationIndex = min(max(0, min(notifications.count, 6) - 1), notificationIndex + 1)
        default: break
        }
    }

    /// A on a notification: do its action and close the panel.
    func openNotification(_ index: Int) {
        guard index < notifications.count else { return }
        let item = notifications[index]
        statusPanel = nil
        // An update notification opens Settings > Updates, also an old one
        // that still has the link to the release page.
        if item.kind == .update {
            openUpdateSettings()
            return
        }
        switch item.action {
        case .openGame(let id):
            if game(id) != nil { home(); openDetail(id) }
        case .openDownloads:
            home(); open(shortcut: shortcuts.first { $0.id == "downloads" }!)
        case .openAchievements(let titleId):
            home()
            let game = libraryGame(titleId: titleId)
            let name = game?.title ?? titleHistory.first { $0.titleId == titleId }?.name ?? "Achievements"
            achievementTitles[titleId] = AchievementTitle(titleId: titleId, name: name, art: game?.tileArt, gameID: game?.id)
            achievementIndex = 0
            showSecrets = false
            stack.append(.achievements(titleId))
            Task { await loadAchievements(titleId: titleId, force: true) }
        case .openConversation(let xuid):
            home()
            stack.append(.messages)
            Task { await loadInbox(notify: false) }
            openConversation(with: xuid)
        case .openURL(let text):
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .openUpdate:
            openUpdateSettings()
        case .none:
            break
        }
    }

    // MARK: Sources

    func downloadFinished(_ task: DownloadTask) {
        if task.status == .complete {
            notify(AppNotification(date: Date(), kind: .installed, title: "\(task.title) is installed",
                                   detail: "Select it to play.", action: .openGame(task.id)))
        } else {
            notify(AppNotification(date: Date(), kind: .downloadFailed, title: "The download of \(task.title) failed",
                                   detail: task.error ?? "Open Downloads to try again.", action: .openDownloads))
        }
    }

    /// After a game stops: compare the achievements of its title with the count before the start.
    /// `announced` unlocks already had a popup and a notification.
    func checkNewAchievements(gameID: String, before: PlayedTitle?, announced: Int = 0) async {
        guard let titleId = game(gameID)?.titleId else { return }
        historyLoadedAt = nil
        await loadHistory(force: true)
        guard let after = titleHistory.first(where: { $0.titleId == titleId }) else { return }
        let unlocked = (after.achievementsUnlocked ?? 0) - (before?.achievementsUnlocked ?? 0)
        let score = (after.currentGamerscore ?? 0) - (before?.currentGamerscore ?? 0)
        let rest = unlocked - announced
        if rest > 0 || (announced == 0 && score > 0) {
            let count = max(rest, 1)
            let more = announced > 0 ? " more" : ""
            notify(AppNotification(date: Date(), kind: .achievements,
                                   title: "You unlocked \(count)\(more) achievement\(count == 1 ? "" : "s") in \(after.name)",
                                   detail: score > 0 ? "+\(score) gamerscore" : "Select it to see the list.",
                                   action: .openAchievements(titleId)))
        }
        guard unlocked > 0 || score > 0 else { return }
        if !accountName.isEmpty, let cli = backendCLI, let me = try? await cli.playerProfile(account: accountName) {
            gamerscore = me.gamerscoreValue
        }
    }
}
