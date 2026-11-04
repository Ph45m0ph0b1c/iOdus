import SwiftUI

/// "My games & apps": a grid of all games, with a left column for filters.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 48 * s) {
                sidebar(s)
                    .frame(width: 280 * s)
                grid(s, size: geo.size)
            }
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.top, 150 * s)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func sidebar(_ s: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8 * s) {
            Text("My games & apps")
                .font(.system(size: 34 * s, weight: .semibold))
                .padding(.bottom, 24 * s)
            ForEach(LibraryFilter.allCases, id: \.self) { filter in
                let selected = model.libraryFilter == filter
                HStack {
                    Text(filter.rawValue)
                    Spacer()
                    Text("\(model.games(in: filter).count)")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 20 * s, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.vertical, 10 * s)
                .padding(.horizontal, 14 * s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.tile : .clear,
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius * s))
                .focusFrame(selected && model.libraryFocus == .filters, scale: s, radius: Theme.cornerRadius)
                .contentShape(Rectangle())
                .onTapGesture { model.tapFilter(filter) }
            }
        }
        .foregroundStyle(Theme.textPrimary)
    }

    static func emptyText(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: return "There are no games in your library."
        case .owned: return "You own no games outside Game Pass."
        case .gamePass: return "No Game Pass games are available to this account."
        case .installed: return "No installed games yet. Open a game and select Install."
        }
    }

    private func grid(_ s: CGFloat, size: CGSize) -> some View {
        let c = model.libraryColumns
        let gap: CGFloat = 18 * s
        let available = size.width - Theme.sidePadding * 2 * s - 280 * s - 48 * s
        let tile = (available - gap * CGFloat(c - 1)) / CGFloat(c)
        let row = model.libraryIndex / c
        let rowsVisible = max(1, Int((size.height - 150 * s - 140 * s) / (tile + gap)))
        let shift = max(0, row - rowsVisible + 1)

        let list = model.libraryGames
        return VStack(alignment: .leading, spacing: 16 * s) {
            Text("\(model.libraryFilter.rawValue) · \(list.count) \(list.count == 1 ? "game" : "games") · Sorted by name")
                .font(.system(size: 18 * s))
                .foregroundStyle(Theme.textSecondary)
            if list.isEmpty {
                Text(model.librarySearch.isEmpty ? Self.emptyText(model.libraryFilter)
                     : "No games match \u{201C}\(model.librarySearch)\u{201D}.")
                    .font(.system(size: 22 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 40 * s)
            }
            // From below the count line to above the hints.
            FocusScroll(focus: model.libraryFocus == .grid ? model.libraryIndex : nil,
                        height: max(tile, size.height - 330 * s),
                        snapshotShift: CGFloat(shift) * (tile + gap), scale: s) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: gap), count: c),
                          alignment: .leading, spacing: gap) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, game in
                        GameTile(game: game, scale: s)
                            .frame(width: tile, height: tile)
                            .focusFrame(model.libraryIndex == i && model.libraryFocus == .grid, scale: s)
                            .onTapGesture { model.tapLibrary(i) }
                            .scrollAnchor(i)
                    }
                }
            }
        }
    }
}
