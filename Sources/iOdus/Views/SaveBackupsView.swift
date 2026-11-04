import SwiftUI

/// The save backups of one game: A restores, X deletes.
struct SaveBackupsView: View {
    @EnvironmentObject private var model: AppModel
    let game: Game
    let scale: CGFloat

    var body: some View {
        let s = scale
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 14 * s) {
                HStack(alignment: .firstTextBaseline, spacing: 20 * s) {
                    Text("Save backups")
                        .font(.system(size: 40 * s, weight: .semibold))
                    Text(game.title)
                        .font(.system(size: 20 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("iOdus makes a backup of the Mac save before a cloud download and before a restore.")
                    .font(.system(size: 18 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.bottom, 10 * s)
                content(s, height: geo.size.height)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(maxWidth: 1100 * s, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.sidePadding * s)
            .padding(.top, 150 * s)
        }
        .background(
            LinearGradient(colors: [Color(white: 0.10), Theme.background], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder
    private func content(_ s: CGFloat, height: CGFloat) -> some View {
        if model.saveBackupList.isEmpty {
            Text("This game has no save backups.")
                .font(.system(size: 22 * s)).foregroundStyle(Theme.textSecondary)
        } else {
            let rowHeight: CGFloat = 86 * s, gap: CGFloat = 10 * s
            let listHeight = max(rowHeight, height - 420 * s)
            let visible = max(1, Int(listHeight / (rowHeight + gap)))
            let shift = max(0, model.backupIndex - visible + 1)
            FocusScroll(focus: model.backupIndex, height: listHeight,
                        snapshotShift: CGFloat(shift) * (rowHeight + gap), scale: s) {
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Array(model.saveBackupList.enumerated()), id: \.element.id) { i, backup in
                        SaveBackupRow(backup: backup, newest: i == 0, scale: s)
                            .frame(height: rowHeight)
                            .focusFrame(model.backupIndex == i, scale: s)
                            .contentShape(Rectangle())
                            .onTapGesture { model.tapBackup(i) }
                            .scrollAnchor(i)
                    }
                }
            }
        }
    }
}

struct SaveBackupRow: View {
    let backup: SaveBackup
    let newest: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 20 * s) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 26 * s))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56 * s, height: 56 * s)
                .background(Color.white.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 6 * s) {
                HStack(spacing: 12 * s) {
                    Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 22 * s, weight: .semibold))
                    if newest {
                        Text("Newest")
                            .font(.system(size: 14 * s, weight: .semibold))
                            .padding(.horizontal, 10 * s)
                            .padding(.vertical, 3 * s)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tile, in: RoundedRectangle(cornerRadius: 4 * s))
    }

    private var detail: String {
        let age = GameDetailView.relative(backup.date)
        let accounts = backup.accounts.count == 1 ? "1 account" : "\(backup.accounts.count) accounts"
        return "Made \(age) · \(Bytes.text(backup.bytes)) · \(accounts)"
    }
}
