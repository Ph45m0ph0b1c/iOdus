import SwiftUI

/// Settings: the account, the install folder, and information about the backend.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 10 * s) {
            Text("Settings")
                .font(.system(size: 40 * s, weight: .semibold))
                .padding(.bottom, 6 * s)
            ForEach(SettingsRow.allCases, id: \.self) { row in
                rowView(row, s)
                    .focusFrame(model.settingsIndex == row.rawValue, scale: s)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapSettings(row.rawValue) }
            }
            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .frame(maxWidth: 1300 * s, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.sidePadding * s)
        .padding(.top, 150 * s)
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    private func rowView(_ row: SettingsRow, _ s: CGFloat) -> some View {
        let (symbol, title, detail, action) = content(row)
        return HStack(spacing: 24 * s) {
            Image(systemName: symbol)
                .font(.system(size: 30 * s))
                .frame(width: 56 * s)
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 24 * s, weight: .semibold))
                ForEach(detail, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 18 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if row == .fullScreen {
                SwitchView(on: AppSettings.startFullScreen, scale: s)
            } else if row == .updates {
                SwitchView(on: model.updateChecker.enabled, scale: s)
            } else if let action {
                Text(action)
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 22 * s)
        .padding(.vertical, 10 * s)
        .background(Theme.tile.opacity(0.9))
    }

    private func content(_ row: SettingsRow) -> (String, String, [String], String?) {
        switch row {
        case .account:
            let name = [model.gamertag, model.accountName].filter { !$0.isEmpty }.joined(separator: " · ")
            return ("person.crop.circle", "Account", [name.isEmpty ? "Signed in" : name], "Sign out")
        case .installFolder:
            let free = Bytes.freeSpace(at: model.downloads.installRoot).map { "\(Bytes.text($0)) free" }
            return ("folder", "Install folder", [model.installFolderText] + (free.map { [$0] } ?? []), "Change")
        case .rescan:
            return ("arrow.clockwise", "Rescan install folder",
                    ["Finds the games in the install folder that iOdus does not know, for example after a fresh install."],
                    "Rescan")
        case .fullScreen:
            return ("arrow.up.left.and.arrow.down.right", "Start in full screen", [], nil)
        case .performance:
            let mode = AppSettings.performanceOverlay
            let detail: String = switch mode {
            case .off: "FPS and system load while you play"
            case .fps: "FPS in the game window (Metal HUD) · FPS changes apply at the next game start"
            case .system: "CPU, GPU, memory, and temperature at the top left"
            case .full: "FPS in the game window, and the system panel · FPS changes apply at the next game start"
            }
            return ("speedometer", "Performance overlay", [detail], mode.title)
        case .updates:
            return ("arrow.down.app", "Check for updates", [], nil)
        case .runtime:
            return ("cpu", "Game runtime", model.runtimeStatus, "Prepare again")
        case .vcRuntime:
            let installed = model.vcRuntimeInstalled
            return ("shippingbox", "Microsoft Visual C++ runtime", [model.vcRuntimeStatus],
                    model.installingVCRuntime ? "Installing…" : (installed ? "Install again" : "Install"))
        case .backend:
            guard let info = model.backendInfo else {
                return ("server.rack", "Backend", ["Reading… · Store region \(model.market)"], nil)
            }
            return ("server.rack", "Backend",
                    ["\(info.version) · Store region \(model.market)"] + (info.source.map { [$0] } ?? []) + [info.path], nil)
        case .exportLogs:
            return ("doc.zipper", "Export logs",
                    ["Makes a zip file on the Desktop for a bug report, without passwords, tokens, or account names."],
                    model.exportingLogs ? "Exporting…" : "Export")
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            return ("info.circle", "About iOdus",
                    ["Version \(version ?? "development build") · Uses Xodus and the Game Porting Toolkit Wine"], nil)
        }
    }
}

/// An on/off switch in the iOdus style. The row handles A and the click.
struct SwitchView: View {
    let on: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        Capsule()
            .fill(on ? Theme.accent : Color(white: 0.32))
            .frame(width: 64 * s, height: 36 * s)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 28 * s, height: 28 * s)
                    .padding(4 * s)
                    .shadow(color: .black.opacity(0.3), radius: 2 * s, y: 1 * s)
            }
            .animation(.easeOut(duration: 0.15), value: on)
    }
}
