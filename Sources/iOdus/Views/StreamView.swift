import SwiftUI
import WebKit

/// The web view of one cloud stream. It keeps the website data (the
/// Microsoft sign-in) in the default store, the same as Safari keeps it.
@MainActor
final class StreamWebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    /// The user agent of Safari 18 on macOS. The web player supports Safari.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    let webView: WKWebView
    private let onReport: (PageReport) -> Void

    init(onReport: @escaping (PageReport) -> Void) {
        self.onReport = onReport
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: StreamPage.mediaDevicesScript, injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false))
        content.addUserScript(WKUserScript(source: StreamPage.script(), injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true))
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        super.init()
        content.add(MessageProxy(self), name: StreamPage.messageName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    /// Gives the keyboard to the web player.
    func focus() {
        webView.window?.makeFirstResponder(webView)
    }

    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: StreamPage.messageName)
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        // Give the keyboard back to the iOdus screens.
        NSApp.windows.first?.makeFirstResponder(nil)
    }

    fileprivate func received(_ body: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let report = try? JSONDecoder().decode(PageReport.self, from: data) else { return }
        onReport(report)
    }

    /// A page that opens a new window (for example a sign-in pop-up) opens in this view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

/// WKUserContentController keeps a strong reference to its handler.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: StreamWebController?
    init(_ target: StreamWebController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}

private struct StreamWebView: NSViewRepresentable {
    let controller: StreamWebController

    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

/// The stream screen: the web player, the iOdus cover while the stream
/// starts, the frame for the sign-in, and the iOdus menu.
struct StreamOverlay: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.snapshotMode) private var snapshotMode
    let session: StreamSession
    let scale: CGFloat

    var body: some View {
        let s = scale
        let signIn = session.phase == .signIn
        ZStack {
            Color.black
            // One web view in one place, so that it keeps its page when the frame changes.
            Group {
                if let web = model.streamWeb, !snapshotMode {
                    StreamWebView(controller: web)
                } else {
                    Color(white: signIn ? 0.95 : 0.0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: signIn ? 10 * s : 0))
            .padding(.horizontal, signIn ? 120 * s : 0)
            .padding(.top, signIn ? 150 * s : 0)
            .padding(.bottom, signIn ? 60 * s : 0)

            if signIn { SignInFrame(scale: s) }
            if session.covered { StreamCover(session: session, game: model.game(session.gameID), scale: s) }
            if session.phase == .pageShown && !session.menuOpen { PageBanner(scale: s) }
            if session.menuOpen { StreamMenu(session: session, scale: s) }
        }
        .ignoresSafeArea()
    }
}

/// The text for the menu keys, in one place.
private let menuKeysText = "Hold B, press the Xbox button, or press Shift+Esc for the menu"

/// The frame around the real Microsoft sign-in page. iOdus does not change,
/// fill, or imitate that page; it only shows where the page comes from.
private struct SignInFrame: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
                Text("Sign in for cloud gaming")
                    .font(.system(size: 34 * s, weight: .semibold))
                Spacer()
                Text("Cancel")
                    .font(.system(size: 18 * s, weight: .semibold))
                    .padding(.horizontal, 22 * s)
                    .frame(height: 40 * s)
                    .background(Theme.tile, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { model.stopStream(message: nil) }
            }
            HStack(spacing: 8 * s) {
                Image(systemName: "lock.fill")
                Text(model.streamWeb?.webView.url?.host ?? "www.xbox.com")
                Text("·")
                Text("This is the Microsoft page. iOdus does not see your password.")
            }
            .font(.system(size: 17 * s))
            .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 120 * s)
        .padding(.top, 50 * s)
    }
}

/// The iOdus screen in front of the page while the stream starts.
private struct StreamCover: View {
    let session: StreamSession
    let game: Game?
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack(alignment: .bottomLeading) {
            HeroBackground(game: game)
            VStack(alignment: .leading, spacing: 18 * s) {
                Text(session.title)
                    .font(.system(size: 64 * s, weight: .bold))
                status(s)
                    .font(.system(size: 24 * s, weight: .medium))
                Text(menuKeysText)
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 20 * s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.bottom, 120 * s)
        }
    }

    @ViewBuilder
    private func status(_ s: CGFloat) -> some View {
        switch session.phase {
        case .queue(let text):
            HStack(spacing: 14 * s) {
                Image(systemName: "person.3.fill").foregroundStyle(Theme.accentBright)
                Text(text)
            }
        case .failed(let text):
            HStack(spacing: 14 * s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.buttonY)
                Text(text)
            }
        default:
            HStack(spacing: 14 * s) {
                ProgressView().controlSize(.regular).tint(.white)
                Text("Starting the stream…")
            }
        }
    }
}

/// The page shows because the stream did not start by itself.
private struct PageBanner: View {
    let scale: CGFloat

    var body: some View {
        let s = scale
        VStack {
            HStack(spacing: 12 * s) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.accentBright)
                Text("The stream did not start by itself. Use the page to start it.")
                Text("·").foregroundStyle(Theme.textSecondary)
                Text(menuKeysText).foregroundStyle(Theme.textSecondary)
            }
            .font(.system(size: 17 * s, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 22 * s)
            .padding(.vertical, 12 * s)
            .background(Color(white: 0.12).opacity(0.95), in: Capsule())
            .padding(.top, 24 * s)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// The iOdus menu in front of the stream.
private struct StreamMenu: View {
    @EnvironmentObject private var model: AppModel
    let session: StreamSession
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack {
            Color.black.opacity(0.6)
                .onTapGesture { model.back() }
            VStack(alignment: .leading, spacing: 14 * s) {
                Text(session.title)
                    .font(.system(size: 30 * s, weight: .semibold))
                Text("Cloud stream")
                    .font(.system(size: 18 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 8 * s)
                ForEach(Array(session.menuItems.enumerated()), id: \.offset) { i, item in
                    let focused = session.menuIndex == i
                    HStack(spacing: 14 * s) {
                        Image(systemName: symbol(item))
                            .frame(width: 26 * s)
                        Text(session.menuTitle(item))
                        Spacer()
                    }
                    .font(.system(size: 21 * s, weight: .semibold))
                    .foregroundStyle(focused ? Color.black : .white)
                    .padding(.horizontal, 20 * s)
                    .frame(height: 58 * s)
                    .background(focused ? Color.white : Theme.tile)
                    .focusFrame(focused, scale: s, radius: 4)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tapStreamMenu(i) }
                }
                HStack(spacing: 20 * s) {
                    hint("A", Theme.buttonA, "Select", s)
                    hint("B", Theme.buttonB, "Close", s)
                }
                .padding(.top, 10 * s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(36 * s)
            .frame(width: 520 * s, alignment: .leading)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8 * s))
            .shadow(color: .black.opacity(0.6), radius: 30 * s)
        }
    }

    private func symbol(_ item: StreamMenuItem) -> String {
        switch item {
        case .resume: return "play.fill"
        case .showPage: return "safari"
        case .stop: return "stop.fill"
        }
    }

    private func hint(_ label: String, _ color: Color, _ text: String, _ s: CGFloat) -> some View {
        HStack(spacing: 8 * s) {
            Circle().fill(Color(white: 0.2)).frame(width: 26 * s, height: 26 * s)
                .overlay(Text(label).font(.system(size: 14 * s, weight: .bold)).foregroundStyle(color))
            Text(text).font(.system(size: 16 * s))
        }
    }
}
