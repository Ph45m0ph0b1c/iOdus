import XCTest
@testable import iOdus

final class MessagingModelTests: XCTestCase {
    private let inboxJSON = #"""
    {"schema":1,"account":"a@b.test","kind":"inbox","items":[
     {"id":"c1","type":"OneToOne","participants":["2533274800000001"],"gamertag":"Xbox player","unread":true,
      "lastMessage":{"id":"m1","sender":"2533274800000001","timestamp":"2026-11-02T21:40:00Z","text":"Hi","hidden":false,"mine":false}},
     {"id":"c2","type":"System","participants":[],"gamertag":"Xbox","unread":false,"lastMessage":null}]}
    """#

    func testSeenMessagesMarkAndPersist() throws {
        struct Items: Decodable { let items: [InboxItem] }
        let items = try JSONDecoder().decode(Items.self, from: Data(inboxJSON.utf8)).items
        XCTAssertEqual(items[0].peer, "2533274800000001")
        XCTAssertTrue(items[1].isSystem)
        XCTAssertNil(items[1].peer)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("seen-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var seen = SeenMessages(file: file)
        XCTAssertTrue(seen.isUnread(items[0]))
        XCTAssertFalse(seen.isUnread(items[1]), "No last message: nothing to read")
        seen.markSeen(items[0])
        XCTAssertFalse(SeenMessages(file: file).isUnread(items[0]), "The seen state is saved")
    }

    func testOwnMessageIsNeverUnread() {
        let mine = InboxItem(id: "c", type: "OneToOne", participants: ["1"], unread: true,
                             lastMessage: ChatMessage(id: "m", sender: "me", timestamp: nil, text: "x", hidden: false, mine: true))
        XCTAssertFalse(SeenMessages(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("seen-\(UUID().uuidString).json")).isUnread(mine))
    }

    func testHiddenMessageText() {
        let hidden = ChatMessage(id: "m", sender: "1", timestamp: nil, text: "", hidden: true, mine: false)
        XCTAssertEqual(hidden.shownText, "This message is not available.")
    }
}

@MainActor
final class SocialChannelTests: XCTestCase {
    /// A fake `native-social listen`: it answers the inbox request after the
    /// conversation request (out of order), and fails a send.
    private func fakeCLI() throws -> XodusCLI {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-listen-\(UUID().uuidString)")
        let script = #"""
        #!/usr/bin/env python3
        import json, sys
        held = None
        for line in sys.stdin:
            req = json.loads(line)
            rid, args = req["id"], req["args"]
            if args[0] == "inbox":
                held = rid          # Answer later, after the next request.
                continue
            if args[0] == "conversation":
                print(json.dumps({"id": rid, "ok": True, "result": {"schema": 1, "account": "a@b.test", "kind": "conversation",
                      "items": [{"id": "m1", "sender": args[1], "timestamp": "2026-11-02T21:40:00Z", "text": "Hi", "hidden": False, "mine": False}]}}))
                if held is not None:
                    print(json.dumps({"id": held, "ok": True, "result": {"schema": 1, "account": "a@b.test", "kind": "inbox", "items": []}}))
                    held = None
            elif args[0] == "send-message":
                print(json.dumps({"id": rid, "ok": False, "stage": "send-text"}))
            sys.stdout.flush()
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return XodusCLI(url: url)
    }

    func testAnswersGoToTheirRequestsAndErrorsHaveText() async throws {
        let channel = SocialChannel(cli: try fakeCLI())
        defer { channel.stop() }
        async let inbox = channel.inbox()
        try await Task.sleep(for: .milliseconds(300))
        let messages = try await channel.conversation(with: "2533274800000001")
        XCTAssertEqual(messages.map(\.text), ["Hi"])
        let items = try await inbox
        XCTAssertTrue(items.isEmpty, "The held inbox answer reached the inbox request")
        do {
            _ = try await channel.send(account: "a@b.test", to: "2533274800000001", text: "x")
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The message is empty or longer than 256 characters.")
        }
    }
}

@MainActor
final class DraftTypingTests: XCTestCase {
    func testTypingAndBackspaceInAConversation() {
        let model = AppModel()
        model.startDemo()
        model.stack = [.home, .messages, .conversation(MockLibrary.friends[0].xuid)]
        XCTAssertTrue(model.isTyping)
        "hey".forEach { model.type(String($0)) }
        model.type(" ")
        XCTAssertEqual(model.chatDraft, "hey ")
        model.deleteKey()
        model.deleteKey()
        XCTAssertEqual(model.chatDraft, "he")
        model.back()
        XCTAssertEqual(model.screen, .messages, "B leaves the conversation")
        XCTAssertEqual(model.chatDraft, "he", "The draft stays")
    }
}

@MainActor
final class SocialTabTests: XCTestCase {
    func testSocialOpensMessagesWhenUnreadAndTabsSwitch() {
        let model = AppModel()
        model.startDemo()
        XCTAssertGreaterThan(model.unreadConversations, 0)
        model.openSocial()
        XCTAssertEqual(model.screen, .messages, "Unread messages open the Messages tab")
        model.move(.left)
        XCTAssertEqual(model.screen, .friends)
        model.shoulder(1)
        XCTAssertEqual(model.screen, .messages, "RB switches the tab")
        XCTAssertEqual(model.stack, [.home, .messages], "The tab replaces the top of the stack")
        model.back()
        XCTAssertEqual(model.screen, .home, "B leaves Social")
    }
}
