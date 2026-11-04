import AppKit
import Foundation

/// The profile card that A opens on a friend.
struct FriendCard: Equatable {
    let friend: Friend
    var profile: PlayerProfile?
    var error: String?
}

// MARK: - Friends

extension AppModel {
    /// The Social page: Messages when a conversation is unread, else Friends.
    func openSocial() {
        friendIndex = 0
        messageIndex = 0
        friendCard = nil
        stack.append(unreadConversations > 0 ? .messages : .friends)
        Task { await loadFriends(force: false) }
        Task { await loadInbox(notify: false) }
    }

    /// Switches between the Friends and Messages tabs. The tab replaces the top
    /// of the stack, so that B goes back to the page before Social.
    func switchSocialTab(to tab: Screen) {
        guard tab == .friends || tab == .messages, screen == .friends || screen == .messages, screen != tab else { return }
        stack[stack.count - 1] = tab
        if tab == .friends { Task { await loadFriends(force: false) } }
        else { Task { await loadInbox(notify: false) } }
    }

    /// Reads the friends list. A list younger than one minute stays, unless `force`.
    func loadFriends(force: Bool) async {
        guard let cli = backendCLI, friendsState != .loading else { return }
        if !force, let loaded = friendsLoadedAt, Date().timeIntervalSince(loaded) < 60 { return }
        guard !demo else { return }
        friendsState = .loading
        do {
            friends = Friend.sorted(try await cli.friends())
            friendIndex = min(friendIndex, max(0, friends.count - 1))
            friendsLoadedAt = Date()
            friendsState = .ready
        } catch {
            friendsState = .failed(error.localizedDescription)
        }
    }

    func moveFriends(_ d: Direction) {
        guard friendCard == nil else { return }
        switch d {
        case .up: friendIndex = max(0, friendIndex - 1)
        case .down: friendIndex = min(max(0, friends.count - 1), friendIndex + 1)
        case .right: switchSocialTab(to: .messages)
        case .left: break
        }
    }

    func openFriendCard() {
        guard friendIndex < friends.count else { return }
        let friend = friends[friendIndex]
        friendCard = FriendCard(friend: friend)
        guard let cli = backendCLI, !accountName.isEmpty else { return }
        let account = accountName
        Task {
            do {
                let profile = try await cli.playerProfile(account: account, xuid: friend.xuid)
                if friendCard?.friend.id == friend.id { friendCard?.profile = profile }
            } catch {
                if friendCard?.friend.id == friend.id { friendCard?.error = error.localizedDescription }
            }
        }
    }

    func tapFriend(_ index: Int) {
        friendIndex = index
        openFriendCard()
    }
}

// MARK: - Store

extension AppModel {
    var storeColumns: Int { 6 }

