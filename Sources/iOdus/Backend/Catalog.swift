import Foundation

struct CatalogProduct {
    let id: String
    let kind: String
    let title: String
    let publisher: String?
    let tileArt: URL?   // Square box art
    let heroArt: URL?   // Wide art for the background
    var titleId: String? = nil  // Xbox title ID, to match the title history
    /// The products in this product when all its SKUs are bundles (for example
    /// "Avowed Standard Edition" holds "Avowed"). Empty for a normal game.
    var bundledIds: Set<String> = []
    /// True when the packages are for Xbox consoles only, with no Windows PC package.
    var consoleOnly = false
    /// The launcher of the publisher when the Store has no package for the game
    /// (for example "the EA app"). Xodus cannot install these games.
    var launcher: String? = nil
}

/// Reads public product data from the Microsoft Store display catalog.
/// No sign-in is necessary.
struct Catalog {
    static let tilePurposes = ["BoxArt", "FeaturePromotionalSquareArt", "Poster", "TitledPoster"]
    static let heroPurposes = ["SuperHeroArt", "TitledHeroArt", "Hero", "Screenshot"]

    let session: URLSession

    func products(ids: [String], market: String) async throws -> [String: CatalogProduct] {
        var result: [String: CatalogProduct] = [:]
        let unique = Array(Set(ids)).sorted()
        let batches = stride(from: 0, to: unique.count, by: 25).map { Array(unique[$0..<min($0 + 25, unique.count)]) }
        try await withThrowingTaskGroup(of: [CatalogProduct].self) { group in
            for batch in batches {
                group.addTask { try await fetch(batch, market: market) }
            }
            for try await products in group {
                for product in products { result[product.id] = product }
            }
        }
        return result
    }

    private func fetch(_ ids: [String], market: String) async throws -> [CatalogProduct] {
        var components = URLComponents(string: "https://displaycatalog.mp.microsoft.com/v7.0/products")!
        components.queryItems = [
            URLQueryItem(name: "bigIds", value: ids.joined(separator: ",")),
            URLQueryItem(name: "market", value: market),
            URLQueryItem(name: "languages", value: "en-us,neutral"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.failed("The Store catalog request failed.")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let products = root["Products"] as? [[String: Any]] else {
            throw BackendError.invalidResponse("The Store catalog gave an unknown response.")
        }
        return products.compactMap(Self.parse)
    }

    static func parse(_ product: [String: Any]) -> CatalogProduct? {
        guard let id = (product["ProductId"] as? String)?.uppercased() else { return nil }
        let localized = (product["LocalizedProperties"] as? [[String: Any]])?.first
        let images = localized?["Images"] as? [[String: Any]] ?? []
        return CatalogProduct(
            id: id,
            kind: product["ProductKind"] as? String ?? "",
            title: localized?["ProductTitle"] as? String ?? id,
            publisher: localized?["PublisherName"] as? String,
            tileArt: image(images, tilePurposes, squareOnly: true) ?? image(images, tilePurposes, squareOnly: false),
            heroArt: image(images, heroPurposes, squareOnly: false),
            titleId: titleId(product),
            bundledIds: bundledIds(product),
            consoleOnly: consoleOnly(product),
            launcher: launcher(product))
    }

    /// The launcher that installs a game with no Store package. Nil for a game with a
    /// package, for a bundle, and for a product with no SKU data.
    static func launcher(_ product: [String: Any]) -> String? {
        let skus = (product["DisplaySkuAvailabilities"] as? [[String: Any]] ?? [])
            .compactMap { ($0["Sku"] as? [String: Any])?["Properties"] as? [String: Any] }
        guard !skus.isEmpty, !skus.allSatisfy({ $0["IsBundle"] as? Bool == true }),
              skus.allSatisfy({ ($0["Packages"] as? [Any] ?? []).isEmpty }) else { return nil }
        let family = (product["Properties"] as? [String: Any])?["PackageFamilyName"] as? String ?? ""
        let publisher = family.split(separator: ".").first.map(String.init) ?? ""
        return launchers[publisher] ?? "the launcher of the publisher"
    }

    static let launchers = [
        "ElectronicArtsMobile": "the EA app",
        "Ubisoft": "Ubisoft Connect",
        "BlizzardEntertainmentInc": "Battle.net",
        "RiotGames": "the Riot Client",
    ]

    /// The bundled product IDs, when all SKUs of the product are bundles.
    static func bundledIds(_ product: [String: Any]) -> Set<String> {
        let skus = (product["DisplaySkuAvailabilities"] as? [[String: Any]] ?? [])
            .compactMap { ($0["Sku"] as? [String: Any])?["Properties"] as? [String: Any] }
        guard !skus.isEmpty, skus.allSatisfy({ $0["IsBundle"] as? Bool == true }) else { return [] }
        var ids = Set<String>()
        for sku in skus {
            for item in sku["BundledSkus"] as? [[String: Any]] ?? [] {
                if let id = (item["BigId"] as? String)?.uppercased() { ids.insert(id) }
            }
        }
        return ids
    }

    /// True when the packages name the Xbox platform and not the Windows desktop.
    static func consoleOnly(_ product: [String: Any]) -> Bool {
        var platforms = Set<String>()
        for availability in product["DisplaySkuAvailabilities"] as? [[String: Any]] ?? [] {
            let properties = (availability["Sku"] as? [String: Any])?["Properties"] as? [String: Any]
            for package in properties?["Packages"] as? [[String: Any]] ?? [] {
                for dependency in package["PlatformDependencies"] as? [[String: Any]] ?? [] {
                    if let name = dependency["PlatformName"] as? String { platforms.insert(name) }
                }
            }
        }
        return platforms.contains("Windows.Xbox") && !platforms.contains("Windows.Desktop")
    }

    /// The Xbox title ID from `AlternateIds`, as a decimal string.
    static func titleId(_ product: [String: Any]) -> String? {
        let ids = product["AlternateIds"] as? [[String: Any]] ?? []
        guard let raw = ids.first(where: { $0["IdType"] as? String == "XboxTitleId" })?["Value"] as? String,
              let number = UInt32(raw), number > 0 else { return nil }
        return String(number)
    }

    private static func image(_ images: [[String: Any]], _ purposes: [String], squareOnly: Bool) -> URL? {
        for purpose in purposes {
            for image in images where image["ImagePurpose"] as? String == purpose {
                if squareOnly {
                    let w = image["Width"] as? Int ?? 0, h = image["Height"] as? Int ?? 0
                    guard w > 0, w == h else { continue }
                }
                guard var uri = image["Uri"] as? String else { continue }
                if uri.hasPrefix("//") { uri = "https:" + uri }
                if let url = URL(string: uri), url.scheme == "https",
                   url.host?.hasSuffix("s-microsoft.com") == true {
                    return url
                }
            }
        }
        return nil
    }
}
