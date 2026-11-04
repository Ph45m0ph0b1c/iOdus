import Foundation

/// One friend from `xodus-cli native-social friends`.
struct Friend: Decodable, Identifiable, Equatable {
    let xuid: String
    let gamertag: String
    let online: Bool
    let presence: String
    let avatarUrl: String?
    let favorite: Bool
    let inParty: Bool

    var id: String { xuid }

    var avatar: URL? {
        guard let avatarUrl, let url = URL(string: avatarUrl), url.scheme == "https" else { return nil }
        return url
    }

    /// Online friends first, then favorites, then by name.
    static func sorted(_ list: [Friend]) -> [Friend] {
        list.sorted { a, b in
            if a.online != b.online { return a.online }
            if a.favorite != b.favorite { return a.favorite }
            return a.gamertag.localizedCaseInsensitiveCompare(b.gamertag) == .orderedAscending
        }
    }
}

/// A profile from `native-social people` with the `profile` operation.
struct PlayerProfile: Decodable, Equatable {
    struct Counts: Decodable, Equatable {
        let friends: Int?
        let followers: Int?
        let following: Int?
    }

    let xuid: String
    let gamertag: String
    let gamerscore: String?
    let online: Bool?
    let presence: String?
    let avatarUrl: String?
    let bio: String?
    let location: String?
    let tenure: String?
    let counts: Counts?

    var gamerscoreValue: Int? { gamerscore.flatMap(Int.init) }
}

private struct FriendsResponse: Decodable {
    let schema: Int
    let kind: String
    let account: String
    let items: [Friend]
}

private struct PeopleEnvelope<T: Decodable>: Decodable {
    let schema: Int
    let kind: String
    let account: String
    let result: T
}

extension XodusCLI {
    func friends() async throws -> [Friend] {
        let response = try await json(FriendsResponse.self, ["native-social", "friends"], timeout: 60)
        guard response.schema == 1 else { throw BackendError.invalidResponse("Unknown friends list format.") }
        return response.items
    }

    /// The profile of `xuid`, or of the signed-in player with "me".
    func playerProfile(account: String, xuid: String = "me") async throws -> PlayerProfile {
        let request = try JSONSerialization.data(withJSONObject: ["account": account, "operation": "profile", "xuid": xuid])
        let response = try await json(PeopleEnvelope<PlayerProfile>.self, ["native-social", "people"],
                                      input: request, timeout: 60)
        guard response.schema == 1, response.kind == "people", response.account == account else {
            throw BackendError.invalidResponse("The profile is for a different account.")
        }
        return response.result
    }
}

extension Int {
    /// 48215 -> "48,215"
    var grouped: String { formatted(.number.grouping(.automatic)) }
}

/// One achievement from `xodus-cli achievements <title id> --json`.
struct Achievement: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let gamerscore: Int
    let iconUrl: String?
    let state: String           // "locked", "unlocked", or "in-progress"
    let progress: Double?       // 0...1
    let secret: Bool
    let revoked: Bool
    let unlockedAt: String?

    var isUnlocked: Bool { state == "unlocked" }
    var inProgress: Bool { state == "in-progress" }
    var unlockedDate: Date? { unlockedAt.flatMap(LibraryRules.parseDate) }

    var icon: URL? {
        guard let iconUrl, let url = URL(string: iconUrl), url.scheme == "https" else { return nil }
        return url
    }

    /// Unlocked first (newest first), then in progress (most progress first), then locked.
    static func sorted(_ list: [Achievement]) -> [Achievement] {
        func rank(_ a: Achievement) -> Int { a.isUnlocked ? 0 : (a.inProgress ? 1 : 2) }
        return list.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.isUnlocked, let da = a.unlockedDate, let db = b.unlockedDate, da != db { return da > db }
            if a.inProgress, (a.progress ?? 0) != (b.progress ?? 0) { return (a.progress ?? 0) > (b.progress ?? 0) }
            return x.offset < y.offset
        }.map(\.element)
    }
}

struct AchievementList: Decodable, Equatable {
    let titleId: String
    let partial: Bool
    let items: [Achievement]

    var unlocked: Int { items.filter(\.isUnlocked).count }
    var earnedScore: Int { items.filter(\.isUnlocked).reduce(0) { $0 + $1.gamerscore } }
    var totalScore: Int { items.reduce(0) { $0 + $1.gamerscore } }
}

private struct AchievementResponse: Decodable {
    let schema: Int
    let titleId: String
    let partial: Bool
    let items: [Achievement]
}

extension XodusCLI {
    /// Reads the achievements of one title. This only reads; nothing unlocks.
    func achievements(titleId: String) async throws -> AchievementList {
        guard let number = UInt32(titleId), number > 0 else { throw BackendError.failed("The game has no Xbox title ID.") }
        let response = try await json(AchievementResponse.self, ["achievements", String(number), "--json"], timeout: 60)
        guard response.schema == 1, response.titleId == String(number) else {
            throw BackendError.invalidResponse("The achievement list is for a different title.")
        }
        return AchievementList(titleId: response.titleId, partial: response.partial,
                               items: Achievement.sorted(response.items.filter { !$0.revoked }))
    }
}
