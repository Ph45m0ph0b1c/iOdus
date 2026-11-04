import AppKit
import SwiftUI

/// A search box for a controller UI: no text field. The model receives the
/// keys, and this view only shows the text and a caret.
struct SearchBar: View {
    let text: String
    let placeholder: String
    let focused: Bool
    let busy: Bool
    let scale: CGFloat
    let onTap: () -> Void
    let onClear: () -> Void

    var body: some View {
        let s = scale
        HStack(spacing: 10 * s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 1 * s) {
                Text(text.isEmpty && !focused ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if focused {
                    Rectangle()
                        .fill(Theme.textPrimary)
                        .frame(width: 2 * s, height: 22 * s)
                }
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView().controlSize(.small).tint(.white)
            }
            if !text.isEmpty {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Theme.textSecondary)
                    .onTapGesture(perform: onClear)
            }
        }
        .font(.system(size: 20 * s))
        .padding(.horizontal, 20 * s)
        .frame(height: 48 * s)
        .background(Color.black.opacity(0.45), in: Capsule())
        // A light border, so that the box stands out from dark and green backgrounds.
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.0 : 0.45), lineWidth: 1.5 * s))
        .focusFrame(focused, scale: s, radius: 24)
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
    }
}

/// The Store: a search box, then rows of Game Pass and trending games,
/// or a grid of search results.
struct StoreView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 24 * s) {
                HStack(spacing: 32 * s) {
                    Text("Store")
                        .font(.system(size: 40 * s, weight: .semibold))
                    SearchBar(text: model.storeSearch, placeholder: "Search the Microsoft Store",
                              focused: model.storeFocus == .search,
                              busy: model.storeSearchState == .loading, scale: s,
                              onTap: { model.tapStoreSearch() },
                              onClear: { model.setStoreSearch("") })
                        .frame(width: 560 * s)
                }
                if model.showsStoreResults {
                    results(s, width: geo.size.width - Theme.sidePadding * 2 * s, height: geo.size.height)
                } else {
                    rows(s, width: geo.size.width - Theme.sidePadding * 2 * s)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.top, 140 * s)
        }
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.30), Theme.background],
                           startPoint: .top, endPoint: .center)
        )
    }

    @ViewBuilder
    private func rows(_ s: CGFloat, width: CGFloat) -> some View {
        switch model.storeState {
        case .loading where model.storeRows.isEmpty:
            HStack(spacing: 14 * s) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Loading the Store…")
            }
            .font(.system(size: 22 * s))
            .foregroundStyle(Theme.textSecondary)
        case .failed(let message) where model.storeRows.isEmpty:
            Text("The Store could not load: \(message) Press X to try again.")
                .font(.system(size: 22 * s))
                .foregroundStyle(Theme.textSecondary)
        default:
            // Show the focused row and the rows below it.
            let first = max(0, min(model.storeRow, model.storeRows.count - 2))
            VStack(alignment: .leading, spacing: 30 * s) {
                ForEach(Array(model.storeRows.enumerated()).dropFirst(first), id: \.element.id) { r, row in
                    VStack(alignment: .leading, spacing: 14 * s) {
                        Text(row.title)
                            .font(.system(size: 24 * s, weight: .semibold))
                        tileRow(row, r, s, width: width)
                    }
                }
            }
        }
    }

    private func tileRow(_ row: StoreRow, _ r: Int, _ s: CGFloat, width: CGFloat) -> some View {
        let tile: CGFloat = 230 * s, gap: CGFloat = 18 * s
        let focusedIndex = r < model.storeIndex.count ? model.storeIndex[r] : 0
        let visible = max(1, Int(width / (tile + gap)))
        let shift = max(0, focusedIndex - visible + 2)
        return HStack(spacing: gap) {
            ForEach(Array(row.items.enumerated()), id: \.element.id) { i, item in
                StoreTile(item: item, inLibrary: model.inLibrary(item.id), scale: s)
                    .frame(width: tile, height: tile)
                    .focusFrame(model.storeFocus == .rows && model.storeRow == r && focusedIndex == i, scale: s)
                    .onTapGesture { model.tapStoreTile(row: r, index: i) }
            }
        }
        .offset(x: -CGFloat(shift) * (tile + gap))
        .animation(.easeOut(duration: 0.18), value: shift)
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func results(_ s: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        let c = model.storeColumns, gap: CGFloat = 18 * s
        let tile = (width - gap * CGFloat(c - 1)) / CGFloat(c)
        VStack(alignment: .leading, spacing: 16 * s) {
            switch model.storeSearchState {
            case .failed(let message):
                Text("The search failed: \(message)")
            case .ready where model.storeResults.isEmpty:
                Text("No games match \u{201C}\(model.storeSearch)\u{201D}.")
            case .idle:
                Text("Type at least two letters.")
            default:
                Text("\(model.storeResults.count) results")
            }
        }
        .font(.system(size: 18 * s))
        .foregroundStyle(Theme.textSecondary)
        let row = model.storeResultIndex / c
        let shift = max(0, row - 1)
        // From below the search box and the result count to above the hints.
        let listHeight = max(tile, height - 400 * s)
        FocusScroll(focus: model.storeFocus == .results ? model.storeResultIndex : nil, height: listHeight,
                    snapshotShift: CGFloat(shift) * (tile + gap), scale: s) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: gap), count: c),
                      alignment: .leading, spacing: gap) {
                ForEach(Array(model.storeResults.enumerated()), id: \.element.id) { i, item in
                    StoreTile(item: item, inLibrary: model.inLibrary(item.id), scale: s)
                        .frame(width: tile, height: tile)
                        .focusFrame(model.storeFocus == .results && model.storeResultIndex == i, scale: s)
                        .onTapGesture { model.tapStoreResult(i) }
                        .scrollAnchor(i)
                }
            }
        }
    }
}

