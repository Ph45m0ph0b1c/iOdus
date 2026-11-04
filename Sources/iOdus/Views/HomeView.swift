import SwiftUI

/// The home screen: the art of the focused game fills the background, with a
/// row of recent games and a row of shortcuts.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                HeroBackground(game: model.focusedHomeGame)

                VStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: geo.size.height * 0.38)
                    heroText(s)
                        .padding(.bottom, 28 * s)
                    recentRow(s, width: geo.size.width)
                        .padding(.bottom, 44 * s)
                    shortcutRow(s)
                    Spacer()
                }
                .padding(.horizontal, Theme.sidePadding * s)
            }
        }
    }

    // MARK: - Parts

    @ViewBuilder
    private func heroText(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6 * s) {
            if let game = model.focusedHomeGame {
                Text(game.title)
                    .font(.system(size: 44 * s, weight: .semibold))
                Text(statusLine(game))
                    .font(.system(size: 20 * s))
                    .foregroundStyle(Theme.textSecondary)
            } else if model.homeRow == 0 {
                Text("My games & apps")
                    .font(.system(size: 44 * s, weight: .semibold))
                Text("\(model.games.count) games")
                    .font(.system(size: 20 * s))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(model.shortcuts[model.homeIndex[1]].title)
                    .font(.system(size: 44 * s, weight: .semibold))
                Text(" ").font(.system(size: 20 * s))
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .shadow(color: .black.opacity(0.5), radius: 8)
    }

    private func recentRow(_ s: CGFloat, width: CGFloat) -> some View {
        let big: CGFloat = 300 * s     // The first (most recent) tile is larger.
        let small: CGFloat = 196 * s
        let gap: CGFloat = 18 * s
        let focusedRow = model.homeRow == 0
        let index = model.homeIndex[0]
        // Shift the row so that the focused tile stays on screen.
        let visible = Int((width - Theme.sidePadding * 2 * s - big) / (small + gap))
        let shift = max(0, index - visible)
        let offset = shift == 0 ? 0 : -(big + gap + CGFloat(shift - 1) * (small + gap))

        return HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(model.recent.enumerated()), id: \.element.id) { i, game in
                GameTile(game: game, scale: s)
                    .frame(width: i == 0 ? big : small, height: i == 0 ? big : small)
                    .focusFrame(focusedRow && index == i, scale: s)
                    .onTapGesture { model.tapHome(row: 0, index: i) }
            }
            AllGamesTile(count: model.games.count, scale: s)
                .frame(width: small, height: small)
                .focusFrame(focusedRow && index == model.recent.count, scale: s)
                .onTapGesture { model.tapHome(row: 0, index: model.recent.count) }
        }
        .offset(x: offset)
        .animation(.easeOut(duration: 0.18), value: shift)
        .frame(height: big, alignment: .bottom)
    }

    private func shortcutRow(_ s: CGFloat) -> some View {
        let focusedRow = model.homeRow == 1
        return HStack(spacing: 18 * s) {
            ForEach(Array(model.shortcuts.enumerated()), id: \.element.id) { i, item in
                let focused = focusedRow && model.homeIndex[1] == i
                VStack(spacing: 12 * s) {
                    Image(systemName: item.symbol)
                        .font(.system(size: 38 * s))
                    Text(item.title)
                        .font(.system(size: 17 * s, weight: .medium))
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 196 * s, height: 120 * s)
                .background(focused ? Theme.accent : Theme.tile.opacity(0.85))
                .overlay(alignment: .topTrailing) {
                    if item.id == "social", model.unreadConversations > 0 {
                        Text("\(model.unreadConversations)")
                            .font(.system(size: 14 * s, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 26 * s, minHeight: 26 * s)
                            .background(Theme.accentBright, in: Circle())
                            .padding(8 * s)
                    }
                }
                .focusFrame(focused, scale: s)
                .contentShape(Rectangle())
                .onTapGesture { model.tapHome(row: 1, index: i) }
            }
        }
    }

    private func statusLine(_ game: Game) -> String {
        switch game.installState {
        case .installed: return "Ready to play"
        case .notInstalled: return game.access == .gamePass ? "Game Pass · Not installed" : "Not installed"
        case .downloading(let p):
            switch model.downloads.task(game.id)?.status {
            case .paused: return "Download paused"
            case .stopped: return "Download stopped"
            case .failed: return "Download failed"
            case .queued: return "Waiting to download"
            default: return "Downloading \(Int(p * 100))%"
            }
        }
    }
}

/// The background art. It changes with a cross-fade when the focus moves.
struct HeroBackground: View {
    let game: Game?

    var body: some View {
        ZStack {
            if let game {
                GameArt(game: game, hero: true, width: 1920)
                    .id(game.id)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.background],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                    .transition(.opacity)
            }
            // Dark scrim so that text and tiles stay readable.
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55), .black.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .center)
        }
        .animation(.easeInOut(duration: 0.3), value: game?.id)
    }
}

struct GameTile: View {
    let game: Game
    let scale: CGFloat

    var body: some View {
        let s = scale
        GameArt(game: game, width: 600)
            .overlay(alignment: .bottomLeading) {
                // Box art has the title in it. Show text only on placeholder art.
                if game.tileArt == nil {
                    Text(game.title)
                        .font(.system(size: 18 * s, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .padding(12 * s)
                }
            }
            .overlay(alignment: .topLeading) {
                if game.access == .gamePass {
                    Text("GAME PASS")
                        .font(.system(size: 11 * s, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7 * s)
                        .padding(.vertical, 3 * s)
                        .background(Theme.accent)
                }
            }
            .overlay(alignment: .topTrailing) {
                if game.installState == .notInstalled {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 16 * s, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8 * s)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(8 * s)
                }
            }
            .overlay(alignment: .bottom) {
                if case .downloading(let p) = game.installState {
                    ProgressStrip(progress: p, scale: s)
                }
            }
    }
}

struct AllGamesTile: View {
    let count: Int
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(spacing: 14 * s) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 48 * s))
            Text("My games & apps")
                .font(.system(size: 17 * s, weight: .medium))
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.tile)
    }
}
