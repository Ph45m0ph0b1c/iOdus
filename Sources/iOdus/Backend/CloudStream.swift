import Foundation

// Cloud streaming through the official web player at xbox.com/play.
//
// iOdus opens the web player in a WKWebView and covers it with its own
// screens. A small page script reports the state of the page (loading, queue,
// sign-in, streaming, error) and presses the Play button. The script never
// touches the Microsoft sign-in pages: the user signs in on the real page.
//
// TEST VERSION. The page script depends on the structure of the web player,
// which Microsoft can change at any time. All text and element rules are in
// `StreamPage.Selectors`. When the stream does not start, iOdus shows the page
// after `StreamSession.fallbackSeconds`, so that the user can still press Play.

/// The addresses of the web player.
enum CloudStream {
    /// The "All games" cloud list of the web player (Gallery "all-games",
    /// CloudAll in the player script). It also has "stream your own game" titles.
    static let cloudListID = "1bf84c2b-0643-4591-893f-d9edb703f692"
    /// The platform value of the web player for the list (SiglPlatform.CloudGPUWeb).
    static let cloudPlatform = "Cloud:XGPUWEB"

    /// The stream route of the web player: /<locale>/play/launch/<name>/<product ID>.
    /// The player finds the game from the product ID; the name is only for people.
    static func launchURL(productId: String, title: String, locale: String = "en-US") -> URL {
        let id = productId.uppercased().filter { $0.isLetter || $0.isNumber }
        let name = slug(title)
        let path = name.isEmpty ? "/\(locale)/play/launch/\(id)" : "/\(locale)/play/launch/\(name)/\(id)"
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.xbox.com"
        components.path = path
        return components.url!
    }

    /// "DREDGE: Deluxe Edition" -> "dredge-deluxe-edition"
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var out = ""
        for scalar in folded.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out += "-"
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// "en_US" -> "en-US". Other forms give "en-US".
    static func locale(from identifier: String) -> String {
        let base = identifier.split(separator: "@").first.map(String.init) ?? identifier
        let parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard parts.count >= 2, parts[0].count == 2, parts[1].count == 2 else { return "en-US" }
        return "\(parts[0].lowercased())-\(parts[1].uppercased())"
    }

    /// The hosts that are always shown to the user, never covered or changed.
    static let signInHosts = ["login.live.com", "login.microsoftonline.com", "account.live.com",
                              "login.microsoft.com", "account.microsoft.com"]
}

/// The page script and its rules.
enum StreamPage {
    /// All rules that depend on the web player page. Keep them here, so that a
    /// change of the page needs a change in one place only.
    struct Selectors: Encodable {
        /// The stream is a <video> element that plays a WebRTC MediaStream (srcObject).
        /// Other videos, for example the Xbox logo while the stream connects, have a
        /// normal file source and do not count.
        var video = "video"
        /// The elements that can be a button.
        var buttons = "button, [role=\"button\"], a"
        /// Buttons that start the stream. The script compares the full label, lower case.
        var playTexts = ["play", "play now", "continue", "start"]
        /// A "Sign in" button means that the player has no account. The script only reports it.
        var signInTexts = ["sign in"]
        /// xbox.com pages of the sign-in itself. "SIGN IN" opens /<locale>/auth/msa?action=logIn,
        /// which then goes to login.live.com. The script reports them as the sign-in and does nothing.
        var authPaths = ["/auth/"]
        /// Text of the queue screen ("Lots of people are playing! Wait time is about …").
        var queueTexts = ["wait time is about", "almost there", "in the queue"]
        /// Dialogs that can hold an error.
        var dialogs = "[role=\"dialog\"], [role=\"alertdialog\"], [aria-live=\"assertive\"]"
        /// Text in a dialog that means that the stream failed.
        var errorTexts = ["something went wrong", "couldn't", "can't", "isn't available", "is not available",
                          "not available in your region", "error code", "unable to"]
        /// Page parts that are hidden while the stream plays.
        var hideCSS = "header, footer, nav, [role=\"banner\"], [role=\"contentinfo\"], [role=\"navigation\"] { display: none !important; }"
        /// The script presses Play at most this many times, with this many milliseconds between.
        var maxClicks = 5
        var clickGapMs = 3000
        /// Checks (one each second) without a playing video before the stream counts as ended.
        /// A short reconnect of the stream must not close it.
        var endedAfterChecks = 10
        var signInHosts = CloudStream.signInHosts
    }

    static let messageName = "iodus"

