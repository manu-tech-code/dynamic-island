import IslandCore
import SwiftUI

/// Status alerts shown like a compact activity: an icon on the left and a ring
/// on the right (AirPods, chargers, low battery), or a band below the notch.
/// Hovering a device's icon drops its name and batteries down, and keeps the
/// alert up while they're read.
struct CompactAlertView: View {
    let alert: IslandAlert
    let model: IslandViewModel

    var body: some View {
        Group {
            switch model.settings.compactStyle {
            case .beside: beside
            case .below: below
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenSummary)
    }

    private var beside: some View {
        let notchW = model.notch.rect.width
        let ear = max(0, (model.bodySize.width - notchW) / 2)
        let inner = max(0, ear - IslandMetrics.earOuterPadding - IslandMetrics.earInnerGap)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                icon
                    .frame(width: inner, alignment: .leading)
                    .padding(.leading, IslandMetrics.earOuterPadding)
                    .padding(.trailing, IslandMetrics.earInnerGap)
                Color.clear.frame(width: notchW)
                status
                    .frame(width: inner, alignment: .trailing)
                    .padding(.leading, IslandMetrics.earInnerGap)
                    .padding(.trailing, IslandMetrics.earOuterPadding)
            }
            .frame(height: model.notch.rect.height)
            .padding(.horizontal, IslandMetrics.shoulder)
            .font(.system(size: 13, weight: .semibold))
            if let device = model.peekingDevice {
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(Self.batteryLine(device)).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1)
                        .opacity(0.68)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, IslandMetrics.shoulder + IslandMetrics.earOuterPadding)
                .padding(.top, 2)
                .modifier(MediaHotspot(model: model, key: "title"))
                .transition(.peekRow)
            }
        }
        .modifier(EarForeground(material: model.material))
    }

    private var below: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.rect.height)
            HStack(spacing: 8) {
                icon
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                status
            }
            .padding(.horizontal, 14)
            .frame(height: IslandMetrics.belowBand - 2)
            if let device = model.peekingDevice {
                Text(Self.batteryLine(device))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14 + IslandMetrics.glyph + 8)
                    .padding(.trailing, 14)
                    .modifier(MediaHotspot(model: model, key: "title"))
                    .transition(.peekRow)
            }
        }
        .padding(.horizontal, IslandMetrics.shoulder)
        .font(.system(size: 12, weight: .semibold))
    }

    // MARK: pieces

    @ViewBuilder private var icon: some View {
        switch alert.style {
        case .deviceConnected(let d):
            symbol(d.kind.symbolName).modifier(MediaHotspot(model: model, key: "alertIcon"))
        case .deviceDisconnected(_, let kind):
            symbol(kind.symbolName).opacity(0.5)
        case .chargerConnected:
            symbol("bolt.fill").foregroundStyle(.green)
        case .chargerDisconnected:
            symbol("powerplug.portrait.fill").opacity(0.7)
        case .lowBattery:
            symbol("battery.25percent").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var status: some View {
        switch alert.style {
        case .deviceConnected(let d):
            if let p = d.ringPercent { ring(p) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .deviceDisconnected:
            Image(systemName: "xmark.circle.fill").opacity(0.45)
        case .chargerConnected(let p):
            percent(p, color: .green)
        case .chargerDisconnected(let p):
            percent(p, color: Self.color(p, charging: false))
        case .lowBattery(let p):
            percent(p, color: .red)
        default:
            EmptyView()
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .symbolEffect(.bounce, value: alert.id)
            .frame(height: IslandMetrics.glyph)
    }

    private func ring(_ p: Int, color: Color? = nil) -> some View {
        Ring(fraction: Double(p) / 100, color: color ?? Self.color(p, charging: false), lineWidth: 2.5)
            .frame(width: 17, height: 17)
    }

    private func percent(_ p: Int, color: Color) -> some View {
        HStack(spacing: IslandMetrics.glyphSpacing) {
            Text("\(p)%").monospacedDigit().foregroundStyle(color)
            ring(p, color: color)
        }
    }

    /// Green, orange from 20 %, red from 10 %.
    static func color(_ p: Int, charging: Bool) -> Color {
        if charging { return .green }
        return p <= 10 ? .red : p <= 20 ? .orange : .green
    }

    static func batteryLine(_ d: BluetoothDeviceInfo) -> String {
        var parts: [String] = []
        if let l = d.batteryLeft { parts.append("L \(l)%") }
        if let r = d.batteryRight { parts.append("R \(r)%") }
        if let c = d.batteryCase { parts.append("Case \(c)%") }
        if parts.isEmpty, let b = d.battery { parts.append("Battery \(b)%") }
        return parts.joined(separator: " · ")
    }

    private var title: String {
        switch alert.style {
        case .deviceConnected(let d): d.name
        case .deviceDisconnected(let name, _): name
        case .chargerConnected: "Charging"
        case .chargerDisconnected: "On battery"
        case .lowBattery: "Low battery"
        default: ""
        }
    }

    private var spokenSummary: String {
        switch alert.style {
        case .deviceConnected(let d): "\(d.name) connected" + (d.hasBattery ? ", \(Self.batteryLine(d))" : "")
        case .deviceDisconnected(let name, _): "\(name) disconnected"
        case .chargerConnected(let p): "Charging, \(p) percent"
        case .chargerDisconnected(let p): "On battery, \(p) percent"
        case .lowBattery(let p): "Low battery, \(p) percent"
        default: ""
        }
    }
}
