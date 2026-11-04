import SwiftUI

/// Friends: online friends first, with their presence. A opens a profile card.
struct FriendsView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14 * s) {
                SocialHeader(busy: model.friendsState == .loading, scale: s)
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
        if case .failed(let message) = model.friendsState, model.friends.isEmpty {
            Text("The friends list could not load: \(message) Press X to try again.")
                .font(.system(size: 22 * s))
                .foregroundStyle(Theme.textSecondary)
        } else if model.friends.isEmpty && model.friendsState != .loading {
            Text("You have no friends on Xbox yet.")
                .font(.system(size: 22 * s))
                .foregroundStyle(Theme.textSecondary)
        } else {
            let rowHeight: CGFloat = 96 * s
            let listHeight = max(rowHeight, height - 380 * s)
            let visible = max(1, Int(listHeight / (rowHeight + 10 * s)))
            let shift = max(0, model.friendIndex - visible + 1)
            FocusScroll(focus: model.friendIndex, height: listHeight,
                        snapshotShift: CGFloat(shift) * (rowHeight + 10 * s), scale: s) {
                VStack(alignment: .leading, spacing: 10 * s) {
                    ForEach(Array(model.friends.enumerated()), id: \.element.id) { i, friend in
                        FriendRow(friend: friend, scale: s)
                            .frame(height: rowHeight)
                            .focusFrame(model.friendIndex == i && model.friendCard == nil, scale: s)
                            .contentShape(Rectangle())
                            .onTapGesture { model.tapFriend(i) }
                            .scrollAnchor(i)
                    }
                }
            }
        }
    }
}

struct FriendAvatar: View {
    let url: URL?
    let online: Bool
    let size: CGFloat

    var body: some View {
        RemoteImage(url: url) {
            Circle().fill(Theme.tile)
                .overlay(Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Theme.textSecondary))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if online {
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(Theme.background, lineWidth: size * 0.05))
            }
        }
    }
}

struct FriendRow: View {
    let friend: Friend
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 20 * s) {
            FriendAvatar(url: friend.avatar, online: friend.online, size: 64 * s)
            VStack(alignment: .leading, spacing: 6 * s) {
                HStack(spacing: 8 * s) {
                    Text(friend.gamertag)
                        .font(.system(size: 22 * s, weight: .semibold))
                    if friend.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 14 * s))
                            .foregroundStyle(Theme.buttonY)
                    }
                    if friend.inParty {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 14 * s))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(friend.presence)
                    .font(.system(size: 17 * s))
                    .foregroundStyle(friend.online ? Theme.accentBright : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18 * s)
        .frame(maxHeight: .infinity)
        .background(Theme.tile.opacity(0.9))
    }
}

/// The profile card of a friend.
struct FriendCardView: View {
    @EnvironmentObject private var model: AppModel
    let card: FriendCard
    let scale: CGFloat

    var body: some View {
        let s = scale
        let friend = card.friend
        ZStack {
            Color.black.opacity(0.65)
                .onTapGesture { model.back() }
            VStack(alignment: .leading, spacing: 18 * s) {
                HStack(spacing: 22 * s) {
                    FriendAvatar(url: friend.avatar, online: friend.online, size: 110 * s)
                    VStack(alignment: .leading, spacing: 8 * s) {
                        Text(friend.gamertag)
                            .font(.system(size: 34 * s, weight: .semibold))
                        if let score = card.profile?.gamerscoreValue {
                            HStack(spacing: 6 * s) {
                                GamerscoreMark(size: 20 * s)
                                Text(score.grouped).monospacedDigit()
                            }
                            .font(.system(size: 20 * s))
                            .foregroundStyle(Theme.textSecondary)
                        }
                        Text(card.profile?.presence ?? friend.presence)
                            .font(.system(size: 18 * s))
                            .foregroundStyle(friend.online ? Theme.accentBright : Theme.textSecondary)
                    }
                }
                if let profile = card.profile {
                    if let bio = profile.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.system(size: 18 * s))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(4)
                    }
                    let details = [
                        profile.location.map { "Location: \($0)" },
                        profile.tenure.map { "Xbox years: \($0)" },
                        profile.counts?.friends.map { "Friends: \($0)" },
                        profile.counts?.followers.map { "Followers: \($0)" },
                    ].compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.system(size: 17 * s))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else if let error = card.error {
                    Text("The profile could not load: \(error)")
                        .font(.system(size: 17 * s))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 12 * s) {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Loading the profile…")
                    }
                    .font(.system(size: 18 * s))
                    .foregroundStyle(Theme.textSecondary)
                }
                Text("Chat and invites come later.")
                    .font(.system(size: 15 * s))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .padding(.top, 6 * s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(36 * s)
            .frame(width: 760 * s, alignment: .leading)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8 * s))
        }
    }
}
