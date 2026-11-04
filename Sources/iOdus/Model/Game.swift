import SwiftUI

enum InstallState: Hashable {
    case installed
    case notInstalled
    case downloading(progress: Double)
}

struct Game: Identifiable, Hashable {
    let id: String          // Store product ID
    let title: String
    let publisher: String
    var tileArt: URL? = nil
    var heroArt: URL? = nil
    var access: Access = .owned
    var installState: InstallState = .notInstalled
    var titleId: String? = nil          // Xbox title ID
    var lastPlayed: Date? = nil         // From the Xbox title history
    var gamerscore: (current: Int, total: Int)? = nil
    var launcher: String? = nil         // Set when only a publisher launcher can install the game

    /// Placeholder colors from the product ID, so that each game keeps its colors.
    var artColors: [Color] {
        let palette: [Color] = [.teal, .indigo, .orange, .red, .pink, .purple, .blue, .cyan, .mint, .green, .brown]
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return [palette[hash % palette.count], palette[(hash / 7) % palette.count].opacity(0.8)]
    }

    static func == (a: Game, b: Game) -> Bool {
        a.id == b.id && a.installState == b.installState && a.tileArt == b.tileArt
            && a.lastPlayed == b.lastPlayed && a.gamerscore?.current == b.gamerscore?.current
    }

    func hash(into h: inout Hasher) { h.combine(id) }
}

struct Shortcut: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String

    static let all: [Shortcut] = [
        Shortcut(id: "library", title: "My games & apps", symbol: "square.grid.2x2.fill"),
        Shortcut(id: "store", title: "Store", symbol: "bag.fill"),
        Shortcut(id: "downloads", title: "Downloads", symbol: "arrow.down.circle.fill"),
        Shortcut(id: "achievements", title: "Achievements", symbol: "trophy.fill"),
        Shortcut(id: "social", title: "Social", symbol: "person.2.fill"),
        Shortcut(id: "settings", title: "Settings", symbol: "gearshape.fill"),
    ]
}

/// Sample data for `--demo` and for snapshots.
enum MockLibrary {
    /// Demo backups. The folders do not exist; demo mode does not restore or delete.
    static func saveBackups(titleId: String) -> [SaveBackup] {
        let root = URL(fileURLWithPath: "/demo/SaveBackups")
        return [(2, 41_200), (26, 39_880), (24 * 9, 12_400)].map { hours, bytes in
            let date = Date().addingTimeInterval(-Double(hours) * 3600)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return SaveBackup(url: root.appendingPathComponent("\(titleId)-\(formatter.string(from: date))"),
                              titleId: titleId, date: date, accounts: ["2533274800000001"], bytes: Int64(bytes))
        }
    }

    static let games: [Game] = [
        game("9P0000000001", "Harbor Lights", "Northwind Studio", .installed),
        game("9P0000000002", "Iron Meridian", "Forge Nine", .installed),
        game("9P0000000003", "Paper Comets", "Kite Games", .downloading(progress: 0.42)),
        game("9P0000000004", "Quiet Orbit", "Low Earth", .notInstalled),
        game("9P0000000005", "Salt & Signal", "Brine Works", .installed),
        game("9P0000000006", "Northbound", "Ridge Line", .notInstalled),
        game("9P0000000007", "Ember Drift", "Coalfire", .installed),
        game("9P0000000008", "Glass Canyon", "Prism House", .notInstalled),
        game("9P0000000009", "Lantern Keep", "Moth & Flame", .installed),
        game("9P0000000010", "Tidewater", "Shoal", .notInstalled),
        game("9P0000000011", "Velvet Circuit", "Neon Loom", .installed),
        game("9P0000000012", "Ashfall Run", "Cinder Co.", .notInstalled),
    ]

    static let friends: [Friend] = [
        friend("2533274800000001", "NorthwindNova", true, "Playing Harbor Lights", favorite: true),
        friend("2533274800000002", "KiteRunner42", true, "Home"),
        friend("2533274800000003", "BrineWorks", false, "Last seen 2h ago: Salt & Signal"),
        friend("2533274800000004", "Coalfire", false, "Last seen 3d ago: Xbox App", favorite: true),
        friend("2533274800000005", "PrismHouse", false, "Offline"),
    ]

    static let storeRows: [StoreRow] = [
        StoreRow(id: "recent", title: "Recently added to PC Game Pass", items: [
            store("9Q0000000001", "Lumen Drift", "Included", gamePass: true),
            store("9P0000000004", "Quiet Orbit", "Included", gamePass: true),
            store("9Q0000000002", "Copper Harbor", "Included", gamePass: true),
            store("9Q0000000003", "Rift Garden", "Included", gamePass: true),
            store("9Q0000000004", "Stone & Sail", "Included", gamePass: true),
            store("9Q0000000005", "Night Ferry", "Included", gamePass: true),
            store("9Q0000000006", "Arc Light", "Included", gamePass: true),
        ]),
        StoreRow(id: "trending", title: "Trending games", items: [
            store("9Q0000000011", "Iron Tide", "$59.99"),
            store("9P0000000006", "Northbound", "Included", gamePass: true),
            store("9Q0000000012", "Pocket Rally", "$19.99"),
            store("9Q0000000013", "Moth & Flame", "Free"),
            store("9Q0000000014", "Glass Garden", "$29.99"),
            store("9Q0000000015", "Ember Coast", "$39.99"),
            store("9Q0000000016", "Kite Fields", "$9.99"),
        ]),
    ]

