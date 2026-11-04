import Foundation

/// The signal file of the iOdus winhttp proxy. The proxy adds one line when a
/// game opens an achievement update request to Xbox Live. The file is only a
/// hint: iOdus shows an unlock only after Xbox Live lists it as unlocked.
enum AchievementSignal {
    static func files(prefix: URL) -> [URL] {
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        return names.map {
            users.appendingPathComponent($0).appendingPathComponent("AppData/Local/iOdus/achievement-signal")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The sum of the file sizes. The proxy only adds lines, so a new request
    /// changes the value.
    static func stamp(prefix: URL) -> Int64 {
        files(prefix: prefix).reduce(0) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return sum + (size ?? 0)
        }
    }
}

/// Watches the achievements of one title while its game runs.
/// 1. At the start, it reads the list. The unlocked achievements are the baseline.
/// 2. When the proxy signal changes, it reads the list again (after 3 s, and
///    after 12 s more if nothing is new yet).
/// 3. Without a signal, it reads the list every `fallback` seconds.
/// 4. At the stop, it reads the list one last time.
/// It only reads from Xbox Live. Each new unlock goes to `onUnlock` one time.
@MainActor
final class AchievementWatcher {
    typealias Reader = @MainActor () async throws -> AchievementList

    let titleId: String
    private let read: Reader
    private let stamp: () -> Int64
    private let onUnlock: ([Achievement]) -> Void
    /// The IDs of the unlocked achievements; nil until the first read works.
    private(set) var known: Set<String>?
    /// The IDs that went to `onUnlock`.
    private(set) var announced: Set<String> = []
    private var loop: Task<Void, Never>?
    private var checking = false

    init(titleId: String, read: @escaping Reader, stamp: @escaping () -> Int64,
         onUnlock: @escaping ([Achievement]) -> Void) {
        self.titleId = titleId
        self.read = read
        self.stamp = stamp
        self.onUnlock = onUnlock
    }

    func start(poll: Duration = .seconds(2), retries: [Duration] = [.seconds(3), .seconds(12)],
               fallback: TimeInterval = 300) {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let first = self else { return }
            var last = first.stamp()
            await first.check()
            var lastRead = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard let self, !Task.isCancelled else { return }
                let now = self.stamp()
                if now != last {
                    last = now
                    // The request is open, not complete. Xbox Live can also show
                    // the unlock some seconds later.
                    for delay in retries {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled || self.loop == nil { return }
                        if await self.check() > 0 { break }
                    }
                    lastRead = Date()
                } else if Date().timeIntervalSince(lastRead) >= fallback {
                    await self.check()
                    lastRead = Date()
                }
            }
        }
    }

    /// Stops the loop and reads the list one last time.
    func stop() async {
        loop?.cancel()
        loop = nil
        await check()
    }

    /// Reads the list and announces the new unlocks. Returns their count.
    @discardableResult
    func check() async -> Int {
        guard !checking else { return 0 }
        checking = true
        defer { checking = false }
        guard let list = try? await read(), list.titleId == titleId else { return 0 }
        let new = Self.newUnlocks(known: known, list: list)
        known = (known ?? []).union(list.items.filter(\.isUnlocked).map(\.id))
        guard !new.isEmpty else { return 0 }
        announced.formUnion(new.map(\.id))
        onUnlock(new)
        return new.count
    }

    /// The unlocked achievements that are not in `known`. Without a baseline,
    /// nothing is new: an unlock from an earlier session must not show.
    static func newUnlocks(known: Set<String>?, list: AchievementList) -> [Achievement] {
        guard let known else { return [] }
        return list.items.filter { $0.isUnlocked && !known.contains($0.id) }
    }
}

extension AppModel {
    /// Starts the watcher for a game that has a title ID. Not in demo mode.
    func startAchievementWatcher(for game: Game) {
        achievementWatcher?.cancel()
        achievementWatcher = nil
        guard !demo, let titleId = game.titleId, let cli = backendCLI else { return }
        let prefix = savePrefix(for: game)
        let title = game.title
        let watcher = AchievementWatcher(
            titleId: titleId,
            read: { try await cli.achievements(titleId: titleId) },
            stamp: { AchievementSignal.stamp(prefix: prefix) },
            onUnlock: { [weak self] items in self?.announceUnlocks(items, titleId: titleId, gameTitle: title) })
        achievementWatcher = watcher
        watcher.start()
    }

    /// A popup over the game, and one notification for each unlock.
    func announceUnlocks(_ items: [Achievement], titleId: String, gameTitle: String) {
        for item in items {
            AchievementPopup.shared.show(AchievementPopupView(name: item.name, gamerscore: item.gamerscore,
                                                              game: gameTitle, icon: item.icon))
            notify(AppNotification(date: Date(), kind: .achievements, title: "Achievement unlocked: \(item.name)",
                                   detail: "\(item.gamerscore) G · \(gameTitle)", action: .openAchievements(titleId)))
        }
        // The next visit to the achievement page reads the new state.
        achievementLists[titleId] = nil
    }
}

extension AchievementWatcher {
    /// Stops the loop without the last read.
    func cancel() {
        loop?.cancel()
        loop = nil
    }
}
