import Foundation

/// The local record of game starts in iOdus.
///
/// Games that iOdus starts do not report presence to Xbox Live yet, so
/// Microsoft's title history does not show them. iOdus keeps its own
/// "last played" time and uses the newer of the two dates.
struct PlayHistory {
    private(set) var lastPlayed: [String: Date] = [:]
    let file: URL

    static var standardFile: URL {
        GameRuntime.support.appendingPathComponent("played.json")
    }

    init(file: URL = PlayHistory.standardFile) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastPlayed = saved
        }
    }

    mutating func record(_ id: String, at date: Date = Date()) {
        lastPlayed[id] = date
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lastPlayed) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// The newer of the Microsoft date and the local date for each game.
    func merged(into games: [Game]) -> [Game] {
        games.map { game in
            guard let local = lastPlayed[game.id] else { return game }
            var game = game
            if game.lastPlayed.map({ local > $0 }) ?? true { game.lastPlayed = local }
            return game
        }
    }
}
