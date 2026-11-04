import Foundation

/// Cloud streaming through the web player (test version). See Backend/CloudStream.swift.
extension AppModel {
    /// The product ID of the open game page, or nil.
    var currentDetailID: String? {
        if case .detail(let id) = screen { return id }
        return nil
    }

    func isCloudGame(_ game: Game) -> Bool {
        streamProductID(game) != nil
    }

    /// The product ID for the web player: the game itself, or the edition in
    /// the cloud list that contains it.
    func streamProductID(_ game: Game) -> String? {
        let id = game.id.uppercased()
        if cloudProducts.contains(id) { return id }
        return cloudEditions[id]
    }

    /// For a game that is not in the cloud list: find its edition there.
    /// Public Store reads only, one time per game in a session.
    func resolveCloudEdition(_ game: Game) async {
        let id = game.id.uppercased()
        guard !demo, !cloudProducts.isEmpty, !cloudProducts.contains(id),
              !cloudEditionChecked.contains(id) else { return }
        cloudEditionChecked.insert(id)
        let catalog = StoreCatalog(session: ImageStore.shared.session, market: market)
        if let edition = try? await catalog.cloudEdition(for: id, title: game.title, cloud: cloudProducts) {
            cloudEditions[id] = edition
        }
    }

    func loadCloudGames() async {
        guard !demo else { return }
        let catalog = StoreCatalog(session: ImageStore.shared.session, market: market)
        if let ids = try? await catalog.cloudGames() { cloudProducts = ids }
    }

    func startStream(_ game: Game) {
        guard stream == nil else { return }
        guard playState == .idle else {
            showToast("A game runs on this Mac. Stop it before you stream.")
            return
        }
        let locale = CloudStream.locale(from: Locale.current.identifier)
        let product = streamProductID(game) ?? game.id
        let session = StreamSession(gameID: game.id, title: game.title,
                                    url: CloudStream.launchURL(productId: product, title: game.title, locale: locale))
        stream = session
        guard !demo else { return }
        StreamLog.start(title: game.title, url: session.url)
        let web = StreamWebController { [weak self] report in self?.streamReport(report) }
        streamWeb = web
        web.load(session.url)
        let token = session.token
        Task {
            try? await Task.sleep(for: .seconds(StreamSession.fallbackSeconds))
            guard stream?.token == token else { return }
            stream?.timeout()
        }
    }

    func streamReport(_ report: PageReport) {
        guard var session = stream else { return }
        let effect = session.apply(report)
        StreamLog.write("\(report.state) host=\(report.host ?? "-") path=\(report.path ?? "-")"
                        + (report.text.map { " text=\($0.prefix(120))" } ?? "") + " -> \(session.phase) \(effect)")
        stream = session
        switch effect {
        case .none: break
        case .reloadLaunch: streamWeb?.load(session.url)
        case .close(let text): stopStream(message: text)
        }
        if stream?.menuOpen == false { streamWeb?.focus() }
    }

    func openStreamMenu() {
        guard stream != nil else { return }
        stream?.openMenu()
    }

    func chooseStreamMenu() {
        guard var session = stream else { return }
        let stop = session.chooseMenu()
        stream = session
        if stop {
            stopStream(message: nil)
        } else {
            streamWeb?.focus()
        }
    }

    func tapStreamMenu(_ index: Int) {
        stream?.menuIndex = index
        chooseStreamMenu()
    }

    func stopStream(message: String?) {
        streamWeb?.close()
        streamWeb = nil
        stream = nil
        if let message { showToast(message, seconds: 5) }
    }
}

/// ~/Library/Logs/iOdus/Stream.log: the page reports of the last stream, for
/// problem reports. Only states, hosts, and paths (no query text, no sign-in data).
@MainActor
enum StreamLog {
    static var file: URL { GameLauncher.logFolder.appendingPathComponent("Stream.log") }

    static func start(title: String, url: URL) {
        try? FileManager.default.createDirectory(at: GameLauncher.logFolder, withIntermediateDirectories: true)
        try? Data().write(to: file)
        write("start \(title) \(url.path)")
    }

    static func write(_ line: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: false))
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(stamp) \(line)\n".utf8))
        try? handle.close()
    }
}
