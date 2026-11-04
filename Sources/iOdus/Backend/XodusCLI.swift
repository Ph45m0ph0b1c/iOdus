import Foundation

struct CLIResult {
    let status: Int32
    let stdout: Data
    let stderr: String
    let timedOut: Bool
}

enum BackendError: LocalizedError {
    case cliNotFound
    case failed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "xodus-cli was not found. Set IODUS_XODUS_CLI to its path."
        case .failed(let message), .invalidResponse(let message):
            return message
        }
    }
}

/// Starts `xodus-cli` as a subprocess. Credentials stay in the CLI and the
/// macOS Keychain; iOdus only reads the JSON that the CLI prints.
final class XodusCLI: @unchecked Sendable {
    let url: URL

    init(url: URL) { self.url = url }

    /// Search order: $IODUS_XODUS_CLI, the app bundle, then the dev build of the fork.
    static func locate() -> XodusCLI? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["IODUS_XODUS_CLI"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "xodus-cli") {
            candidates.append(bundled)
        }
        candidates.append(fm.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/iodus-xodus/target/release/xodus-cli"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }.map(XodusCLI.init)
    }

    /// Runs the CLI. `input` goes to stdin, for commands that read a private request.
    func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> CLIResult {
        try await Self.runProcess(url, arguments, input: input, timeout: timeout)
    }

    /// Runs a program and collects its output. `environment` replaces the
    /// environment of iOdus when it is set.
    static func runProcess(_ url: URL, _ arguments: [String], input: Data? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval) async throws -> CLIResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = url
                process.arguments = arguments
                if let environment { process.environment = environment }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                let stdin = input.map { _ in Pipe() }
                process.standardInput = stdin ?? FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let stdin, let input {
                    try? stdin.fileHandleForWriting.write(contentsOf: input)
                    try? stdin.fileHandleForWriting.close()
                }

                let state = RunState()
                let killer = DispatchWorkItem {
                    if process.isRunning {
                        state.timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                // Read both pipes at the same time, so that a full pipe cannot block the CLI.
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    state.stdout = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    state.stderr = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.waitUntilExit()
                group.wait()
                killer.cancel()
                continuation.resume(returning: CLIResult(
                    status: process.terminationStatus,
                    stdout: state.stdout,
                    stderr: String(decoding: state.stderr, as: UTF8.self),
                    timedOut: state.timedOut))
            }
        }
    }

    /// Runs a command and decodes the last JSON line of its output.
    func json<T: Decodable>(_ type: T.Type, _ arguments: [String], input: Data? = nil,
                            timeout: TimeInterval = 60) async throws -> T {
        let result = try await run(arguments, input: input, timeout: timeout)
        if result.timedOut { throw BackendError.failed("The backend did not answer in time.") }
        guard result.status == 0 else { throw BackendError.failed(Self.message(from: result.stderr)) }
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) else {
            throw BackendError.invalidResponse("The backend gave no JSON for \(arguments.first ?? "command").")
        }
        do {
            return try JSONDecoder().decode(T.self, from: Data(line.utf8))
        } catch {
            throw BackendError.invalidResponse("The backend gave JSON that iOdus cannot read (\(arguments.first ?? "command")).")
        }
    }

    /// The last useful line of stderr, for an error message.
    static func message(from stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last ?? "The backend stopped with an error."
    }
}

private final class RunState: @unchecked Sendable {
    var stdout = Data()
    var stderr = Data()
    var timedOut = false
}

// MARK: - Commands

struct AccountStatus: Decodable {
    let stored: Bool
    let username: String?
}

struct XboxProfile: Decodable {
    let schema: Int
    let account: String
    let gamertag: String
    let gamerpicDataUrl: String?
}

struct LibraryResponse: Decodable {
    let schema: Int
    let account: String
    let market: String
    let checkedAt: String
    let entitlements: [Entitlement]
}

struct Entitlement: Decodable {
    let productId: String
    let status: String
    let isTrial: Bool
    let sharingSource: String
    let endDate: String
    let satisfiedByProductId: String?
    let special: Bool
    let isPositron: Bool?
}

/// One game from the Xbox title history. The service sorts the list by the last play.
struct PlayedTitle: Decodable, Equatable {
    let titleId: String
    let name: String
    let lastPlayed: String?
    let currentGamerscore: Int?
    let totalGamerscore: Int?
    var achievementsUnlocked: Int? = nil
    var achievementsTotal: Int? = nil
    var imageUrl: String? = nil

    var lastPlayedDate: Date? { lastPlayed.flatMap(LibraryRules.parseDate) }

    var image: URL? {
        guard let imageUrl, let url = URL(string: imageUrl), url.scheme == "https" else { return nil }
        return url
    }

    /// Only games with achievements belong in the achievement hub.
    var hasAchievements: Bool { (achievementsTotal ?? 0) > 0 || (totalGamerscore ?? 0) > 0 }
}

private struct PeopleResponse<T: Decodable>: Decodable {
    let schema: Int
    let kind: String
    let account: String
    let result: T
}

private struct TitlePage: Decodable {
    let items: [PlayedTitle]
}

extension XodusCLI {
    /// The last 100 games that the account played, from `native-social people`.
    func titleHistory(account: String) async throws -> [PlayedTitle] {
        let request = try JSONSerialization.data(withJSONObject: ["account": account, "operation": "games", "xuid": "me"])
        let response = try await json(PeopleResponse<TitlePage>.self, ["native-social", "people"],
                                      input: request, timeout: 60)
        guard response.schema == 1, response.kind == "people", response.account == account else {
            throw BackendError.invalidResponse("The title history is for a different account.")
        }
        return response.result.items
    }

    func account() async throws -> AccountStatus {
        try await json(AccountStatus.self, ["account", "--json"], timeout: 20)
    }

    func profile() async throws -> XboxProfile {
        try await json(XboxProfile.self, ["profile", "--json"], timeout: 60)
    }

    func library(market: String) async throws -> LibraryResponse {
        try await json(LibraryResponse.self, ["library", "--json", "--market", market], timeout: 60)
    }

    /// Opens the Microsoft sign-in window of the CLI and waits until it closes.
    func login() async throws {
        let result = try await run(["login"], timeout: 15 * 60)
        if result.timedOut { throw BackendError.failed("The sign-in took too long. Try again.") }
        guard result.status == 0 else { throw BackendError.failed(Self.message(from: result.stderr)) }
    }

    /// Removes the account and the device credentials. A new sign-in then makes
    /// all Keychain items again, owned by the current (signed) xodus-cli.
    func logout() async throws {
        let result = try await run(["logout", "--device"], timeout: 30)
        guard result.status == 0 else { throw BackendError.failed(Self.message(from: result.stderr)) }
    }
}
