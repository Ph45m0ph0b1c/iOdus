import Foundation

/// One product in the Store page: from a list or a search, plus catalog art.
struct StoreItem: Identifiable, Equatable {
    let id: String              // Store product ID, upper case
    var title: String
    var publisher: String = ""
    var price: String?          // "Included", "$63.99", "Free", or nil
    var tileArt: URL?
    var heroArt: URL?
    var gamePass = false
}

struct StoreRow: Identifiable, Equatable {
    let id: String
    let title: String
    var items: [StoreItem]
}

/// Public Microsoft Store and Game Pass lists. No sign-in is necessary.
/// The sources are the same that Xodus Nexus uses (src/main/catalog.ts and
/// src/main/gamepass-recent.ts).
struct StoreCatalog {
    static let recentPCGamePass = "06323672-b8c8-43cc-b0de-32d5a9834749"
    let session: URLSession
    let market: String

    /// "Recently added" to PC Game Pass, in the order of the collection.
    func recentGamePass() async throws -> [String] {
        var components = URLComponents(string: "https://catalog.gamepass.com/sigls/v3")!
        components.queryItems = [
            URLQueryItem(name: "id", value: Self.recentPCGamePass),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "platformContext", value: "pc"),
            URLQueryItem(name: "subscriptionContext", value: "cfq7ttc0kgq8"),
        ]
        let data = try await get(components.url!)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count > 1 else {
            throw BackendError.invalidResponse("The Game Pass list has an unknown format.")
        }
        return Self.uniqueIDs(rows.dropFirst().compactMap { $0["id"] as? String })
    }

    /// The product IDs that the web player can stream (the cloud "All games" list).
    func cloudGames() async throws -> Set<String> {
        var components = URLComponents(string: "https://catalog.gamepass.com/sigls/v3")!
        components.queryItems = [
            URLQueryItem(name: "id", value: CloudStream.cloudListID),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "platformContext", value: CloudStream.cloudPlatform),
            URLQueryItem(name: "subscriptionContext", value: "none"),
        ]
        let data = try await get(components.url!)
        return try Self.cloudIDs(from: data)
    }

    /// The cloud list often has the editions of a game ("Standard Edition"),
    /// not the game product itself. This finds the edition in the cloud list
    /// that contains `productId`: a Store search for the title, then a check of
    /// the bundled products of each cloud result. Returns nil when none matches.
    func cloudEdition(for productId: String, title: String, cloud: Set<String>) async throws -> String? {
        var search = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/productFamilies/autosuggest")!
        search.queryItems = [
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "languages", value: "en-US"),
            URLQueryItem(name: "query", value: Self.searchTitle(title)),
            URLQueryItem(name: "productFamilyNames", value: "Games,Bundles"),
        ]
        let candidates = Self.suggestedIDs(from: try await get(search.url!)).filter { cloud.contains($0) }
        guard !candidates.isEmpty else { return nil }
        var lookup = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
        lookup.queryItems = [
            URLQueryItem(name: "bigIds", value: candidates.prefix(20).joined(separator: ",")),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "languages", value: "en-US"),
        ]
        return Self.edition(containing: productId, in: try await get(lookup.url!))
    }

    /// "Forza Horizon™ 6" -> "Forza Horizon 6"
    static func searchTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "™", with: "").replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The product IDs of an autosuggest answer, upper case.
    static func suggestedIDs(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["Results"] as? [[String: Any]] else { return [] }
        return uniqueIDs(results.flatMap { ($0["Products"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["ProductId"] as? String })
    }

    /// The product of a display catalog answer whose SKUs bundle `productId`.
    /// With more than one, the edition with the fewest bundled products
    /// (the Standard Edition before the Deluxe Edition).
    static func edition(containing productId: String, in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = object["Products"] as? [[String: Any]] else { return nil }
        let wanted = productId.uppercased()
        var best: (id: String, count: Int)?
        for product in products {
            guard let id = (product["ProductId"] as? String)?.uppercased() else { continue }
            let skus = (product["DisplaySkuAvailabilities"] as? [[String: Any]]) ?? []
            for availability in skus {
                let properties = ((availability["Sku"] as? [String: Any])?["Properties"] as? [String: Any]) ?? [:]
                let bundled = ((properties["BundledSkus"] as? [[String: Any]]) ?? [])
                    .compactMap { ($0["BigId"] as? String)?.uppercased() }
                if bundled.contains(wanted), best.map({ bundled.count < $0.count }) ?? true {
                    best = (id, bundled.count)
                }
            }
        }
        return best?.id
    }

    static func cloudIDs(from data: Data) throws -> Set<String> {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count > 1 else {
            throw BackendError.invalidResponse("The cloud games list has an unknown format.")
        }
        return Set(rows.dropFirst().compactMap { ($0["id"] as? String)?.uppercased() })
    }

    /// "Trending games" from the Microsoft Store.
    func trending() async throws -> [(id: String, price: String?)] {
        var components = URLComponents(string: "https://apps.microsoft.com/api/Reco/GetComputedProductsList")!
        components.queryItems = [
            URLQueryItem(name: "listName", value: "TopTrending"),
            URLQueryItem(name: "pgNo", value: "1"),
            URLQueryItem(name: "noItems", value: "24"),
            URLQueryItem(name: "filteredCategories", value: "AllProducts"),
            URLQueryItem(name: "mediaType", value: "Games"),
            URLQueryItem(name: "gl", value: market),
            URLQueryItem(name: "hl", value: "en-us"),
            URLQueryItem(name: "exp", value: "0"),
        ]
        return try Self.products(from: await get(components.url!))
    }

    /// A search for games in the Microsoft Store.
    func search(_ query: String) async throws -> [(id: String, price: String?)] {
        var components = URLComponents(string: "https://apps.microsoft.com/api/products/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "mediaType", value: "games"),
            URLQueryItem(name: "age", value: "all"),
            URLQueryItem(name: "price", value: "all"),
            URLQueryItem(name: "category", value: "all"),
            URLQueryItem(name: "subscription", value: "all"),
            URLQueryItem(name: "gl", value: market),
            URLQueryItem(name: "hl", value: "en-us"),
        ]
        return try Self.products(from: await get(components.url!))
    }

    /// Titles and art from the display catalog, in the order of `ids`.
    func items(_ list: [(id: String, price: String?)], gamePass: Bool = false) async throws -> [StoreItem] {
        let products = try await Catalog(session: session).products(ids: list.map(\.id), market: market)
        return list.compactMap { entry in
            guard let product = products[entry.id], product.kind == "Game" else { return nil }
            return StoreItem(id: entry.id, title: product.title, publisher: product.publisher ?? "",
                             price: gamePass ? "Included" : entry.price,
                             tileArt: product.tileArt, heroArt: product.heroArt,
                             gamePass: gamePass || entry.price == "Included")
        }
    }

    // MARK: - Parsing

    static func products(from data: Data) throws -> [(id: String, price: String?)] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["productsList"] as? [[String: Any]] else {
            throw BackendError.invalidResponse("The Store gave an unknown response.")
        }
        var seen = Set<String>()
        return list.compactMap { product in
            guard let raw = product["productId"] as? String else { return nil }
            let id = raw.uppercased()
            guard LibraryRules.isProductID(id), seen.insert(id).inserted else { return nil }
            let price = (product["displayPrice"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return (id, price)
        }
    }

    static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.map { $0.uppercased() }.filter { LibraryRules.isProductID($0) && seen.insert($0).inserted }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.failed("The Store request failed.")
        }
        return data
    }
}