struct StoreTile: View {
    let item: StoreItem
    let inLibrary: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        GameArt(game: item.asGame, width: 600)
            .overlay(alignment: .bottomLeading) {
                if item.tileArt == nil {
                    Text(item.title)
                        .font(.system(size: 18 * s, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .padding(12 * s)
                }
            }
            .overlay(alignment: .topLeading) {
                if let label {
                    Text(label)
                        .font(.system(size: 12 * s, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7 * s)
                        .padding(.vertical, 3 * s)
                        .background(inLibrary || item.gamePass ? Theme.accent : .black.opacity(0.75))
                }
            }
    }

    private var label: String? {
        if inLibrary { return "IN LIBRARY" }
        if item.gamePass { return "GAME PASS" }
        return item.price
    }
}

/// The page of a game that is not in the library.
struct StoreItemView: View {
    @EnvironmentObject private var model: AppModel
    let item: StoreItem
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack(alignment: .bottomLeading) {
            HeroBackground(game: item.asGame)
            VStack(alignment: .leading, spacing: 18 * s) {
                Text(item.title)
                    .font(.system(size: 64 * s, weight: .bold))
                Text(item.publisher)
                    .font(.system(size: 22 * s))
                    .foregroundStyle(Theme.textSecondary)
                Text(priceLine)
                    .font(.system(size: 18 * s, weight: .medium))
                    .foregroundStyle(item.gamePass ? Theme.accentBright : Theme.textSecondary)
                    .padding(.bottom, 20 * s)
                HStack(spacing: 12 * s) {
                    Image(systemName: "safari")
                    Text("Open on xbox.com")
                }
                .font(.system(size: 20 * s, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 44 * s)
                .frame(height: 60 * s)
                .background(Theme.accent)
                .focusFrame(true, scale: s, radius: 4)
                .contentShape(Rectangle())
                .onTapGesture { model.openOnXbox(item.id) }
                Text("iOdus cannot buy games. A game that you get on xbox.com shows in your library when you start iOdus again.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8 * s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.bottom, 170 * s)
        }
    }

    private var priceLine: String {
        if item.gamePass { return "Included with Game Pass" }
        if let price = item.price { return price == "Free" ? "Free" : "Price: \(price)" }
        return "Microsoft Store"
    }
}

extension StoreItem {
    /// A Game value, so that the art views can show a Store item.
    var asGame: Game {
        Game(id: id, title: title, publisher: publisher, tileArt: tileArt, heroArt: heroArt,
             access: gamePass ? .gamePass : .owned)
    }
}
