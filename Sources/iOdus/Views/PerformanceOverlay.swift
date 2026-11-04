import AppKit
import SwiftUI

/// What the performance overlay shows while a game runs.
enum PerformanceOverlayMode: String, CaseIterable, Codable {
    case off
    case fps    // Apple's Metal Performance HUD in the game window
    case system // The iOdus system panel only
    case full   // The Metal HUD and the iOdus system panel

    var title: String {
        switch self {
        case .off: "Off"
        case .fps: "FPS"
        case .system: "System"
        case .full: "FPS and system"
        }
    }

    /// True when the Metal HUD (FPS) is on. It applies only at the game start.
    var showsFPS: Bool { self == .fps || self == .full }

    /// True when the iOdus system panel shows. It applies at once.
    var showsSystem: Bool { self == .system || self == .full }

    var next: PerformanceOverlayMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Apple's Metal Performance HUD shows FPS and the frame time. D3DMetal renders
    /// with Metal, so the HUD works for the games. It applies at the game start.
    var gameEnvironment: [String: String] {
        showsFPS ? ["MTL_HUD_ENABLED": "1"] : [:]
    }
}

struct PerformancePanelView: View {
    static let size = CGSize(width: 300, height: 86)
    let sample: SystemSample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sample.lines, id: \.self) { line in
                Text(line)
            }
        }
        .font(.system(size: 14, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.62)))
    }
}

/// The system panel at the top left of the screen (the Metal HUD is at the top
/// right). It floats above a full-screen game, takes no focus, and gets no clicks.
/// It reads the system once each second while it shows.
@MainActor
final class PerformanceOverlay {
    static let shared = PerformanceOverlay()

    private var panel: NSPanel?
    private var timer: Timer?
    private let stats = SystemStats()

    /// Shows the panel while a game runs and the mode is "full"; hides it otherwise.
    func update(playing: Bool, mode: PerformanceOverlayMode) {
        if playing && mode.showsSystem {
            guard timer == nil else { return }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { PerformanceOverlay.shared.refresh() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            panel?.orderOut(nil)
        }
    }

    private func refresh() {
        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: PerformancePanelView(sample: stats.sample()))
        place(panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: PerformancePanelView.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let area = screen.frame
        let size = PerformancePanelView.size
        panel.setFrame(NSRect(x: area.minX + 20, y: area.maxY - size.height - 40,
                              width: size.width, height: size.height), display: true)
    }
}
