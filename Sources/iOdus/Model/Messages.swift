import Foundation

/// Messages that this Mac has shown. The backend cannot mark a conversation as
/// read on Xbox Live, so iOdus keeps its own record (the last seen message ID
/// of each conversation).
struct SeenMessages {
    private(set) var lastSeen: [String: String] = [:]
    let file: URL

    static var standardFile: URL { GameRuntime.support.appendingPathComponent("seen-messages.json") }

    init(file: URL = SeenMessages.standardFile) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) { lastSeen = saved }
    }

    func isUnread(_ item: InboxItem) -> Bool {
        guard let last = item.lastMessage, !last.mine else { return false }
        return lastSeen[item.id] != last.id
    }

    mutating func markSeen(_ item: InboxItem) {
        guard let last = item.lastMessage, lastSeen[item.id] != last.id else { return }
        lastSeen[item.id] = last.id
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lastSeen) { try? data.write(to: file, options: .atomic) }
    }
}

extension AppModel {
    static let maxMessageLength = 256

    var unreadConversations: Int { inbox.filter { seenMessages.isUnread($0) }.count }

    /// The name of a player: from the friends list, from a loaded profile, or the XUID.
    func playerName(_ xuid: String) -> String {
        if let friend = friends.first(where: { $0.xuid == xuid }) { return friend.gamertag }
        if let profile = playerProfiles[xuid] { return profile.gamertag }
        return "Xbox player"
    }

    func playerAvatar(_ xuid: String) -> URL? {
        if let url = friends.first(where: { $0.xuid == xuid })?.avatar { return url }
        return playerProfiles[xuid]?.avatarUrl.flatMap(URL.init(string:))
    }

    func conversationTitle(_ item: InboxItem) -> String {
        if item.isSystem { return "Xbox" }
        if let peer = item.peer { return playerName(peer) }
        return item.participants.map(playerName).joined(separator: ", ")
    }

    private func channel() -> SocialChannel? {
        if let socialChannel { return socialChannel }
        guard let cli = backendCLI, !demo else { return nil }
        let channel = SocialChannel(cli: cli)
        socialChannel = channel
        return channel
    }

    // MARK: Inbox

    /// Reads the inbox. With `notify`, a new message gives a toast and a notification.
    func loadInbox(notify: Bool) async {
        guard let channel = channel(), inboxState != .loading else { return }
        inboxState = .loading
        do {
            let items = try await channel.inbox()
            let before = Set(inbox.compactMap { $0.lastMessage?.id })
            inbox = items.sorted { ($0.lastMessage?.date ?? .distantPast) > ($1.lastMessage?.date ?? .distantPast) }
            inboxState = .ready
            messageIndex = min(messageIndex, max(0, inbox.count - 1))
            if friends.isEmpty { await loadFriends(force: false) }
            await loadMissingNames()
            if notify { announceNewMessages(previous: before) }
        } catch {
            inboxState = .failed(error.localizedDescription)
        }
    }

    /// Profiles for people who are not friends, so that their names show.
    private func loadMissingNames() async {
        guard let cli = backendCLI, !accountName.isEmpty else { return }
        let known = Set(friends.map(\.xuid)).union(playerProfiles.keys)
        for xuid in Set(inbox.flatMap(\.participants)).subtracting(known).prefix(10) {
            if let profile = try? await cli.playerProfile(account: accountName, xuid: xuid) {
                playerProfiles[xuid] = profile
            }
        }
    }

    private func announceNewMessages(previous: Set<String>) {
        // The first check after the start only learns the current state.
        guard inboxChecked else { inboxChecked = true; return }
        for item in inbox where seenMessages.isUnread(item) {
            guard let last = item.lastMessage, !previous.contains(last.id) else { continue }
            // An open conversation shows the message at once.
            if case .conversation(let peer) = screen, peer == item.peer { continue }
            let name = conversationTitle(item)
            let text = last.hidden ? "New message" : String(last.text.prefix(80))
            showToast("\(name): \(text)", seconds: 5)
            notify(AppNotification(date: Date(), kind: .message, title: "Message from \(name)", detail: text,
                                   action: item.peer.map { .openConversation($0) } ?? .none))
        }
    }

    /// Checks the inbox every 60 seconds while the app runs.
    func startMessagePolling() {
        guard inboxTimer == nil, !demo else { return }
        inboxTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                guard model.account == .ready else { return }
                Task { await model.loadInbox(notify: true) }
            }
        }
        Task { await loadInbox(notify: true) }
    }

    func moveMessages(_ d: Direction) {
        switch d {
        case .up: messageIndex = max(0, messageIndex - 1)
        case .down: messageIndex = min(max(0, inbox.count - 1), messageIndex + 1)
        case .left: switchSocialTab(to: .friends)
        case .right: break
        }
    }

    func openSelectedConversation() {
        guard messageIndex < inbox.count else { return }
        let item = inbox[messageIndex]
        guard let peer = item.peer else {
            showToast(item.isSystem ? "System messages from Xbox cannot get a reply." : "Group conversations come later.")
            seenMessages.markSeen(item)
            objectWillChange.send()
            return
        }
        openConversation(with: peer)
    }

    func tapConversation(_ index: Int) {
        messageIndex = index
        openSelectedConversation()
    }

    // MARK: Conversation

    func openConversation(with xuid: String) {
        chatDraft = ""
        stack.append(.conversation(xuid))
        markConversationSeen(xuid)
        Task { await loadConversation(xuid) }
        startConversationPolling(xuid)
    }

    func loadConversation(_ xuid: String) async {
        guard let channel = channel() else { return }
        if conversations[xuid] == nil { conversationState = .loading }
        do {
            conversations[xuid] = try await channel.conversation(with: xuid)
            conversationState = .ready
        } catch {
            conversationState = .failed(error.localizedDescription)
        }
    }

    private func markConversationSeen(_ xuid: String) {
        for item in inbox where item.peer == xuid { seenMessages.markSeen(item) }
        objectWillChange.send()
    }

    /// While a conversation is open, read it every 5 seconds.
    private func startConversationPolling(_ xuid: String) {
        conversationTimer?.invalidate()
        conversationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                guard case .conversation(let open) = model.screen, open == xuid else {
                    timer.invalidate()
                    return
                }
                Task {
                    await model.loadConversation(xuid)
                    await model.refreshInboxQuietly(for: xuid)
                }
            }
        }
    }

    /// Keeps the inbox entry of the open conversation current and seen.
    private func refreshInboxQuietly(for xuid: String) async {
        guard let channel = channel(), let items = try? await channel.inbox() else { return }
        inbox = items.sorted { ($0.lastMessage?.date ?? .distantPast) > ($1.lastMessage?.date ?? .distantPast) }
        markConversationSeen(xuid)
    }

    func sendDraft() {
        guard case .conversation(let xuid) = screen, !sendingMessage else { return }
        let text = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.maxMessageLength else {
            showToast("A message can have at most \(Self.maxMessageLength) characters.")
            return
        }
        guard let channel = channel(), !accountName.isEmpty else { return }
        sendingMessage = true
        let account = accountName
        Task {
            do {
                _ = try await channel.send(account: account, to: xuid, text: text)
                if chatDraft.trimmingCharacters(in: .whitespacesAndNewlines) == text { chatDraft = "" }
                await loadConversation(xuid)
            } catch {
                showToast(error.localizedDescription, seconds: 6)
            }
            sendingMessage = false
        }
    }

    /// A friend card: write to this friend.
    func messageFriend(_ friend: Friend) {
        friendCard = nil
        openConversation(with: friend.xuid)
    }
}
