import SwiftUI

/// The inbox: one row for each conversation, newest first.
struct MessagesView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14 * s) {
                SocialHeader(busy: model.inboxState == .loading, scale: s)
                    .padding(.bottom, 10 * s)
                content(s, height: geo.size.height)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: 1100 * s, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.top, 150 * s)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func content(_ s: CGFloat, height: CGFloat) -> some View {
        if model.inbox.isEmpty {
            switch model.inboxState {
            case .failed(let message):
                Text("The messages could not load: \(message) Press X to try again.")
                    .font(.system(size: 22 * s)).foregroundStyle(Theme.textSecondary)
            case .loading, .idle:
                EmptyView()
            case .ready:
                Text("No messages yet. Open Friends and select a friend to write a message.")
                    .font(.system(size: 22 * s)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            let rowHeight: CGFloat = 96 * s, gap: CGFloat = 10 * s
            let listHeight = max(rowHeight, height - 380 * s)
            let visible = max(1, Int(listHeight / (rowHeight + gap)))
            let shift = max(0, model.messageIndex - visible + 1)
            FocusScroll(focus: model.messageIndex, height: listHeight,
                        snapshotShift: CGFloat(shift) * (rowHeight + gap), scale: s) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(model.inbox.enumerated()), id: \.element.id) { i, item in
                        InboxRow(item: item, scale: s)
                            .frame(height: rowHeight)
                            .focusFrame(model.messageIndex == i, scale: s)
                            .contentShape(Rectangle())
                            .onTapGesture { model.tapConversation(i) }
                            .scrollAnchor(i)
                    }
                }
            }
        }
    }
}

struct InboxRow: View {
    @EnvironmentObject private var model: AppModel
    let item: InboxItem
    let scale: CGFloat

