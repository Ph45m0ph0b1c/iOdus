import SwiftUI

/// The top bar: the profile on the left, the status and the clock on the right.
struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 16 * s) {
            if model.canGoBack {
                Image(systemName: "chevron.left")
                    .font(.system(size: 24 * s, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 52 * s, height: 52 * s)
                    .background(Color.white.opacity(0.10), in: Circle())
                    .contentShape(Circle())
                    .onTapGesture { model.back() }
                    .help("Back")
            }
            if !model.gamertag.isEmpty {
                avatar(s)
                VStack(alignment: .leading, spacing: 2 * s) {
                    Text(model.gamertag)
                        .font(.system(size: 22 * s, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6 * s) {
                        if let score = model.gamerscore {
                            GamerscoreMark(size: 16 * s)
                            Text(score.grouped)
                                .monospacedDigit()
                            Text("·")
                        }
                        Text("\(model.games.count) games")
                    }
                    .font(.system(size: 17 * s, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            HStack(spacing: 26 * s) {
                BellIndicator(unread: model.notifications.filter { !$0.read }.count, scale: s)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.statusPanel == .notifications { model.statusPanel = nil } else { model.openNotifications() }
                    }
                    .help("Notifications")
                ControllerIndicator(controllers: model.controllers, scale: s)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleStatusPanel(.controllers) }
                    .help("Controllers")
                NetworkIndicator(status: model.network, scale: s)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleStatusPanel(.network) }
                    .help("Network")
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                }
            }
            .font(.system(size: 22 * s, weight: .regular))
            .foregroundStyle(Theme.textPrimary)
        }
        .overlay { gameSearch(s) }
    }

    /// The game search at the top middle, on the home screen and in the library.
    @ViewBuilder
    private func gameSearch(_ s: CGFloat) -> some View {
        switch model.screen {
        case .home where model.account == .ready && model.setup == nil:
            SearchBar(text: "", placeholder: "Search your games", focused: false, busy: false, scale: s,
                      onTap: { model.openLibrarySearch() }, onClear: {})
                .frame(width: 520 * s)
        case .library:
            SearchBar(text: model.librarySearch, placeholder: "Search your games",
                      focused: model.libraryFocus == .search, busy: false, scale: s,
                      onTap: { model.tapSearch() }, onClear: { model.clearSearch() })
                .frame(width: 520 * s)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func avatar(_ s: CGFloat) -> some View {
        if let picture = model.gamerpic {
            Image(nsImage: picture)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52 * s, height: 52 * s)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(LinearGradient(colors: [Theme.accentBright, Theme.accent],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 52 * s, height: 52 * s)
                .overlay(
                    Text(String(model.gamertag.prefix(1)).uppercased())
                        .font(.system(size: 24 * s, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
    }
}

/// A plain "G" in a circle for gamerscore. Not the Microsoft mark.
struct GamerscoreMark: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .stroke(Theme.textSecondary, lineWidth: max(1, size * 0.12))
            .frame(width: size, height: size)
            .overlay(Text("G").font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(Theme.textSecondary))
    }
}

enum FaceButton {
    case a, b, x, y

    var label: String {
        switch self { case .a: "A"; case .b: "B"; case .x: "X"; case .y: "Y" }
    }

    var color: Color {
        switch self { case .a: Theme.buttonA; case .b: Theme.buttonB; case .x: Theme.buttonX; case .y: Theme.buttonY }
    }
}

struct ButtonHint: Identifiable {
    let button: FaceButton
    let text: String
    var id: String { button.label }

    init(_ button: FaceButton, _ text: String) {
        self.button = button
        self.text = text
    }
}

/// The hint bar at the bottom right, as on the console. A click on a hint
/// does the same as the controller button, so a mouse can also go back.
struct ButtonHints: View {
    @EnvironmentObject private var model: AppModel
    let hints: [ButtonHint]
    let scale: CGFloat
    @State private var hovered: String?

    var body: some View {
        let s = scale
        HStack(spacing: 18 * s) {
            Spacer()
            ForEach(hints) { hint in
                HStack(spacing: 10 * s) {
                    Circle()
                        .fill(Color(white: 0.12))
                        .frame(width: 30 * s, height: 30 * s)
                        .overlay(
                            Text(hint.button.label)
                                .font(.system(size: 16 * s, weight: .bold))
                                .foregroundStyle(hint.button.color)
                        )
                    Text(hint.text)
                        .font(.system(size: 18 * s, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 12 * s)
                .padding(.vertical, 6 * s)
                .background(hovered == hint.id ? Color.white.opacity(0.12) : .clear,
                            in: Capsule())
                .contentShape(Capsule())
                .onHover { inside in hovered = inside ? hint.id : (hovered == hint.id ? nil : hovered) }
                .onTapGesture { press(hint.button) }
            }
        }
    }

    private func press(_ button: FaceButton) {
        switch button {
        case .a: model.confirm()
        case .b: model.back()
        case .x: model.xPressed()
        case .y: model.focusSearch()
        }
    }
}

/// The white focus ring with a small lift.
struct FocusFrame: ViewModifier {
    let focused: Bool
    let scale: CGFloat
    var radius: CGFloat = Theme.cornerRadius

    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: radius * scale))
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: (radius + 3) * scale)
                        .stroke(Theme.focusRing, lineWidth: 4 * scale)
                        .padding(-6 * scale)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
            .shadow(color: .black.opacity(focused ? 0.6 : 0), radius: 18 * scale, y: 8 * scale)
            .zIndex(focused ? 1 : 0)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

extension View {
    func focusFrame(_ focused: Bool, scale: CGFloat, radius: CGFloat = Theme.cornerRadius) -> some View {
        modifier(FocusFrame(focused: focused, scale: scale, radius: radius))
    }
}

/// A thin download bar for a tile.
struct ProgressStrip: View {
    let progress: Double
    let scale: CGFloat

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.55))
                Rectangle().fill(Theme.accentBright).frame(width: g.size.width * progress)
            }
        }
        .frame(height: 6 * scale)
    }
}

// MARK: - Scrolling lists

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while `--snapshot` renders a frame. ImageRenderer cannot draw a
    /// ScrollView, so lists then use an offset layout.
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// A vertical list area with native, smooth scrolling for the mouse and the
/// trackpad. When the focus moves (D-pad or keys), the list scrolls only as far
/// as necessary to show the focused item, with a short animation. Each item
/// needs `.id(index)`. The area has extra space at the sides and the top for
/// the focus frame, which is larger than its item.
extension View {
    /// The scroll target of FocusScroll (the row or tile index). The ID sits on an
    /// invisible background, so that the view keeps the identity of its item.
    /// With .id(index) on the view itself, a new filter or a new order kept the old
    /// views at the same positions (old art, old icons, a correct count).
    func scrollAnchor(_ index: Int) -> some View {
        background(Color.clear.id(index))
    }
}

struct FocusScroll<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshotMode
    let focus: Int?
    let height: CGFloat
    let snapshotShift: CGFloat
    let scale: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        let s = scale
        let side = 60 * s, top = 16 * s
        Group {
            if snapshotMode {
                content()
                    .offset(y: -snapshotShift)
                    .padding(.horizontal, side)
                    .padding(.vertical, top)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: height + 2 * top, alignment: .top)
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        content()
                            .padding(.horizontal, side)
                            .padding(.vertical, top)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: height + 2 * top)
                    .onChange(of: focus) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(new) }
                    }
                }
            }
        }
        .padding(.horizontal, -side)
        .padding(.top, -top)
    }
}
