import Foundation

/// One message, from `native-social inbox` or `conversation`.
struct ChatMessage: Decodable, Identifiable, Equatable {
    let id: String
    let sender: String
    let timestamp: String?
    let text: String
    let hidden: Bool        // Deleted, or marked unsuitable by Xbox Live
    let mine: Bool

    var date: Date? { timestamp.flatMap(LibraryRules.parseDate) }
    var shownText: String { hidden ? "This message is not available." : text }
}

/// One conversation in the inbox.
struct InboxItem: Decodable, Identifiable, Equatable {
    let id: String
    let type: String?
    let participants: [String]      // XUIDs, without the signed-in player
    let unread: Bool
    let lastMessage: ChatMessage?

    var isSystem: Bool { type == "System" }
    /// The friend of a one-to-one conversation.
    var peer: String? { participants.count == 1 ? participants[0] : nil }
}

private struct SocialItems<T: Decodable>: Decodable {
    let schema: Int
    let kind: String
    let account: String
    let items: [T]
}

private struct ChannelReply: Decodable {
    let id: UInt64
    let ok: Bool
    let stage: String?
}

/// A long-running `xodus-cli native-social listen` process. Each request is one
/// JSON line with an ID; the answer has the same ID. One process serves all
/// social requests, so a check does not start a new process each time.
@MainActor
final class SocialChannel {
    private let cli: XodusCLI
    private var process: StreamingProcess?
    private var nextID: UInt64 = 1
    private var waiting: [UInt64: CheckedContinuation<Data, Error>] = [:]

    init(cli: XodusCLI) { self.cli = cli }

    func stop() {
        process?.interrupt()
        process = nil
        fail(BackendError.failed("The social connection stopped."))
    }

    /// Sends `args` (for example ["inbox"]) and returns the JSON of the result.
    func request(_ args: [String], input: String? = nil, timeout: TimeInterval = 60) async throws -> Data {
        try startIfNeeded()
        let id = nextID
        nextID += 1
        var line: [String: Any] = ["id": id, "args": args]
        if let input { line["input"] = input }
        let data = try JSONSerialization.data(withJSONObject: line)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
            process?.send(String(decoding: data, as: UTF8.self))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if let pending = self.waiting.removeValue(forKey: id) {
                    pending.resume(throwing: BackendError.failed("Xbox Live did not answer in time."))
                }
            }
        }
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        let process = StreamingProcess(url: cli.url, arguments: ["native-social", "listen"])
        self.process = process
        try process.start(
            onLine: { [weak self] line in self?.received(line) },
            onExit: { [weak self] _, stderr in
                self?.process = nil
                self?.fail(BackendError.failed(XodusCLI.message(from: stderr)))
            })
    }

    private func received(_ line: String) {
        let data = Data(line.utf8)
        guard let reply = try? JSONDecoder().decode(ChannelReply.self, from: data),
              let continuation = waiting.removeValue(forKey: reply.id) else { return }
        guard reply.ok,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"],
              let resultData = try? JSONSerialization.data(withJSONObject: result) else {
            continuation.resume(throwing: BackendError.failed(Self.text(for: reply.stage)))
            return
        }
        continuation.resume(returning: resultData)
    }

    private func fail(_ error: Error) {
        let all = waiting
        waiting.removeAll()
        for continuation in all.values { continuation.resume(throwing: error) }
    }

    static func text(for stage: String?) -> String {
        switch stage {
        case "social-rate-limited": return "Xbox Live asks iOdus to wait. Try again in a minute."
        case "social-permission-denied": return "Xbox Live refused the request. Check the privacy settings of your account."
        case "send-text": return "The message is empty or longer than 256 characters."
        case "timeout": return "Xbox Live did not answer in time."
        default: return "Xbox Live messaging is not available now (\(stage ?? "unknown"))."
        }
    }

    // MARK: Requests

    func inbox() async throws -> [InboxItem] {
        try JSONDecoder().decode(SocialItems<InboxItem>.self, from: await request(["inbox"])).items
    }

    func conversation(with xuid: String) async throws -> [ChatMessage] {
        try JSONDecoder().decode(SocialItems<ChatMessage>.self, from: await request(["conversation", xuid])).items
    }

    /// Sends a text message. Returns the ID of the new message.
    func send(account: String, to xuid: String, text: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: ["account": account, "xuid": xuid, "text": text])
        let data = try await request(["send-message"], input: String(decoding: body, as: UTF8.self), timeout: 70)
        struct Sent: Decodable { let id: String }
        return try JSONDecoder().decode(SocialItems<Sent>.self, from: data).items.first?.id
    }
}