    /// A web view in an app has no navigator.mediaDevices without microphone
    /// permission. The guide of the web player (the Xbox button) calls
    /// enumerateDevices() for party chat and fails with "Unhandled Thrown Error".
    /// This stand-in, only on xbox.com and only when the object is missing,
    /// reports no devices and refuses microphone and camera access.
    static let mediaDevicesScript = """
    (function () {
      if (!/(^|\\.)xbox\\.com$/.test(location.hostname)) return;
      if (navigator.mediaDevices) return;
      const denied = () => Promise.reject(new DOMException("iOdus does not use the microphone or the camera.", "NotAllowedError"));
      const target = new EventTarget();
      const devices = {
        enumerateDevices: () => Promise.resolve([]),
        getUserMedia: denied,
        getDisplayMedia: denied,
        getSupportedConstraints: () => ({}),
        addEventListener: target.addEventListener.bind(target),
        removeEventListener: target.removeEventListener.bind(target),
        dispatchEvent: target.dispatchEvent.bind(target),
        ondevicechange: null
      };
      try { Object.defineProperty(Navigator.prototype, "mediaDevices", { get: () => devices, configurable: true }); } catch (e) {}
    })();
    """

    /// The page script. It runs in the main frame of each page.
    static func script(_ selectors: Selectors = Selectors()) -> String {
        let data = (try? JSONEncoder().encode(selectors)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return """
        (function () {
          if (window.__iodusStream) return;
          window.__iodusStream = true;
          const S = \(json);
          const host = location.hostname;
          const post = (state, text) => {
            try {
              window.webkit.messageHandlers.\(messageName).postMessage(
                { state: state, text: text || null, host: host, path: location.pathname });
            } catch (e) {}
          };
          // A sign-in or account page: report it, and do nothing else on the page.
          if (host !== "www.xbox.com" && host !== "xbox.com") { post("signIn"); return; }
          // An xbox.com page of the sign-in (it goes on to the Microsoft page): the same.
          if (S.authPaths.some((p) => location.pathname.toLowerCase().includes(p))) { post("signIn"); return; }

          let clicks = 0, lastClick = 0, streamed = false, missing = 0, last = "";
          const visible = (el) => {
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== "hidden";
          };
          const label = (el) => String(el.innerText || el.getAttribute("aria-label") || "").trim().toLowerCase();
          const findButton = (texts) => Array.from(document.querySelectorAll(S.buttons))
            .find((el) => visible(el) && texts.includes(label(el)));
          const lineWith = (root, texts) => {
            for (const line of String(root.innerText || "").split("\\n")) {
              const l = line.trim();
              if (l && texts.some((t) => l.toLowerCase().includes(t))) return l.slice(0, 200);
            }
            return null;
          };
          const hideMenus = () => {
            if (document.getElementById("iodus-hide")) return;
            const style = document.createElement("style");
            style.id = "iodus-hide";
            style.textContent = S.hideCSS;
            document.documentElement.appendChild(style);
          };
          const report = (state, text) => {
            const key = state + "|" + (text || "");
            if (key === last) return;
            last = key;
            post(state, text);
          };
          const tick = () => {
            const video = Array.from(document.querySelectorAll(S.video))
              .find((v) => v.videoWidth > 0 && v.readyState >= 2 && !v.paused &&
                           typeof MediaStream !== "undefined" && v.srcObject instanceof MediaStream);
            if (video) { streamed = true; missing = 0; hideMenus(); report("streaming"); return; }
            if (streamed) { if (++missing >= S.endedAfterChecks) report("ended"); return; }
            for (const d of document.querySelectorAll(S.dialogs)) {
              if (!visible(d)) continue;
              const error = lineWith(d, S.errorTexts);
              if (error) { report("error", error); return; }
            }
            const queue = document.body ? lineWith(document.body, S.queueTexts) : null;
            if (queue) { report("queue", queue); return; }
            // The user presses "Sign in" on the page. The script does not.
            if (findButton(S.signInTexts)) { report("signIn"); return; }
            const play = findButton(S.playTexts);
            if (play && clicks < S.maxClicks && Date.now() - lastClick > S.clickGapMs) {
              clicks++; lastClick = Date.now(); play.click();
            }
            report("loading");
          };
          setInterval(tick, 1000);
          tick();
        })();
        """
    }
}

/// One message from the page script.
struct PageReport: Equatable, Decodable {
    let state: String            // loading, signIn, queue, streaming, error, ended
    var text: String?
    var host: String?
    var path: String?

