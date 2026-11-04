import Foundation

/// A long-running CLI process with line-by-line stdout and a stdin for
/// control messages. Used for `xodus-cli streaming`.
final class StreamingProcess: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let queue = DispatchQueue(label: "iodus.streaming")
    private var buffer = Data()
    private var stderrTail = Data()

    init(url: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = url
        process.arguments = arguments
        if let environment { process.environment = environment }
    }

    /// `onLine` and `onExit` run on the main thread, in the order of the output.
    func start(onLine: @escaping @MainActor (String) -> Void,
               onExit: @escaping @MainActor (Int32, String) -> Void) throws {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdinPipe

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.sync { self?.consume(data, onLine: onLine) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.sync {
                guard let self else { return }
                self.stderrTail.append(data)
                if self.stderrTail.count > 16_384 { self.stderrTail = self.stderrTail.suffix(8_192) }
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            let errRest = err.fileHandleForReading.readDataToEndOfFile()
            self.queue.sync {
                self.consume(rest, onLine: onLine)
                if !self.buffer.isEmpty {
                    let line = String(decoding: self.buffer, as: UTF8.self)
                    self.buffer.removeAll()
                    DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
                }
                self.stderrTail.append(errRest)
                let stderr = String(decoding: self.stderrTail.suffix(8_192), as: UTF8.self)
                let status = process.terminationStatus
                DispatchQueue.main.async { MainActor.assumeIsolated { onExit(status, stderr) } }
            }
        }
        try process.run()
    }

    private func consume(_ data: Data, onLine: @escaping @MainActor (String) -> Void) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
        }
        if buffer.count > 1_000_000 { buffer.removeAll() } // A line this long is not a protocol line.
    }

    /// Sends one JSON control line, for example a pause.
    func send(_ line: String) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    /// SIGINT. The CLI stops and keeps its files, so that a later run can resume.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    var isRunning: Bool { process.isRunning }
}

/// One `NEXUS_PROGRESS` record (Nexus progress protocol v1).
struct ProgressRecord: Decodable {
    static let prefix = "NEXUS_PROGRESS "
    static let phases = ["initializing", "metadata", "downloading", "finalizing", "complete", "failed"]

    let schema: Int
    let event: String
    let sequence: Int64
    let phase: String
    let paused: Bool
    let canPause: Bool
    let completedBytes: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Int64
    let networkBytes: Int64?
    let reusedBytes: Int64?

    static func parse(_ line: String) -> ProgressRecord? {
        guard line.hasPrefix(prefix), line.count <= 4096,
              let record = try? JSONDecoder().decode(ProgressRecord.self, from: Data(line.dropFirst(prefix.count).utf8)),
              record.schema == 1, record.event == "progress", phases.contains(record.phase),
              record.sequence >= 0, record.completedBytes >= 0, record.bytesPerSecond >= 0,
              record.totalBytes.map({ $0 >= record.completedBytes }) ?? true else { return nil }
        return record
    }
}

// MARK: - resolve-package

struct InstallChoice: Decodable, Equatable {
    let productId: String
    let contentId: String
    let title: String
    let platform: String
    let packageFormat: String
    let kind: String
    let supported: Bool
    let downloadBytes: Int64?
    let installBytes: Int64?
}

struct InstallPlan: Decodable {
    let schema: Int
    let rootProductId: String
    let market: String
    let status: String
    let choices: [InstallChoice]

    /// The base game package for Windows PC. Add-ons come later.
    var gameChoice: InstallChoice? {
        choices.first { $0.supported && $0.kind == "Game" && $0.platform == "Windows.Desktop" && $0.packageFormat == "MSIXVC" }
    }
}

extension XodusCLI {
    /// Public Store data. No sign-in.
    func resolvePackage(_ productId: String, market: String) async throws -> InstallPlan {
        let plan = try await json(InstallPlan.self, ["resolve-package", productId, "--json", "--market", market], timeout: 40)
        guard plan.schema == 1, plan.rootProductId == productId else {
            throw BackendError.invalidResponse("The Store package data does not match this game.")
        }
        return plan
    }
}
