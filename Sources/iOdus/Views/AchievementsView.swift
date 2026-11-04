import SwiftUI

/// The achievements of one game: a summary, then one row per achievement.
struct AchievementsView: View {
    @EnvironmentObject private var model: AppModel
    let title: AchievementTitle
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 48 * s) {
                summary(s)
                    .frame(width: 360 * s, alignment: .topLeading)
                list(s, height: geo.size.height)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.top, 150 * s)
        }
        .background(
            ZStack {
                if let id = title.gameID, let game = model.game(id) {
                    HeroBackground(game: game)
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.35), Theme.background],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                }
                Color.black.opacity(0.55)
            }
        )
    }

    private var achievementList: AchievementList? { model.achievementList(title.titleId) }

    private func summary(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16 * s) {
            TitleArt(url: title.art, name: title.name, scale: s)
                .frame(width: 200 * s, height: 200 * s)
                .clipShape(RoundedRectangle(cornerRadius: 4 * s))
            Text(title.name)
                .font(.system(size: 30 * s, weight: .semibold))
            Text("Achievements")
                .font(.system(size: 20 * s))
                .foregroundStyle(Theme.textSecondary)
            if let list = achievementList, !list.items.isEmpty {
                Text("\(list.unlocked) of \(list.items.count) unlocked")
                    .font(.system(size: 20 * s, weight: .medium))
                HStack(spacing: 8 * s) {
                    GamerscoreMark(size: 20 * s)
                    Text("\(list.earnedScore.grouped) / \(list.totalScore.grouped)")
                        .monospacedDigit()
                }
                .font(.system(size: 20 * s))
                ProgressStrip(progress: Double(list.unlocked) / Double(list.items.count), scale: s * 1.4)
                    .frame(width: 300 * s)
                    .clipShape(Capsule())
                if list.partial {
                    Text("Xbox Live returned only a part of the list.")
                        .font(.system(size: 15 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func list(_ s: CGFloat, height: CGFloat) -> some View {
        if let list = achievementList {
            if list.items.isEmpty {
                message("This game has no achievements.", s)
            } else {
                let rowHeight: CGFloat = 104 * s, gap: CGFloat = 10 * s
                let listHeight = max(rowHeight, height - 290 * s)
                let visible = max(1, Int(listHeight / (rowHeight + gap)))
                let shift = max(0, model.achievementIndex - visible + 2)
                FocusScroll(focus: model.achievementIndex, height: listHeight,
                            snapshotShift: CGFloat(shift) * (rowHeight + gap), scale: s) {
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(list.items.enumerated()), id: \.element.id) { i, item in
                            AchievementRow(item: item, showSecret: model.showSecrets, scale: s)
                                .frame(height: rowHeight)
                                .focusFrame(model.achievementIndex == i, scale: s)
                                .contentShape(Rectangle())
                                .onTapGesture { model.tapAchievement(i) }
                                .scrollAnchor(i)
                        }
                    }
                }
            }
        } else {
            switch model.achievementState {
            case .failed(let message):
                self.message("The achievements could not load: \(message)", s)
            default:
                HStack(spacing: 14 * s) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Loading the achievements…")
                }
                .font(.system(size: 22 * s))
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func message(_ text: String, _ s: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 22 * s))
            .foregroundStyle(Theme.textSecondary)
    }
}

struct AchievementRow: View {
    let item: Achievement
    let showSecret: Bool
    let scale: CGFloat

    private var hidden: Bool { item.secret && !item.isUnlocked && !showSecret }

    var body: some View {
        let s = scale
        HStack(spacing: 20 * s) {
            ZStack {
                if hidden {
                    Theme.tile
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26 * s))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    RemoteImage(url: item.icon) { Theme.tile }
                        .saturation(item.isUnlocked ? 1 : 0)
                        .opacity(item.isUnlocked ? 1 : 0.55)
                }
            }
            .frame(width: 80 * s, height: 80 * s)
            .clipShape(RoundedRectangle(cornerRadius: 4 * s))

            VStack(alignment: .leading, spacing: 6 * s) {
                Text(hidden ? "Secret achievement" : item.name)
                    .font(.system(size: 21 * s, weight: .semibold))
                    .lineLimit(1)
                Text(hidden ? "Keep playing to unlock this achievement. Press X to show it." : item.description)
                    .font(.system(size: 16 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                status(s)
            }
            Spacer()
            HStack(spacing: 6 * s) {
                GamerscoreMark(size: 18 * s)
                Text("\(item.gamerscore)")
                    .monospacedDigit()
            }
            .font(.system(size: 20 * s, weight: .semibold))
            .foregroundStyle(item.isUnlocked ? Theme.textPrimary : Theme.textSecondary)
        }
        .padding(.horizontal, 16 * s)
        .frame(maxHeight: .infinity)
        .background((item.isUnlocked ? Theme.accent.opacity(0.22) : Theme.tile.opacity(0.9)))
    }

    @ViewBuilder
    private func status(_ s: CGFloat) -> some View {
        if item.isUnlocked {
            Label(item.unlockedDate.map { "Unlocked " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unlocked",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 14 * s, weight: .medium))
                .foregroundStyle(Theme.accentBright)
        } else if item.inProgress, let progress = item.progress {
            HStack(spacing: 10 * s) {
                ProgressStrip(progress: progress, scale: s)
                    .frame(width: 180 * s)
                    .clipShape(Capsule())
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 14 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
        }
    }
}

/// The art of a title: the Store box art, the Xbox title image, or a placeholder.
struct TitleArt: View {
    let url: URL?
    let name: String
    let scale: CGFloat

    var body: some View {
        RemoteImage(url: url.map { ImageStore.sized($0, width: 300) }) {
            ZStack {
                Theme.tile
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 30 * scale))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// The achievement hub: recent games with their achievement progress.
struct AchievementHubView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
                    Text("Achievements")
                        .font(.system(size: 40 * s, weight: .semibold))
                    if let score = model.gamerscore {
                        HStack(spacing: 6 * s) {
                            GamerscoreMark(size: 20 * s)
                            Text(score.grouped).monospacedDigit()
                        }
                        .font(.system(size: 22 * s))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if model.historyState == .loading {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                }
                .padding(.bottom, 10 * s)
                content(s, height: geo.size.height)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: 1300 * s, alignment: .leading)
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
        let titles = model.hubTitles
        if titles.isEmpty {
            switch model.historyState {
            case .failed(let message):
                Text("The game list could not load: \(message) Press X to try again.")
                    .font(.system(size: 22 * s)).foregroundStyle(Theme.textSecondary)
            case .loading:
                EmptyView()
            default:
                Text("No games with achievements yet.")
                    .font(.system(size: 22 * s)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            let rowHeight: CGFloat = 110 * s, gap: CGFloat = 10 * s
            // The list ends above the button hints.
            let listHeight = max(rowHeight, height - 380 * s)
            let visible = max(1, Int(listHeight / (rowHeight + gap)))
            let shift = max(0, model.hubIndex - visible + 2)
            FocusScroll(focus: model.hubIndex, height: listHeight,
                        snapshotShift: CGFloat(shift) * (rowHeight + gap), scale: s) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(titles.enumerated()), id: \.element.titleId) { i, title in
                        HubRow(title: title, art: model.libraryGame(titleId: title.titleId)?.tileArt ?? title.image, scale: s)
                            .frame(height: rowHeight)
                            .focusFrame(model.hubIndex == i, scale: s)
                            .contentShape(Rectangle())
                            .onTapGesture { model.tapHubTitle(i) }
                            .scrollAnchor(i)
                    }
                }
            }
        }
    }
}

struct HubRow: View {
    let title: PlayedTitle
    let art: URL?
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 22 * s) {
            TitleArt(url: art, name: title.name, scale: s)
                .frame(width: 86 * s, height: 86 * s)
                .clipShape(RoundedRectangle(cornerRadius: 4 * s))
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title.name)
                    .font(.system(size: 22 * s, weight: .semibold))
                    .lineLimit(1)
                if let date = title.lastPlayedDate {
                    Text("Last played " + GameDetailView.relative(date))
                        .font(.system(size: 16 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
                ProgressStrip(progress: fraction, scale: s * 1.2)
                    .frame(width: 360 * s)
                    .clipShape(Capsule())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8 * s) {
                if let total = title.achievementsTotal, total > 0 {
                    Text("\(title.achievementsUnlocked ?? 0) of \(total)")
                        .font(.system(size: 18 * s, weight: .medium))
                        .monospacedDigit()
                }
                HStack(spacing: 6 * s) {
                    GamerscoreMark(size: 18 * s)
                    Text("\((title.currentGamerscore ?? 0).grouped) / \((title.totalGamerscore ?? 0).grouped)")
                        .monospacedDigit()
                }
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 18 * s)
        .frame(maxHeight: .infinity)
        .background(Theme.tile.opacity(0.9))
    }

    private var fraction: Double {
        if let total = title.totalGamerscore, total > 0 { return Double(title.currentGamerscore ?? 0) / Double(total) }
        if let total = title.achievementsTotal, total > 0 { return Double(title.achievementsUnlocked ?? 0) / Double(total) }
        return 0
    }
}