    var showsStoreResults: Bool { !storeSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    func openStore() {
        storeFocus = .rows
        storeRow = 0
        stack.append(.store)
        Task { await loadStore(force: false) }
    }

    /// Reads the Store rows. Rows younger than ten minutes stay, unless `force`.
    func loadStore(force: Bool) async {
        guard storeState != .loading else { return }
        if !force, let loaded = storeLoadedAt, Date().timeIntervalSince(loaded) < 600, !storeRows.isEmpty { return }
        storeState = .loading
        let catalog = StoreCatalog(session: ImageStore.shared.session, market: market)
        do {
            async let recentIDs = catalog.recentGamePass()
            async let trendingList = catalog.trending()
            let recent = try await catalog.items(recentIDs.map { ($0, nil as String?) }, gamePass: true)
            let trending = try await catalog.items(trendingList)
            var rows: [StoreRow] = []
            if !recent.isEmpty { rows.append(StoreRow(id: "recent", title: "Recently added to PC Game Pass", items: recent)) }
            if !trending.isEmpty { rows.append(StoreRow(id: "trending", title: "Trending games", items: trending)) }
            storeRows = rows
            storeIndex = rows.map { _ in 0 }
            storeRow = min(storeRow, max(0, rows.count - 1))
            for item in recent + trending { storeItems[item.id] = item }
            storeLoadedAt = Date()
            storeState = .ready
        } catch {
            storeState = .failed(error.localizedDescription)
        }
    }

    /// New search text. The search starts 0.4 seconds after the last key.
    func setStoreSearch(_ text: String) {
        storeSearch = text
        storeResultIndex = 0
        storeSearchTask?.cancel()
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            storeResults = []
            storeSearchState = .idle
            return
        }
        storeSearchState = .loading
        let market = self.market
        storeSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let catalog = StoreCatalog(session: ImageStore.shared.session, market: market)
            do {
                let items = try await catalog.items(catalog.search(query))
                guard !Task.isCancelled, storeSearch.trimmingCharacters(in: .whitespaces) == query else { return }
                storeResults = items
                for item in items { storeItems[item.id] = item }
                storeSearchState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                storeSearchState = .failed(error.localizedDescription)
            }
        }
    }

    func moveStore(_ d: Direction) {
        switch storeFocus {
        case .search:
            if d == .down {
                if showsStoreResults { if !storeResults.isEmpty { storeFocus = .results } } else if !storeRows.isEmpty { storeFocus = .rows }
            }
        case .rows:
            guard !storeRows.isEmpty else { if d == .up { storeFocus = .search }; return }
            switch d {
            case .up: if storeRow > 0 { storeRow -= 1 } else { storeFocus = .search }
            case .down: storeRow = min(storeRows.count - 1, storeRow + 1)
            case .left: storeIndex[storeRow] = max(0, storeIndex[storeRow] - 1)
            case .right: storeIndex[storeRow] = min(storeRows[storeRow].items.count - 1, storeIndex[storeRow] + 1)
            }
        case .results:
            let n = storeResults.count, c = storeColumns
            switch d {
            case .left: if storeResultIndex % c > 0 { storeResultIndex -= 1 }
            case .right: if storeResultIndex % c < c - 1, storeResultIndex + 1 < n { storeResultIndex += 1 }
            case .up: if storeResultIndex - c >= 0 { storeResultIndex -= c } else { storeFocus = .search }
            case .down: if n > 0 { storeResultIndex = min(n - 1, storeResultIndex + c) }
            }
        }
    }

    func confirmStore() {
        switch storeFocus {
        case .search:
            if showsStoreResults { if !storeResults.isEmpty { storeFocus = .results } } else { storeFocus = .rows }
        case .rows:
            guard storeRow < storeRows.count else { return }
            let items = storeRows[storeRow].items
            if storeIndex[storeRow] < items.count { openStoreItem(items[storeIndex[storeRow]]) }
        case .results:
            if storeResultIndex < storeResults.count { openStoreItem(storeResults[storeResultIndex]) }
        }
    }

    /// A game in the library opens its normal page. Other games open a Store page.
    func openStoreItem(_ item: StoreItem) {
        if game(item.id) != nil {
            openDetail(item.id)
            return
        }
        storeItems[item.id] = item
        stack.append(.storeItem(item.id))
    }

    func storeItem(_ id: String) -> StoreItem? { storeItems[id] }

    func inLibrary(_ id: String) -> Bool { game(id) != nil }

    /// iOdus cannot buy games, so the Store page links to xbox.com.
    func openOnXbox(_ id: String) {
        let locale = "en-\(market)"
        guard let url = URL(string: "https://www.xbox.com/\(locale)/games/store/x/\(id)") else { return }
        NSWorkspace.shared.open(url)
        showToast("Opened \(storeItems[id]?.title ?? "the game") on xbox.com in your browser.")
    }

    func tapStoreSearch() { storeFocus = .search }

    func tapStoreTile(row: Int, index: Int) {
        storeFocus = .rows
        storeRow = row
        storeIndex[row] = index
        confirmStore()
    }

    func tapStoreResult(_ index: Int) {
        storeFocus = .results
        storeResultIndex = index
        confirmStore()
    }
}

