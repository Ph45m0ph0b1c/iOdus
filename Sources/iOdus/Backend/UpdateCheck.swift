import Foundation

/// One release from the GitHub releases API.
struct ReleaseInfo: Decodable, Equatable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", draft, prerelease
    }

    /// "v0.2.0" -> "0.2.0"
    var version: String { tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName }
}

/// Finds a new iOdus release on GitHub. It only tells the player: it does not
/// download or install anything.
enum UpdateCheck {
    /// The GitHub repository "owner/name". The Info.plist key IOdusUpdateRepository
    /// replaces the default.
    static let defaultRepository = "burghr/iOdus"
    static let repositoryKey = "IOdusUpdateRepository"

    static var repository: String {
        (Bundle.main.object(forInfoDictionaryKey: repositoryKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultRepository
    }

    /// The version of this build, or nil for a `swift build` binary (no Info.plist).
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func releasesURL(_ repository: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20")
    }

    /// Compares two versions part by part as numbers: "0.10.0" > "0.9.1".
    /// A suffix after "-" or "+" is ignored. A missing part counts as 0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ text: String) -> [Int] {
            var core = text.hasPrefix("v") || text.hasPrefix("V") ? String(text.dropFirst()) : text
            if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
            return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The newest release that is not a draft and not a pre-release.
    static func newest(_ releases: [ReleaseInfo]) -> ReleaseInfo? {
        releases.filter { !$0.draft && !$0.prerelease }
            .max { compare($0.version, $1.version) == .orderedAscending }
    }
}

/// Checks for a new release at the start and then once a day. It stores the time
/// of the last check and the last version that it announced, so that one version
/// gives one notification.
@MainActor
final class UpdateChecker {
    /// Returns the body and the HTTP status of a GET request.
    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    static let enabledKey = "checkForUpdates"
    static let lastCheckKey = "updateLastCheck"
    static let announcedKey = "updateAnnouncedVersion"
    static let interval: TimeInterval = 24 * 60 * 60

    let repository: String
    let currentVersion: String?
    private let defaults: UserDefaults
    private let fetch: Fetch
    private let now: () -> Date

    init(repository: String = UpdateCheck.repository, currentVersion: String? = UpdateCheck.currentVersion,
         defaults: UserDefaults = .standard, fetch: @escaping Fetch = UpdateChecker.network,
         now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
    }

    /// The check is on by default.
    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var isDue: Bool {
        guard let last = defaults.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.interval
    }

    /// Reads the releases when the check is on and due (or with `force`). Returns
    /// a notification for a new version that was not announced before, else nil.
    /// Errors (no network, no repository: 404, rate limit) give nil without a message.
    func check(force: Bool = false) async -> AppNotification? {
        guard enabled, let current = currentVersion, force || isDue,
              let url = UpdateCheck.releasesURL(repository) else { return nil }
        defaults.set(now(), forKey: Self.lastCheckKey)
        guard let (data, status) = try? await fetch(url), status == 200,
              let releases = try? JSONDecoder().decode([ReleaseInfo].self, from: data),
              let newest = UpdateCheck.newest(releases),
              UpdateCheck.compare(newest.version, current) == .orderedDescending else { return nil }
        if let announced = defaults.string(forKey: Self.announcedKey),
           UpdateCheck.compare(newest.version, announced) != .orderedDescending { return nil }
        defaults.set(newest.version, forKey: Self.announcedKey)
        return AppNotification(date: now(), kind: .update, title: "iOdus \(newest.version) is available",
                               detail: "You have version \(current). Select to open the release page.",
                               action: .openURL(newest.htmlURL))
    }

    nonisolated static let network: Fetch = { url in
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iOdus", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
