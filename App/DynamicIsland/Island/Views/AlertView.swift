import IslandCore
import SwiftUI

/// A brief moment: the island grows, holds, and retracts on its own.
struct AlertView: View {
    let alert: IslandAlert
    let model: IslandViewModel

    var body: some View {
        if case .messages(let messages, let style) = alert.style, !messages.isEmpty {
            MessageAlertView(messages: messages, style: style, model: model)
        } else if alert.isHUD {
            HUDView(style: alert.style, model: model)
        } else if alert.isCompact {
            CompactAlertView(alert: alert, model: model)
        } else {
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.rect.height)
                HStack(spacing: 14) { content }
                    .padding(.horizontal, 22)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, IslandMetrics.shoulder)
        }
    }

    @ViewBuilder private var content: some View {
        switch alert.style {
        case .chargerConnected(let p):
            symbol("bolt.fill", .green)
            titles("Charging", "\(p)%")
            Spacer()
            Ring(fraction: Double(p) / 100, color: .green, lineWidth: 4).frame(width: 34, height: 34)
        case .chargerDisconnected(let p):
            symbol("powerplug.portrait", .secondary)
            titles("On battery", "\(p)% remaining")
            Spacer()
            Ring(fraction: Double(p) / 100, color: p <= 20 ? .red : .primary, lineWidth: 4).frame(width: 34, height: 34)
        case .lowBattery(let p):
            symbol("battery.25percent", .red)
            titles("Low battery", "\(p)% remaining. Plug in soon.")
            Spacer()
        case .timerFinished(let label):
            symbol("timer", .orange)
            titles("Timer done", label)
            Spacer()
            IslandCapsuleButton(title: "Dismiss") { model.env.engine.dismissAlert() }
        case .deviceConnected(let device):
            DeviceAlertContent(device: device)
        case .deviceDisconnected(let name, let kind):
            symbol(kind.symbolName, .secondary)
            titles(name, "Disconnected")
            Spacer()
        case .downloadFinished(let name, let path):
            DownloadAlertContent(name: name, path: path, model: model)
        case .volume, .brightness:
            EmptyView()
        case .message(let title, let subtitle, let symbolName):
            symbol(symbolName, Color.accentColor)
            titles(title, subtitle)
            Spacer()
            DashboardButton(model: model, size: 28)
        case .messages:
            EmptyView() // drawn by MessageAlertView
        case .agentFinished(let f):
            AgentBadge(agent: f.agent, size: 30).frame(width: 36)
            titles("\(f.agent.displayName) finished", "\(f.project) · \(IslandFormat.took(f.duration))")
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: alert.id)
        case .updateAvailable(let version):
            symbol("arrow.down.circle.fill", Color.accentColor)
            titles("Update available", "Dynamic Island \(version)")
            Spacer()
            IslandCapsuleButton(title: "Install", prominent: true) {
                model.env.engine.dismissAlert()
                model.env.updates.checkForUpdates()
            }
        case .eventStarting(let e):
            symbol("calendar", Color(hex: e.calendarColorHex))
            titles(e.title, "Starting now")
            Spacer()
            if let url = e.joinURL {
                IslandCapsuleButton(title: "Join", systemName: "video.fill", prominent: true) {
                    NSWorkspace.shared.open(url)
                    model.env.engine.dismissAlert()
                }
            }
        }
    }

    private func symbol(_ name: String, _ style: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(style)
            .symbolEffect(.bounce, value: alert.id)
            .frame(width: 36)
    }

    private func titles(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}
