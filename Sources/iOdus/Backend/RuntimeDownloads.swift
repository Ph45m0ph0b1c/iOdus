import Foundation

/// A runtime that iOdus can download: a release file of the iOdus repository,
/// made by scripts/build-wine-runtime.sh (STAGE=package). The package has no
/// D3DMetal; iOdus adds it from the installed Game Porting Toolkit.
struct RuntimeDownload: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let wineVersion: String
    let release: Int
    let url: URL
    let sha256: String
    let size: Int64                     // The archive
    let unpackedBytes: Int64            // On disk after the install

    var displayName: String { "\(name) (Wine \(wineVersion))" }
    var neededBytes: Int64 { size + unpackedBytes }

    static let crossover = RuntimeDownload(
        id: "crossover-26.3", name: "CrossOver 26.3 Wine", wineVersion: "11.0", release: 3,
        url: URL(string: "https://github.com/burghr/iOdus/releases/download/v0.1.0/crossover-26.3-3.tar.xz")!,
        sha256: "fde679e5dba0e1c07dc8db31a70b4467808df8dcd6e3f2bcf6c2fab4bb950173",
        size: 277_378_440, unpackedBytes: 1_600_000_000)

    /// The runtimes that the Runtimes page and the setup offer.
    static var catalog: [RuntimeDownload] { [localArchive ?? crossover] }

    /// A test switch for a runtime that has no published release:
    /// --runtime-archive <file.tar.gz> installs the Wine 11 runtime from a local
    /// archive. The file <archive>.sha256 must hold its SHA-256, so the check still runs.
    static let localArchive: RuntimeDownload? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--runtime-archive"), i + 1 < args.count else { return nil }
        let file = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64,
              let text = try? String(contentsOf: URL(fileURLWithPath: file.path + ".sha256"), encoding: .utf8) else { return nil }
        let sha = String(text.prefix(64)).lowercased()
        guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else { return nil }
        return RuntimeDownload(id: crossover.id, name: crossover.name, wineVersion: crossover.wineVersion,
                               release: crossover.release, url: file, sha256: sha, size: size,
                               unpackedBytes: crossover.unpackedBytes)
    }()
}

enum RuntimeInstallError: LocalizedError, Equatable {
    case badPackage(String)
    case noGPTK

    var errorDescription: String? {
        switch self {
        case .badPackage(let detail): return "The runtime package is not valid. \(detail)"
        case .noGPTK: return "This runtime uses D3DMetal from the Game Porting Toolkit. Install the Game Porting Toolkit first."
        }
    }
}

/// Puts a downloaded runtime package into the Runtimes folder. All folders are
/// parameters, so that tests use temporary folders.
enum RuntimeInstaller {
    /// The wine folder of the installed GPTK (it has lib/external/D3DMetal.framework).
    static var gptkWine: URL {
        GameRuntime.standard.root.appendingPathComponent(GameRuntime.wineBundle, isDirectory: true)
    }

    /// 1. Extract into a staging folder in `runtimes`.
    /// 2. Check runtime.json: the ID of the download, and an executable Wine.
    /// 3. Add D3DMetal from GPTK.
    /// 4. Move the folder to Runtimes/<id>. An older release there is replaced;
    ///    its prefix (Prefixes/<id>) stays.
    static func install(archive: URL, download: RuntimeDownload, runtimes: URL, gptkWine: URL = gptkWine) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
        let staging = runtimes.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        // bsdtar refuses absolute paths and ".." entries by default.
        try RuntimeSetup.run("/usr/bin/tar", ["-xf", archive.path, "-C", staging.path])

        let folder = staging.appendingPathComponent(download.id, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("runtime.json")),
              let manifest = try? JSONDecoder().decode(RuntimeManifest.self, from: data) else {
            throw RuntimeInstallError.badPackage("runtime.json is missing or not readable.")
        }
        guard manifest.id == download.id, RuntimeCatalog.isValidID(manifest.id) else {
            throw RuntimeInstallError.badPackage("The package is for \(manifest.id), not \(download.id).")
        }
        guard fm.isExecutableFile(atPath: folder.appendingPathComponent(manifest.wine).path) else {
            throw RuntimeInstallError.badPackage("Wine is missing.")
        }
        if let files = manifest.d3dmetal { try addD3DMetal(files, from: gptkWine, to: folder) }

        let target = runtimes.appendingPathComponent(download.id, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            let old = staging.appendingPathComponent("old", isDirectory: true)
            try fm.moveItem(at: target, to: old)
        }
        try fm.moveItem(at: folder, to: target)
    }

    /// Copies Apple's D3DMetal from GPTK into a runtime folder, in the GPTK layout:
    /// lib/external (the framework and libd3dshared), the PE DLLs, and the
    /// unix .so files as the same links that GPTK has.
    static func addD3DMetal(_ files: D3DMetalFiles, from gptkWine: URL, to runtime: URL) throws {
        let fm = FileManager.default
        let external = gptkWine.appendingPathComponent("lib/external", isDirectory: true)
        guard fm.fileExists(atPath: external.appendingPathComponent("D3DMetal.framework").path) else {
            throw RuntimeInstallError.noGPTK
        }
        let target = runtime.appendingPathComponent("lib/external", isDirectory: true)
        try? fm.removeItem(at: target)
        // ditto keeps the links of the framework and the signatures.
        try RuntimeSetup.run("/usr/bin/ditto", [external.path, target.path])
        for name in files.windows where isPlainName(name) {
            let from = gptkWine.appendingPathComponent("lib/wine/x86_64-windows/\(name)")
            let to = runtime.appendingPathComponent("lib/wine/x86_64-windows/\(name)")
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try fm.copyItem(at: from, to: to)
        }
        for name in files.unix where isPlainName(name) {
            let from = gptkWine.appendingPathComponent("lib/wine/x86_64-unix/\(name)")
            let to = runtime.appendingPathComponent("lib/wine/x86_64-unix/\(name)")
            guard let link = try? fm.destinationOfSymbolicLink(atPath: from.path) else { continue }
            try? fm.removeItem(at: to)
            try fm.createSymbolicLink(atPath: to.path, withDestinationPath: link)
        }
    }

    /// A file name without a path, so that runtime.json cannot write outside the folder.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }
}