    var onLaunchPage: Bool { (path ?? "").lowercased().contains("/play/launch/") }
}

enum StreamPhase: Equatable {
    case loading                 // The cover: "Starting the stream…"
    case signIn                  // The real Microsoft page in the iOdus frame
    case queue(String)           // The cover with the wait text
    case streaming               // Only the game
    case pageShown               // The stream did not start: the page without the cover
    case failed(String)          // The cover with the error; the menu opens
}

enum StreamMenuItem: Equatable {
    case resume, showPage, stop
}

/// One cloud stream: the state machine of the stream screens. The web view
/// sends page reports and the timeout; the result tells the model what to do.
struct StreamSession: Equatable {
    static let fallbackSeconds: Double = 30

    enum Effect: Equatable {
        case none
        case reloadLaunch          // After the sign-in, open the stream address again
        case close(String)         // Stop the stream; show the text as a toast
    }

    let token = UUID()
    let gameID: String
    let title: String
    let url: URL
    var phase: StreamPhase = .loading
    var menuOpen = false
    var menuIndex = 0
    var everStreamed = false
    /// True after a report from a Microsoft sign-in host (login.live.com and others).
    /// Only then does a return to xbox.com mean that the sign-in is complete.
    var visitedSignInHost = false

    /// True when the cover hides the page.
    var covered: Bool {
        switch phase {
        case .loading, .queue, .failed: return true
        case .signIn, .streaming, .pageShown: return false
        }
    }

    /// While the stream screen is open and the iOdus menu is closed, the
    /// controller and the keyboard belong to the web player.
    var capturesInput: Bool { !menuOpen }

    var menuItems: [StreamMenuItem] {
        switch phase {
        case .loading, .queue: return [.resume, .showPage, .stop]
        case .failed: return [.showPage, .stop]
        case .signIn, .streaming, .pageShown: return [.resume, .stop]
        }
    }

    func menuTitle(_ item: StreamMenuItem) -> String {
        switch item {
        case .resume:
            switch phase {
            case .loading, .queue: return "Keep waiting"
            case .signIn: return "Back to the sign-in"
            default: return "Back to the stream"
            }
        case .showPage: return "Show the page"
        case .stop: return "Stop streaming"
        }
    }

    mutating func apply(_ report: PageReport) -> Effect {
        switch report.state {
        case "signIn":
            phase = .signIn
            if let host = report.host, CloudStream.signInHosts.contains(host.lowercased()) { visitedSignInHost = true }
        case "loading":
            if phase == .signIn {
                // Before the Microsoft page, a "loading" xbox.com page is a step of
                // the sign-in, not its end. A reload then stops the sign-in.
                guard visitedSignInHost else { break }
                visitedSignInHost = false
                phase = .loading
                // The sign-in can end on another xbox.com page.
                if !report.onLaunchPage { return .reloadLaunch }
            } else if case .queue = phase {
                phase = .loading
            }
        case "queue":
            if phase != .pageShown { phase = .queue(report.text ?? "Waiting for a free server…") }
        case "streaming":
            phase = .streaming
            everStreamed = true
        case "error":
            phase = .failed(report.text ?? "The stream did not start.")
            menuOpen = true
            menuIndex = 0
        case "ended":
            if everStreamed { return .close("The stream of \(title) ended.") }
        default:
            break
        }
        return .none
    }

    /// No stream after `fallbackSeconds`: show the page, so that the user can press Play.
    mutating func timeout() {
        if phase == .loading { phase = .pageShown }
    }

    mutating func openMenu() {
        menuOpen = true
        menuIndex = 0
    }

    mutating func moveMenu(_ d: Direction) {
        switch d {
        case .up, .left: menuIndex = max(0, menuIndex - 1)
        case .down, .right: menuIndex = min(menuItems.count - 1, menuIndex + 1)
        }
    }

    /// A on the menu. Returns true for Stop.
    mutating func chooseMenu() -> Bool {
        guard menuIndex < menuItems.count else { return false }
        let item = menuItems[menuIndex]
        menuOpen = false
        switch item {
        case .resume: return false
        case .showPage:
            phase = .pageShown
            return false
        case .stop: return true
        }
    }
}

/// Where an input goes while a stream screen is open.
enum StreamInputRoute: Equatable {
    case app            // iOdus handles it (no stream, or the menu is open)
    case web            // The web player gets it; iOdus ignores it
    case openMenu       // Hold B, the Xbox button, or Shift+Escape
}

enum StreamInput: Equatable {
    case holdB, guide, shiftEscape, other
}

enum StreamInputGate {
    static func route(_ input: StreamInput, session: StreamSession?) -> StreamInputRoute {
        guard let session else { return .app }
        if !session.capturesInput { return .app }
        switch input {
        case .holdB, .guide, .shiftEscape: return .openMenu
        case .other: return .web
        }
    }
}
