import AppKit
import SwiftUI

/// The popup for one unlocked achievement.
struct AchievementPopupView: View {
    static let size = CGSize(width: 440, height: 80)

    let name: String
    let gamerscore: Int
    let game: String
    let icon: URL?

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accent)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                if let icon {
                    AsyncImage(url: icon) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .clipShape(Circle())
                }
            }
            .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text("Achievement unlocked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentBright)
                Text("\(gamerscore) G – \(name)")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(game)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
        .padding(.trailing, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Capsule().fill(Color(white: 0.10)))
        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
    }
}

/// Shows achievement popups at the bottom center of the screen, one after the
/// other. The panel floats above a full-screen game, does not take the focus,
/// and does not get mouse clicks.
@MainActor
final class AchievementPopup {
    static let shared = AchievementPopup()
    static let visibleSeconds: Double = 6

    private var panel: NSPanel?
    private var queue: [AchievementPopupView] = []
    private var showing = false

    func show(_ view: AchievementPopupView) {
        queue.append(view)
        if !showing { next() }
    }

    private func next() {
        guard !queue.isEmpty else {
            showing = false
            panel?.orderOut(nil)
            return
        }
        showing = true
        let view = queue.removeFirst()
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        place(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in self.next() }
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: AchievementPopupView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    /// The screen of the key window (the game), at the bottom center.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let size = AchievementPopupView.size
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 90,
                              width: size.width, height: size.height), display: true)
    }
}