// MARK: - Achievements

/// The name and art of one achievement page.
struct AchievementTitle: Equatable {
    let titleId: String
    let name: String
    let art: URL?
    let gameID: Game.ID?    // The library game, when the title is in the library
}

extension AppModel {
    func achievementList(_ titleId: String) -> AchievementList? { achievementLists[titleId] }

    /// From a game page.
    func openAchievements(_ game: Game) {
        guard let titleId = game.titleId else {
            showToast("\(game.title) has no Xbox title ID, so it has no achievement list.")
            return
        }
        achievementTitles[titleId] = AchievementTitle(titleId: titleId, name: game.title,
                                                      art: game.tileArt, gameID: game.id)
        openAchievementPage(titleId)
    }

    private func openAchievementPage(_ titleId: String) {
        achievementIndex = 0
        showSecrets = false
        stack.append(.achievements(titleId))
        Task { await loadAchievements(titleId: titleId, force: false) }
    }

    func loadAchievements(titleId: String, force: Bool) async {
        if !force, achievementLists[titleId] != nil {
            achievementState = .ready
            return
        }
        guard !demo, let cli = backendCLI, achievementState != .loading else { return }
        achievementState = .loading
        do {
            achievementLists[titleId] = try await cli.achievements(titleId: titleId)
            achievementState = .ready
        } catch {
            achievementState = .failed(error.localizedDescription)
        }
    }

    func moveAchievements(_ d: Direction) {
        guard case .achievements(let titleId) = screen, let list = achievementLists[titleId] else { return }
        switch d {
        case .up: achievementIndex = max(0, achievementIndex - 1)
        case .down: achievementIndex = min(max(0, list.items.count - 1), achievementIndex + 1)
        default: break
        }
    }

    func tapAchievement(_ index: Int) { achievementIndex = index }

    // MARK: Hub

    /// The games of the hub: recent games with achievements, newest first.
    var hubTitles: [PlayedTitle] { titleHistory.filter(\.hasAchievements) }

    /// The library game of a title, for its box art.
    func libraryGame(titleId: String) -> Game? { games.first { $0.titleId == titleId } }

    func openAchievementHub() {
        hubIndex = 0
        stack.append(.achievementHub)
        Task { await loadHistory(force: false) }
    }

    /// The history from the library load stays for two minutes; then it is read again,
    /// so that new achievements show.
    func loadHistory(force: Bool) async {
        if !force, let loaded = historyLoadedAt, Date().timeIntervalSince(loaded) < 120, !titleHistory.isEmpty { return }
        guard !demo, let cli = backendCLI, !accountName.isEmpty, historyState != .loading else { return }
        historyState = .loading
        do {
            titleHistory = try await cli.titleHistory(account: accountName)
            historyLoadedAt = Date()
            historyState = .ready
            hubIndex = min(hubIndex, max(0, hubTitles.count - 1))
            // A new history can change the achievement counts, so lists load again.
            if force { achievementLists.removeAll() }
        } catch {
            historyState = .failed(error.localizedDescription)
        }
    }

    func moveHub(_ d: Direction) {
        switch d {
        case .up: hubIndex = max(0, hubIndex - 1)
        case .down: hubIndex = min(max(0, hubTitles.count - 1), hubIndex + 1)
        default: break
        }
    }

    func openHubTitle() {
        let titles = hubTitles
        guard hubIndex < titles.count else { return }
        let title = titles[hubIndex]
        let game = libraryGame(titleId: title.titleId)
        achievementTitles[title.titleId] = AchievementTitle(titleId: title.titleId, name: title.name,
                                                            art: game?.tileArt ?? title.image, gameID: game?.id)
        openAchievementPage(title.titleId)
    }

    func tapHubTitle(_ index: Int) {
        hubIndex = index
        openHubTitle()
    }
}
