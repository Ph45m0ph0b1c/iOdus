import Foundation

/// A Store package that is only a starter for another launcher. Some publishers
/// ship their PC Game Pass games this way: the package has one small
/// GDKStubGame.exe, which opens the publisher's launcher (Ubisoft Connect, the
/// EA app), and that launcher installs and runs the real game. iOdus cannot run
/// those launchers yet, so it shows a note instead of starting the stub (issue #6).
struct GameStub: Equatable {
    static let stubExecutable = "gdkstubgame.exe"

    /// The publisher from the package, for example "Ubisoft".
    let publisher: String

    /// The launcher that the stub opens, from the publisher name.
    var launcher: String {
        let name = publisher.lowercased()
        if name.contains("ubisoft") { return "Ubisoft Connect" }
        if name.contains("electronic arts") || name == "ea" || name.hasPrefix("ea ") { return "the EA app" }
        if name.contains("activision") || name.contains("blizzard") { return "Battle.net" }
        if name.contains("rockstar") { return "the Rockstar Games Launcher" }
        return publisher.isEmpty ? "the publisher's launcher" : "\(publisher)'s launcher"
    }

    /// The note for the game page and for a Play press.
    func note(for title: String) -> String {
        "This Store version of \(title) is only a starter for \(launcher). iOdus cannot run \(launcher) yet, so the game cannot start."
    }

    /// Reads MicrosoftGame.config in `folder`: a stub when every executable is GDKStubGame.exe.
    static func detect(in folder: URL) -> GameStub? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
              let config = names.first(where: { $0.lowercased() == "microsoftgame.config" }),
              let text = try? String(contentsOf: folder.appendingPathComponent(config), encoding: .utf8) else { return nil }
        return parse(config: text)
    }

    static func parse(config text: String) -> GameStub? {
        let executables = matches(#"<Executable\b[^>]*\bName="([^"]+)""#, in: text)
        guard !executables.isEmpty,
              executables.allSatisfy({ ($0.split(separator: "\\").last.map(String.init) ?? $0).lowercased() == stubExecutable })
        else { return nil }
        let publisher = matches(#"\bPublisherDisplayName="([^"]*)""#, in: text).first ?? ""
        return GameStub(publisher: publisher)
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
