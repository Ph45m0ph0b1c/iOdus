import Foundation

enum Access: String {
    case owned
    case gamePass
    case other
}

/// Decides how the account has access to each product. This is a port of
/// `resolveEntitlement` in Xodus Nexus `src/main/account-library.ts` (MIT).
enum LibraryRules {
    /// Game Pass and other subscription plan product IDs.
    static let plans: Set<String> = [
        "CFQ7TTC0KGQ8", "CFQ7TTC0KHS0", "CFQ7TTC0P85B", "CFQ7TTC0K5DJ", "CFQ7TTC0K6L8", "CFQ7TTC10QFD",
    ]

    static func accessByProduct(_ entitlements: [Entitlement], now: Date = Date()) -> [String: Access] {
        var entries: [String: Entitlement] = [:]
        var duplicates = Set<String>()
        for row in entitlements where isProductID(row.productId) {
            if entries[row.productId] != nil { duplicates.insert(row.productId) }
            entries[row.productId] = row
        }
        for id in duplicates { entries[id] = nil }

        var result: [String: Access] = [:]
        for id in entries.keys {
            if let access = resolve(id, entries: entries, now: now) { result[id] = access }
        }
        return result
    }

    static func resolve(_ productId: String, entries: [String: Entitlement], now: Date) -> Access? {
        var visited = Set<String>()
        var current = productId
        var subscription = false
        var conditional = false
        for depth in 0..<16 {
            if visited.contains(current) { return nil }
            visited.insert(current)
            if plans.contains(current) { subscription = true }
            guard let item = entries[current] else {
                if depth == 0 { return nil }
                return conditional ? .owned : subscription ? .gamePass : .other
            }
            // Only an explicit isPositron flag lets a "special" entitlement count.
            if item.special && item.isPositron != true { return nil }
            guard item.status == "Active", !item.isTrial, item.sharingSource == "None",
                  let end = parseDate(item.endDate), end > now else { return nil }
            if item.isPositron == true { conditional = true }
            guard let parent = item.satisfiedByProductId else {
                if current == productId && plans.contains(current) { return nil }
                return conditional ? .owned : subscription ? .gamePass : .owned
            }
            current = parent
        }
        return nil
    }

    /// Removes the second entries of one game from the library:
    /// - A bundle (an edition such as "Avowed Standard Edition") when a game in the
    ///   bundle is in the library too. That game gets the better access of the two.
    /// - A version for Xbox consoles only, when a PC version of the same game
    ///   (the same title ID or name) is in the library.
    static func withoutDuplicates(_ access: [String: Access],
                                  products: [String: CatalogProduct]) -> [String: Access] {
        var result = access
        for (id, product) in products where access[id] != nil && !product.bundledIds.isEmpty {
            let contents = product.bundledIds.filter { access[$0] != nil && products[$0]?.kind == "Game" }
            guard !contents.isEmpty, let bundleAccess = access[id] else { continue }
            result[id] = nil
            for content in contents {
                if let current = result[content], rank(bundleAccess) > rank(current) {
                    result[content] = bundleAccess
                }
            }
        }
        func nameKey(_ title: String) -> String {
            String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        let pcGames = result.keys.compactMap { products[$0] }.filter { !$0.consoleOnly }
        let pcTitleIds = Set(pcGames.compactMap(\.titleId))
        let pcNames = Set(pcGames.map { nameKey($0.title) })
        for (id, product) in products where result[id] != nil && product.consoleOnly {
            if product.titleId.map(pcTitleIds.contains) == true || pcNames.contains(nameKey(product.title)) {
                result[id] = nil
            }
        }
        return result
    }

    private static func rank(_ access: Access) -> Int {
        switch access {
        case .owned: 2
        case .gamePass: 1
        case .other: 0
        }
    }

    static func isProductID(_ value: String) -> Bool {
        value.count == 12 && value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Parses ISO 8601 dates, also with 7 fraction digits ("…59.9999999Z").
    static func parseDate(_ text: String) -> Date? {
        var value = text
        if let dot = value.firstIndex(of: ".") {
            let rest = value[value.index(after: dot)...]
            if let end = rest.firstIndex(where: { !$0.isNumber }) {
                value.removeSubrange(dot..<end)
            } else {
                value.removeSubrange(dot...)
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
