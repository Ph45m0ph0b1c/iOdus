import XCTest
@testable import iOdus

final class SocialStoreTests: XCTestCase {
    func testFriendsSortOnlineThenFavoritesThenName() {
        func f(_ tag: String, _ online: Bool, _ favorite: Bool) -> Friend {
            Friend(xuid: tag, gamertag: tag, online: online, presence: "", avatarUrl: nil, favorite: favorite, inParty: false)
        }
        let sorted = Friend.sorted([f("zed", false, false), f("amy", false, true), f("bob", true, false),
                                    f("cat", false, false), f("dan", true, true)])
        XCTAssertEqual(sorted.map(\.gamertag), ["dan", "bob", "amy", "cat", "zed"])
    }

    @MainActor
    func testFriendAvatarAllowsOnlyHttps() {
        let good = Friend(xuid: "1", gamertag: "a", online: false, presence: "",
                          avatarUrl: "https://images-eds-ssl.xboxlive.com/image?url=abc", favorite: false, inParty: false)
        let bad = Friend(xuid: "2", gamertag: "b", online: false, presence: "",
                         avatarUrl: "http://example.com/x.png", favorite: false, inParty: false)
        XCTAssertNotNil(good.avatar)
        XCTAssertNil(bad.avatar)
        // The Store image sizing must not change an Xbox picture URL.
        XCTAssertEqual(ImageStore.sized(good.avatar!, width: 200), good.avatar)
    }

    func testStoreProductsParseUpperCaseAndDeduplicate() throws {
        let json = #"{"productsList":[{"productId":"9nkx70bbcdrn","displayPrice":"Included"},{"productId":"9NKX70BBCDRN"},{"productId":"bad"},{"productId":"9pnsz7gmwcqz","displayPrice":"$19.99"},{"productId":"9N4XW3N02MNJ","displayPrice":""}]}"#
        let products = try StoreCatalog.products(from: Data(json.utf8))
        XCTAssertEqual(products.map(\.id), ["9NKX70BBCDRN", "9PNSZ7GMWCQZ", "9N4XW3N02MNJ"])
        XCTAssertEqual(products.map(\.price), ["Included", "$19.99", nil])
    }

    func testPlayerProfileDecodesTheBackendShape() throws {
        let json = ##"{"xuid":"2533274800000001","gamertag":"Player One","gamerscore":"48215","online":true,"presence":"YouTube","counts":{"friends":10,"followers":14,"following":1},"tenure":"11","colors":{"primary":"#54A81B"},"isSelf":true}"##
        let profile = try JSONDecoder().decode(PlayerProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.gamerscoreValue, 48_215)
        XCTAssertEqual(profile.counts?.friends, 10)
        XCTAssertEqual(48_215.grouped, "48,215")
    }

    /// Live Store requests. Run with IODUS_NETWORK_TESTS=1.
    func testLiveStoreLists() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IODUS_NETWORK_TESTS"] == "1")
        let catalog = StoreCatalog(session: .shared, market: "US")
        let recent = try await catalog.recentGamePass()
        let trending = try await catalog.trending()
        XCTAssertFalse(recent.isEmpty)
        XCTAssertFalse(trending.isEmpty)
        let results = try await catalog.items(catalog.search("forza"))
        XCTAssertTrue(results.contains { $0.title.contains("Forza") })
    }
}

final class AchievementTests: XCTestCase {
    func testDecodesTheBackendShapeAndSorts() throws {
        let json = #"""
        [{"id":"a:1","name":"Locked","description":"d","gamerscore":10,"iconUrl":null,"state":"locked","progress":0.0,"secret":false,"revoked":false,"unlockedAt":null},
         {"id":"a:2","name":"Old","description":"d","gamerscore":20,"iconUrl":"https://images-eds-ssl.xboxlive.com/image?url=x","state":"unlocked","progress":null,"secret":true,"revoked":false,"unlockedAt":"2026-10-07T01:40:59.7600000Z"},
         {"id":"a:3","name":"Half","description":"d","gamerscore":30,"iconUrl":null,"state":"in-progress","progress":0.5,"secret":false,"revoked":false,"unlockedAt":null},
         {"id":"a:4","name":"New","description":"d","gamerscore":40,"iconUrl":null,"state":"unlocked","progress":1.0,"secret":false,"revoked":false,"unlockedAt":"2026-11-01T10:00:00Z"}]
        """#
        let items = try JSONDecoder().decode([Achievement].self, from: Data(json.utf8))
        let sorted = Achievement.sorted(items)
        XCTAssertEqual(sorted.map(\.name), ["New", "Old", "Half", "Locked"])
        let list = AchievementList(titleId: "1", partial: false, items: sorted)
        XCTAssertEqual(list.unlocked, 2)
        XCTAssertEqual(list.earnedScore, 60)
        XCTAssertEqual(list.totalScore, 100)
        XCTAssertNotNil(sorted[1].icon)
    }
}