    static let achievements = AchievementList(titleId: "1907796436", partial: false, items: Achievement.sorted([
        achievement("1", "First Light", "Finish the first night at sea.", 20, "unlocked", 1, "2026-10-30T21:10:00Z"),
        achievement("2", "Deep Water", "Catch a fish in the open ocean.", 30, "unlocked", 1, "2026-11-01T19:02:00Z"),
        achievement("3", "Lantern Keeper", "Repair every lighthouse.", 50, "in-progress", 0.4, nil),
        achievement("4", "The Last Light", "Reach the end of the story.", 100, "locked", 0, nil, secret: true),
        achievement("5", "Full Hold", "Fill the hold with fish.", 15, "locked", 0, nil),
        achievement("6", "Night Owl", "Stay at sea until dawn.", 25, "in-progress", 0.75, nil),
    ]))

    static let notifications: [AppNotification] = [
        AppNotification(date: Date().addingTimeInterval(-300), kind: .achievements,
                        title: "You unlocked 2 achievements in Harbor Lights", detail: "+40 gamerscore",
                        action: .openAchievements("1001")),
        AppNotification(date: Date().addingTimeInterval(-3600), kind: .installed,
                        title: "Salt & Signal is installed", detail: "Select it to play.",
                        action: .openGame("9P0000000005")),
        AppNotification(date: Date().addingTimeInterval(-7200), kind: .downloadFailed,
                        title: "The download of Glass Canyon failed", detail: "Not enough free space.",
                        action: .openDownloads, read: true),
    ]

    static let inbox: [InboxItem] = [
        InboxItem(id: "c1", type: "OneToOne", participants: ["2533274800000001"], unread: true,
                  lastMessage: chatMessage("m4", "2533274800000001", "2026-11-02T21:40:00Z", "Want to fish tonight?", mine: false)),
        InboxItem(id: "c2", type: "OneToOne", participants: ["2533274800000002"], unread: false,
                  lastMessage: chatMessage("m9", "me", "2026-11-01T18:10:00Z", "Good game!", mine: true)),
        InboxItem(id: "c3", type: "System", participants: [], unread: false,
                  lastMessage: chatMessage("m10", "0", "2026-10-28T09:00:00Z", "Welcome to Xbox Game Pass.", mine: false)),
    ]

    static let chat: [ChatMessage] = [
        chatMessage("m1", "2533274800000001", "2026-11-02T21:30:00Z", "Did you see the new lighthouse update?", mine: false),
        chatMessage("m2", "me", "2026-11-02T21:32:00Z", "Not yet. Is it good?", mine: true),
        chatMessage("m3", "2533274800000001", "2026-11-02T21:35:00Z", "Very. The night fishing is much harder now.", mine: false),
        chatMessage("m4", "2533274800000001", "2026-11-02T21:40:00Z", "Want to fish tonight?", mine: false),
    ]

    private static func chatMessage(_ id: String, _ sender: String, _ time: String, _ text: String,
                                    mine: Bool) -> ChatMessage {
        ChatMessage(id: id, sender: sender, timestamp: time, text: text, hidden: false, mine: mine)
    }

    static let history: [PlayedTitle] = [
        played("1001", "Harbor Lights", "2026-11-02T20:00:00Z", 460, 1000, 21, 50),
        played("1002", "Salt & Signal", "2026-11-01T18:00:00Z", 1000, 1000, 40, 40),
        played("1003", "Lantern Keep", "2026-10-29T21:30:00Z", 130, 1000, 6, 45),
        played("1004", "Iron Meridian", "2026-10-20T12:00:00Z", 0, 1000, 0, 30),
        played("1005", "An Old Classic", "2025-12-24T09:00:00Z", 200, 200, 12, 12),
    ]

    private static func played(_ id: String, _ name: String, _ date: String, _ score: Int, _ total: Int,
                               _ unlocked: Int, _ count: Int) -> PlayedTitle {
        PlayedTitle(titleId: id, name: name, lastPlayed: date, currentGamerscore: score, totalGamerscore: total,
                    achievementsUnlocked: unlocked, achievementsTotal: count, imageUrl: nil)
    }

    private static func achievement(_ id: String, _ name: String, _ text: String, _ score: Int, _ state: String,
                                    _ progress: Double?, _ date: String?, secret: Bool = false) -> Achievement {
        Achievement(id: id, name: name, description: text, gamerscore: score, iconUrl: nil, state: state,
                    progress: progress, secret: secret, revoked: false, unlockedAt: date)
    }

    private static func friend(_ xuid: String, _ tag: String, _ online: Bool, _ presence: String,
                               favorite: Bool = false) -> Friend {
        Friend(xuid: xuid, gamertag: tag, online: online, presence: presence, avatarUrl: nil,
               favorite: favorite, inParty: false)
    }

    private static func store(_ id: String, _ title: String, _ price: String, gamePass: Bool = false) -> StoreItem {
        StoreItem(id: id, title: title, publisher: "Demo Studio", price: price, gamePass: gamePass)
    }

    private static func game(_ id: String, _ title: String, _ publisher: String, _ state: InstallState) -> Game {
        var game = Game(id: id, title: title, publisher: publisher, installState: state)
        // Fixed "last played" values, so that snapshots show the recent order.
        let days = ["9P0000000005": 0.1, "9P0000000001": 1.2, "9P0000000009": 4, "9P0000000002": 12]
        if let d = days[id] {
            game.lastPlayed = Date(timeIntervalSince1970: 1_793_000_000 - d * 86_400)
            game.gamerscore = (Int(400 + d * 50), 1000)
        }
        return game
    }
}
