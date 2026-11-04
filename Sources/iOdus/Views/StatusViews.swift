import SwiftUI

/// The controller icon of the top bar, with the battery of the first controller.
struct ControllerIndicator: View {
    let controllers: [ControllerStatus]
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(spacing: 6 * s) {
            if controllers.isEmpty {
                Image(systemName: "gamecontroller")
                    .opacity(0.45)
                    .overlay {
                        // No SF Symbol has a crossed-out controller, so draw the line.
                        Rectangle()
                            .fill(Theme.textPrimary.opacity(0.7))
                            .frame(width: 30 * s, height: 2 * s)
                            .rotationEffect(.degrees(-35))
                    }
            } else {
                Image(systemName: "gamecontroller.fill")
                if let first = controllers.first, let symbol = first.batterySymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 16 * s))
                        .foregroundStyle(first.lowBattery ? Theme.buttonB : Theme.textPrimary)
                }
                if controllers.count > 1 {
                    Text("\(controllers.count)")
                        .font(.system(size: 14 * s, weight: .bold))
                }
            }
        }
    }
}

/// The panel below the top bar that the bell, controller, or network icon opens.
struct StatusPanelView: View {
    @EnvironmentObject private var model: AppModel
    let panel: StatusPanel
    let scale: CGFloat

    var body: some View {
        let s = scale
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.statusPanel = nil }
            VStack(alignment: .leading, spacing: 16 * s) {
                content(s)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(24 * s)
            .frame(width: 480 * s, alignment: .leading)
            .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 8 * s))
            .shadow(color: .black.opacity(0.5), radius: 20 * s, y: 8 * s)
            .padding(.top, 100 * s)
            .padding(.trailing, Theme.sidePadding * s)
        }
    }

    @ViewBuilder
    private func content(_ s: CGFloat) -> some View {
        switch panel {
        case .controllers:
            Text("Controllers")
                .font(.system(size: 24 * s, weight: .semibold))
            if model.controllers.isEmpty {
                Text("No controller is connected. Connect an Xbox controller with Bluetooth or USB. The keyboard and the mouse also work.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(model.controllers) { controller in
                    HStack(spacing: 16 * s) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 26 * s))
                            .frame(width: 44 * s)
                        VStack(alignment: .leading, spacing: 4 * s) {
                            Text(controller.name)
                                .font(.system(size: 19 * s, weight: .medium))
                            HStack(spacing: 8 * s) {
                                if let symbol = controller.batterySymbol {
                                    Image(systemName: symbol)
                                }
                                Text(controller.batteryText)
                            }
                            .font(.system(size: 15 * s))
                            .foregroundStyle(controller.lowBattery ? Theme.buttonB : Theme.textSecondary)
                        }
                    }
                }
            }
        case .network:
            Text("Network")
                .font(.system(size: 24 * s, weight: .semibold))
            row("Connection", model.network.kindText, symbol: model.network.symbol,
                good: model.network.online, s)
            row("Xbox Live", model.network.serviceText,
                symbol: model.network.xboxLive == .reachable ? "checkmark.shield" : "exclamationmark.shield",
                good: model.network.xboxLive == .reachable, s)
            if let checked = model.network.checkedAt {
                Text("Checked at " + checked.formatted(date: .omitted, time: .shortened) + ". Press A to check again.")
                    .font(.system(size: 14 * s))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .notifications:
            Text("Notifications")
                .font(.system(size: 24 * s, weight: .semibold))
            if model.notifications.isEmpty {
                Text("No notifications. iOdus tells you here when a download is complete or when you unlock achievements.")
                    .font(.system(size: 17 * s))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                let shown = Array(model.notifications.prefix(6).enumerated())
                ForEach(shown, id: \.element.id) { i, item in
                    NotificationRow(item: item, focused: model.notificationIndex == i, scale: s)
                        .contentShape(Rectangle())
                        .onTapGesture { model.openNotification(i) }
                }
                if model.notifications.count > 6 {
                    Text("\(model.notifications.count - 6) older notifications are not shown.")
                        .font(.system(size: 14 * s))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func row(_ title: String, _ value: String, symbol: String, good: Bool, _ s: CGFloat) -> some View {
        HStack(spacing: 16 * s) {
            Image(systemName: symbol)
                .font(.system(size: 22 * s))
                .frame(width: 44 * s)
            VStack(alignment: .leading, spacing: 4 * s) {
                Text(title).font(.system(size: 19 * s, weight: .medium))
                Text(value)
                    .font(.system(size: 15 * s))
                    .foregroundStyle(good ? Theme.accentBright : Theme.buttonY)
            }
        }
    }
}

/// The network icon of the top bar. A yellow mark shows when Xbox Live does not answer.
struct NetworkIndicator: View {
    let status: NetworkStatus
    let scale: CGFloat

    var body: some View {
        Image(systemName: status.symbol)
            .opacity(status.online ? 1 : 0.6)
            .overlay(alignment: .bottomTrailing) {
                if status.online && status.xboxLive == .unreachable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11 * scale))
                        .foregroundStyle(Theme.buttonY)
                        .offset(x: 6 * scale, y: 4 * scale)
                }
            }
    }
}

/// The bell of the top bar, with a badge for unread notifications.
struct BellIndicator: View {
    let unread: Int
    let scale: CGFloat

    var body: some View {
        Image(systemName: unread > 0 ? "bell.fill" : "bell")
            .overlay(alignment: .topTrailing) {
                if unread > 0 {
                    Text(unread > 9 ? "9+" : "\(unread)")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4 * scale)
                        .frame(minWidth: 18 * scale, minHeight: 18 * scale)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 9 * scale, y: -7 * scale)
                }
            }
    }
}

struct NotificationRow: View {
    let item: AppNotification
    let focused: Bool
    let scale: CGFloat

    var body: some View {
        let s = scale
        HStack(alignment: .top, spacing: 14 * s) {
            Image(systemName: item.symbol)
                .font(.system(size: 20 * s))
                .foregroundStyle(color)
                .frame(width: 28 * s)
            VStack(alignment: .leading, spacing: 3 * s) {
                Text(item.title)
                    .font(.system(size: 17 * s, weight: item.read ? .regular : .semibold))
                    .lineLimit(2)
                Text(item.detail)
                    .font(.system(size: 14 * s))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                Text(item.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 12 * s))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(10 * s)
        .background(focused ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6 * s))
    }

    private var color: Color {
        switch item.kind {
        case .installed: return Theme.accentBright
        case .downloadFailed: return Theme.buttonB
        case .achievements: return Theme.buttonY
        case .update: return Theme.buttonX
        case .message: return Theme.accentBright
        case .info: return Theme.textSecondary
        }
    }
}