    var body: some View {
        let s = scale
        let unread = model.seenMessages.isUnread(item)
        HStack(spacing: 20 * s) {
            if item.isSystem {
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 28 * s))
                    .frame(width: 64 * s, height: 64 * s)
                    .background(Theme.accent, in: Circle())
            } else {
                FriendAvatar(url: item.peer.flatMap(model.playerAvatar), online: false, size: 64 * s)
            }
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(model.conversationTitle(item))
                    .font(.system(size: 22 * s, weight: unread ? .bold : .semibold))
                if let last = item.lastMessage {
                    Text((last.mine ? "You: " : "") + last.shownText)
                        .font(.system(size: 17 * s))
                        .foregroundStyle(unread ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8 * s) {
                if let date = item.lastMessage?.date {
                    Text(MessageTime.short(date))
                        .font(.system(size: 15 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
                if unread {
                    Circle().fill(Theme.accentBright).frame(width: 12 * s, height: 12 * s)
                }
            }
        }
        .padding(.horizontal, 18 * s)
        .frame(maxHeight: .infinity)
        .background(Theme.tile.opacity(0.9))
    }
}

/// One conversation: bubbles, newest at the bottom, and an input box.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.snapshotMode) private var snapshotMode
    let peer: String
    let scale: CGFloat

    var body: some View {
        let s = scale
        let messages = model.conversations[peer] ?? []
        VStack(alignment: .leading, spacing: 16 * s) {
            HStack(spacing: 16 * s) {
                FriendAvatar(url: model.playerAvatar(peer),
                             online: model.friends.first { $0.xuid == peer }?.online ?? false, size: 56 * s)
                VStack(alignment: .leading, spacing: 4 * s) {
                    Text(model.playerName(peer))
                        .font(.system(size: 30 * s, weight: .semibold))
                    if let friend = model.friends.first(where: { $0.xuid == peer }) {
                        Text(friend.presence)
                            .font(.system(size: 16 * s))
                            .foregroundStyle(friend.online ? Theme.accentBright : Theme.textSecondary)
                    }
                }
                if model.conversationState == .loading {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            bubbles(messages, s)
            inputBox(s)
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: 1100 * s)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.sidePadding * s)
        .padding(.top, 130 * s)
        .padding(.bottom, 110 * s)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func bubbles(_ messages: [ChatMessage], _ s: CGFloat) -> some View {
        if messages.isEmpty {
            VStack {
                Spacer()
                switch model.conversationState {
                case .failed(let message):
                    Text("The conversation could not load: \(message)")
                default:
                    Text(model.conversationState == .loading ? "" : "No messages yet. Write the first one.")
                }
                Spacer()
            }
            .font(.system(size: 20 * s))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
        } else if snapshotMode {
            // ImageRenderer cannot draw a ScrollView: show the newest messages.
            VStack(spacing: 10 * s) {
                Spacer(minLength: 0)
                ForEach(messages.suffix(8)) { message in MessageBubble(message: message, scale: s) }
            }
            .frame(maxHeight: .infinity)
            .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 10 * s) {
                        ForEach(messages) { message in
                            MessageBubble(message: message, scale: s).id(message.id)
                        }
                    }
                    .padding(.vertical, 8 * s)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func inputBox(_ s: CGFloat) -> some View {
        let draft = model.chatDraft
        return HStack(spacing: 12 * s) {
            HStack(spacing: 1 * s) {
                Text(draft.isEmpty ? "Type a message" : draft)
                    .foregroundStyle(draft.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Rectangle().fill(Theme.textPrimary).frame(width: 2 * s, height: 22 * s)
            }
            Spacer(minLength: 0)
            if !draft.isEmpty {
                Text("\(draft.count)/\(AppModel.maxMessageLength)")
                    .font(.system(size: 14 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            if model.sendingMessage {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(draft.isEmpty ? Theme.textSecondary : Theme.accentBright)
                    .contentShape(Rectangle())
                    .onTapGesture { model.sendDraft() }
            }
        }
        .font(.system(size: 20 * s))
        .padding(.horizontal, 20 * s)
        .frame(height: 52 * s)
        .background(Color.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 1.5 * s))
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack {
            if message.mine { Spacer(minLength: 160 * s) }
            VStack(alignment: message.mine ? .trailing : .leading, spacing: 4 * s) {
                Text(message.shownText)
                    .font(.system(size: 19 * s))
                    .italic(message.hidden)
                    .foregroundStyle(message.hidden ? Theme.textSecondary : Theme.textPrimary)
                    .multilineTextAlignment(message.mine ? .trailing : .leading)
                    .padding(.horizontal, 16 * s)
                    .padding(.vertical, 10 * s)
                    .background(message.mine ? Theme.accent : Theme.tile,
                                in: RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
                if let date = message.date {
                    Text(MessageTime.short(date))
                        .font(.system(size: 13 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !message.mine { Spacer(minLength: 160 * s) }
        }
    }
}

enum MessageTime {
    /// "9:42 PM" today, "Yesterday", or "Oct 30".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// The header of the Social page: the title and the Friends and Messages tabs.
/// LB / RB, Left / Right, or a click switches the tab.
struct SocialHeader: View {
    @EnvironmentObject private var model: AppModel
    let busy: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(alignment: .center, spacing: 28 * s) {
            Text("Social")
                .font(.system(size: 40 * s, weight: .semibold))
            HStack(spacing: 8 * s) {
                tab("Friends", detail: "\(model.friends.filter(\.online).count) online", screen: .friends, s)
                tab("Messages", detail: model.unreadConversations > 0 ? "\(model.unreadConversations) unread" : nil,
                    screen: .messages, s)
            }
            .padding(5 * s)
            .background(Color.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1 * s))
            if busy {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
    }

    private func tab(_ title: String, detail: String?, screen: Screen, _ s: CGFloat) -> some View {
        let selected = model.screen == screen
        return HStack(spacing: 8 * s) {
            Text(title)
                .font(.system(size: 19 * s, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 15 * s, weight: .medium))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Theme.accentBright)
            }
        }
        .foregroundStyle(selected ? Color.white : Theme.textSecondary)
        .padding(.horizontal, 18 * s)
        .frame(height: 40 * s)
        .background(selected ? Theme.accent : .clear, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { model.switchSocialTab(to: screen) }
    }
}
