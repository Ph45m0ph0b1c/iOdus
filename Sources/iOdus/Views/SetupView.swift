import SwiftUI

/// The setup after the sign-in: Rosetta, then the game runtime. The steps
/// that are done do not show. A, the mouse, or a click selects an item.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    let flow: SetupFlow
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            LinearGradient(colors: [Theme.accent.opacity(0.40), Theme.background],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: .leading, spacing: 28 * s) {
                stepBar(s)
                switch flow.step {
                case .rosetta: rosetta(s)
                case .runtime: runtime(s)
                case .wineRuntime: wineRuntime(s)
                case .vcRuntime: vcRuntime(s)
                case nil: EmptyView()
                }
                if let error = flow.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 19 * s, weight: .medium))
                        .foregroundStyle(Theme.buttonY)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(56 * s)
            .frame(width: 1120 * s, alignment: .leading)
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14 * s))
            .overlay(RoundedRectangle(cornerRadius: 14 * s).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }

    // MARK: Step bar

    /// "Setup" and, when there is more than one step, the steps in order.
    private func stepBar(_ s: CGFloat) -> some View {
        HStack(spacing: 12 * s) {
            Text("SETUP")
                .font(.system(size: 15 * s, weight: .bold))
                .tracking(2 * s)
                .foregroundStyle(Theme.accentBright)
            if flow.steps.count > 1 {
                ForEach(Array(flow.steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 8 * s) {
                        Image(systemName: i < flow.index ? "checkmark.circle.fill" : "\(i + 1).circle.fill")
                        Text(step.title)
                    }
                    .font(.system(size: 15 * s, weight: .semibold))
                    .foregroundStyle(i == flow.index ? Color.white : Theme.textSecondary)
                    .opacity(i > flow.index ? 0.6 : 1)
                }
            }
            Spacer(minLength: 0)
            if let step = flow.step, step.isOptional {
                Text(step == .vcRuntime ? "OPTIONAL · RECOMMENDED" : "OPTIONAL")
                    .font(.system(size: 13 * s, weight: .bold))
                    .tracking(1 * s)
                    .padding(.horizontal, 10 * s)
                    .frame(height: 24 * s)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Rosetta

    @ViewBuilder
    private func rosetta(_ s: CGFloat) -> some View {
        header("Install Rosetta", symbol: "cpu",
               "The game runtime is an Intel program. macOS runs it with Rosetta, and Rosetta is not installed on this Mac.", s)
        VStack(alignment: .leading, spacing: 10 * s) {
            Text("macOS asks for an administrator password. You can also run this command in Terminal:")
                .font(.system(size: 17 * s))
                .foregroundStyle(Theme.textSecondary)
            Text("softwareupdate --install-rosetta --agree-to-license")
                .font(.system(size: 17 * s, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 16 * s)
                .padding(.vertical, 10 * s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6 * s))
        }
        if flow.rosettaBusy {
            busy("Installing Rosetta. Use the macOS window to continue.", s)
        } else {
            HStack(spacing: 16 * s) {
                button("Install Rosetta", symbol: "arrow.down.circle", item: .installRosetta, primary: true, s)
                button("Check again", symbol: "arrow.clockwise", item: .checkRosetta, s)
                button("Not now", item: .notNow, s)
            }
        }
    }

    // MARK: Game runtime

    @ViewBuilder
    private func runtime(_ s: CGFloat) -> some View {
        if flow.rosetta == .notAppleSilicon {
            header("This Mac cannot run games", symbol: "exclamationmark.triangle",
                   "The Game Porting Toolkit needs a Mac with Apple silicon. You can still use your library, your friends, your messages, and the Store.", s)
            button("Continue", item: .notNow, primary: true, s)
        } else {
            switch flow.runtime {
            case .choose: runtimeChoice(s)
            case .downloading(let done, let total):
                header("Downloading the Game Porting Toolkit", symbol: "arrow.down.circle",
                       "iOdus downloads the Game Porting Toolkit \(GPTKRelease.pinned.version) from GitHub.", s)
                progress(done: done, total: total, s)
                button("Cancel", item: .cancel, s)
            case .verifying:
                header("Checking the download", symbol: "checkmark.shield", nil, s)
                busy("iOdus compares the SHA-256 of the file with the pinned value.", s)
            case .extracting:
                header("Installing the Game Porting Toolkit", symbol: "shippingbox", nil, s)
                busy("iOdus extracts the Game Porting Toolkit. This can take a minute.", s)
            case .copying:
                header("Copying the Game Porting Toolkit", symbol: "doc.on.doc", nil, s)
                busy("iOdus copies the Game Porting Toolkit into its own folder.", s)
            }
        }
    }

    @ViewBuilder
    private func runtimeChoice(_ s: CGFloat) -> some View {
        let release = GPTKRelease.pinned
        header("Install the Game Porting Toolkit", symbol: "gamecontroller",
               "iOdus runs Windows games with Apple's Game Porting Toolkit: Wine with D3DMetal.", s)

        facts([("Version", release.version), ("Download", Bytes.text(release.size)),
               ("Source", "Gcenx build on GitHub"), ("Check", "SHA-256")], s)

        VStack(alignment: .leading, spacing: 16 * s) {
            VStack(alignment: .leading, spacing: 6 * s) {
                Text("Apple's license")
                    .font(.system(size: 20 * s, weight: .semibold))
                Text("D3DMetal is Apple software under Apple's license. Wine is free software under the GNU LGPL. Read the license before you continue.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16 * s) {
                button("Read the license", symbol: "doc.text", item: .openLicense, s)
                checkbox(s)
            }
            HStack(spacing: 28 * s) {
                link("Game Porting Toolkit at Apple", symbol: "safari", url: GPTKRelease.appleURL, s)
                link("Release notes", symbol: "shippingbox", url: GPTKRelease.releaseURL, s)
            }
        }

        let other = flow.existing.filter { !$0.matches }
        if !other.isEmpty {
            Text(other.map { "\($0.app.path) has version \($0.version ?? "unknown"). iOdus needs \(release.version)." }
                    .joined(separator: "\n"))
                .font(.system(size: 16 * s))
                .foregroundStyle(Theme.textSecondary)
        }

        Divider().overlay(Color.white.opacity(0.12))

        let hasCopy = flow.items.contains { if case .useExisting = $0 { return true } else { return false } }
        HStack(spacing: 16 * s) {
            ForEach(flow.items.filter { if case .useExisting = $0 { return true } else { return false } }, id: \.key) { item in
                if case .useExisting(let i) = item {
                    button("Use the copy in \(Self.place(flow.existing[i].app))", symbol: "doc.on.doc",
                           item: item, primary: true, dimmed: !flow.licenseAccepted, s)
                }
            }
            button("Download (\(Bytes.text(release.size)))", symbol: "arrow.down.circle", item: .download,
                   primary: !hasCopy, dimmed: !flow.licenseAccepted, s)
            button("Not now", item: .notNow, s)
            Spacer(minLength: 0)
            if !flow.licenseAccepted {
                Text("Accept the license to continue.")
                    .font(.system(size: 16 * s))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Wine 11 runtime

    @ViewBuilder
    private func wineRuntime(_ s: CGFloat) -> some View {
        if let download = flow.wineDownload {
            switch flow.runtime {
            case .choose:
                header("Install the Wine 11 runtime", symbol: "square.stack.3d.up",
                       "A newer Wine with better game and controller support. Some games need it, for example Hades II.", s)
                facts([("Version", "Wine \(download.wineVersion) · \(download.name.replacingOccurrences(of: " Wine", with: ""))"),
                       ("Download", Bytes.text(download.size)),
                       ("On disk", Bytes.text(download.unpackedBytes)),
                       ("Check", "SHA-256")], s)
                Text(flow.wineReady
                     ? "iOdus adds D3DMetal from the Game Porting Toolkit and uses this runtime as the default. You can change the runtime of each game in Settings > Runtimes."
                     : "This runtime uses D3DMetal from the Game Porting Toolkit. Install the Game Porting Toolkit first.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(s) {
                    if flow.wineReady {
                        button("Install (\(Bytes.text(download.size)))", symbol: "arrow.down.circle", item: .install, primary: true, s)
                    }
                    button("Skip", item: .skip, primary: !flow.wineReady, s)
                }
            case .downloading(let done, let total):
                header("Downloading the Wine 11 runtime", symbol: "arrow.down.circle",
                       "iOdus downloads \(download.displayName) from GitHub.", s)
                progress(done: done, total: total, s)
                button("Cancel", item: .cancel, s)
            case .verifying, .extracting, .copying:
                header("Installing the Wine 11 runtime", symbol: "shippingbox", nil, s)
                busy("iOdus checks the SHA-256, extracts the runtime, and adds D3DMetal. This can take a minute.", s)
            }
        }
    }

    // MARK: Visual C++

    @ViewBuilder
    private func vcRuntime(_ s: CGFloat) -> some View {
        header("Install the Visual C++ runtime", symbol: "puzzlepiece.extension",
               "Microsoft's Visual C++ 2015-2022 runtime. Some games do not start without it.", s)
        facts([("Publisher", "Microsoft"),
               ("Download", "About 25 MB"),
               ("Check", "Microsoft's SHA-256"),
               ("Install", flow.vcInstallsNow ? "Now" : "At the first game")], s)
        Text(flow.vcInstallsNow
             ? "iOdus downloads Microsoft's installer and installs it in each game prefix now. You can change this in Settings."
             : "iOdus downloads Microsoft's installer when it makes a game prefix, at the first start of a game. You can change this in Settings.")
            .font(.system(size: 17 * s))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        actions(s) {
            button(flow.vcInstallsNow ? "Install now" : "Install at the first game", symbol: "checkmark.circle",
                   item: .install, primary: true, s)
            button("Skip", item: .skip, s)
        }
    }

    // MARK: Shared parts

    /// The facts row: up to four labeled columns.
    private func facts(_ items: [(String, String)], _ s: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in fact(item.0, item.1, s) }
        }
        .padding(.vertical, 18 * s)
        .padding(.horizontal, 22 * s)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8 * s))
    }

    /// A line, then the buttons of a step.
    private func actions<Content: View>(_ s: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 28 * s) {
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 16 * s) { content() }
        }
    }

    private func progress(done: Int64, total: Int64, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            ProgressStrip(progress: total > 0 ? Double(done) / Double(total) : 0, scale: s)
                .frame(maxWidth: .infinity)
                .clipShape(Capsule())
            Text("\(Bytes.text(done)) of \(Bytes.text(total)) · \(total > 0 ? Int(Double(done) * 100 / Double(total)) : 0)%")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
    }

    /// A text link for the mouse. (SwiftUI Link does not draw in snapshots.)
    private func link(_ title: String, symbol: String, url: URL, _ s: CGFloat) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 17 * s, weight: .medium))
            .foregroundStyle(Theme.accentBright)
            .contentShape(Rectangle())
            .onTapGesture { NSWorkspace.shared.open(url) }
    }

    /// "/Applications" or "~/Applications" for a button label.
    static func place(_ app: URL) -> String {
        app.deletingLastPathComponent().path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    // MARK: Parts

    /// The icon, the title, and an optional short text of a step.
    private func header(_ title: String, symbol: String, _ text: String?, _ s: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 24 * s) {
            Image(systemName: symbol)
                .font(.system(size: 34 * s, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76 * s, height: 76 * s)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16 * s))
            VStack(alignment: .leading, spacing: 6 * s) {
                Text(title)
                    .font(.system(size: 40 * s, weight: .bold))
                if let text {
                    Text(text)
                        .font(.system(size: 19 * s))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One column of the facts row: a small label over a value.
    private func fact(_ label: String, _ value: String, _ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4 * s) {
            Text(label.uppercased())
                .font(.system(size: 13 * s, weight: .bold))
                .tracking(1 * s)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 18 * s, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func busy(_ text: String, _ s: CGFloat) -> some View {
        HStack(spacing: 14 * s) {
            ProgressView().controlSize(.small).tint(.white)
            Text(text)
        }
        .font(.system(size: 19 * s))
        .foregroundStyle(Theme.textSecondary)
    }

    private func checkbox(_ s: CGFloat) -> some View {
        let focused = flow.focusedItem == .license
        let on = flow.licenseAccepted
        return HStack(spacing: 14 * s) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 26 * s))
                .foregroundStyle(on ? Theme.accentBright : (focused ? Color.black : .white))
            Text("I accept Apple's license for D3DMetal")
                .font(.system(size: 20 * s, weight: .semibold))
        }
        .foregroundStyle(focused ? Color.black : .white)
        .padding(.horizontal, 22 * s)
        .frame(height: 58 * s)
        .background(focused ? Color.white : Theme.tile.opacity(0.9))
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSetup(.license) }
    }

    /// A focusable button. `dimmed` shows a button that needs the license first.
    private func button(_ title: String, symbol: String? = nil, item: SetupItem, primary: Bool = false,
                        dimmed: Bool = false, _ s: CGFloat) -> some View {
        let focused = flow.focusedItem == item
        return HStack(spacing: 10 * s) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 20 * s, weight: .semibold))
        .foregroundStyle(focused && !primary ? Color.black : .white)
        .padding(.horizontal, 28 * s)
        .frame(height: 58 * s)
        .background(primary ? Theme.accent : (focused ? Color.white : Theme.tile.opacity(0.9)))
        .opacity(dimmed && !focused ? 0.45 : 1)
        .focusFrame(focused, scale: s, radius: 4)
        .contentShape(Rectangle())
        .onTapGesture { model.tapSetup(item) }
    }
}

private extension SetupItem {
    /// A stable ID for ForEach.
    var key: String {
        switch self {
        case .useExisting(let i): return "existing-\(i)"
        default: return String(describing: self)
        }
    }
}
