import AppKit
import IslandCore
import SwiftUI

// MARK: compact pieces

/// Compact leading content for the Phase 2 kinds.
struct Phase2Leading: View {
    let payload: ActivityPayload

    var body: some View {
        switch payload {
        case .shelf:
            Image(systemName: "tray.full.fill").foregroundStyle(.teal)
        case .download(let d):
            DownloadRing(fraction: d.fraction, size: 18)
        case .privacy(let p):
            HStack(spacing: 4) {
                if p.microphone { Image(systemName: "mic.fill").foregroundStyle(.orange) }
                if p.camera { Image(systemName: "video.fill").foregroundStyle(.green) }
            }
        default:
            EmptyView()
        }
    }
}

struct Phase2Trailing: View {
    let payload: ActivityPayload

    var body: some View {
        switch payload {
        case .shelf(let items):
            Text("\(items.count)").monospacedDigit().foregroundStyle(.teal)
        case .download(let d):
            if let f = d.fraction {
                Text("\(Int((f * 100).rounded()))%").monospacedDigit().foregroundStyle(.blue)
                    .contentTransition(.numericText())
            } else {
                ProgressView().controlSize(.mini).tint(.blue)
            }
        case .privacy(let p):
            HStack(spacing: 4) {
                if p.microphone { Circle().fill(.orange).frame(width: 7, height: 7) }
                if p.camera { Circle().fill(.green).frame(width: 7, height: 7) }
            }
        default:
            EmptyView()
        }
    }
}

/// Below-the-notch band content for the Phase 2 kinds.
struct Phase2Band: View {
    let payload: ActivityPayload

    var body: some View {
        switch payload {
        case .shelf(let items):
            Image(systemName: "tray.full.fill").foregroundStyle(.teal)
            Text(items.count == 1 ? items[0].name : "\(items.count) items on the shelf").lineLimit(1)
            Spacer(minLength: 4)
        case .download(let d):
            DownloadRing(fraction: d.fraction, size: 15)
            Text(d.name).lineLimit(1)
            Spacer(minLength: 4)
            Phase2Trailing(payload: payload)
        case .privacy(let p):
            Phase2Leading(payload: payload)
            Text(p.microphone && p.camera ? "Mic and camera in use" : p.microphone ? "Microphone in use" : "Camera in use").lineLimit(1)
            Spacer(minLength: 4)
        default:
            EmptyView()
        }
    }
}

struct Phase2Glyph: View {
    let payload: ActivityPayload

    var body: some View {
        switch payload {
        case .shelf: Image(systemName: "tray.full.fill").foregroundStyle(.teal).frame(width: 20, height: 20)
        case .download(let d): DownloadRing(fraction: d.fraction, size: 16).frame(width: 20, height: 20)
        case .privacy(let p): Circle().fill(p.camera ? Color.green : .orange).frame(width: 8, height: 8).frame(width: 20, height: 20)
        default: EmptyView()
        }
    }
}

struct DownloadRing: View {
    let fraction: Double?
    let size: CGFloat

    var body: some View {
        ZStack {
            if let fraction {
                Ring(fraction: fraction, color: .blue, lineWidth: size > 20 ? 4 : 2.4)
            } else {
                Circle().stroke(Color.blue.opacity(0.35), lineWidth: size > 20 ? 4 : 2.4)
            }
            Image(systemName: "arrow.down").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.blue)
        }
        .frame(width: size, height: size)
    }
}

// MARK: expanded

struct DownloadsExpanded: View {
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let downloads = env.downloads.downloads
        EarRow(model: model) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text(downloads.count == 1 ? "Downloading" : "\(downloads.count) downloads")
        } trailing: {
            EmptyView()
        }
        VStack(spacing: 10) {
            ForEach(downloads.prefix(3)) { d in
                HStack(spacing: 12) {
                    DownloadRing(fraction: d.fraction, size: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(d.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let f = d.fraction { ProgressTrack(fraction: f, height: 4) }
                        Text(Self.detail(d)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    IslandIconButton(systemName: "magnifyingglass", size: 28, label: "Show in Finder") { env.downloads.reveal(d) }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    static func detail(_ d: DownloadInfo) -> String {
        switch (d.completedBytes, d.totalBytes) {
        case let (done?, total?): "\(ByteFormat.size(done)) of \(ByteFormat.size(total))"
        case let (done?, nil): ByteFormat.size(done)
        default: d.fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "Starting…"
        }
    }
}

struct PrivacyExpanded: View {
    let info: PrivacyInfo
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        EarRow(model: model) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            Text("Privacy")
        } trailing: {
            EmptyView()
        }
        VStack(alignment: .leading, spacing: 8) {
            if info.microphone { row("mic.fill", .orange, "Your microphone is in use") }
            if info.camera { row("video.fill", .green, "A camera is in use") }
            TimelineView(.everyMinute) { ctx in
                Text(env.privacy.since.map { "For \(IslandFormat.duration(minutes: max(1, Int(ctx.date.timeIntervalSince($0) / 60))))" } ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 10)
    }

    private func row(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            Text(text).font(.system(size: 14, weight: .semibold))
        }
    }
}

// MARK: alerts

struct HUDView: View {
    let style: IslandAlert.Style
    let model: IslandViewModel

    var body: some View {
        let (symbol, level, color) = parts
        if model.settings.compactStyle == .beside {
            let notchW = model.notch.rect.width
            let ear = max(0, (model.bodySize.width - notchW) / 2)
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: ear - 16, alignment: .leading)
                    .padding(.leading, 16)
                Color.clear.frame(width: notchW)
                HUDBar(level: level, color: color)
                    .frame(width: max(0, ear - 34))
                    .padding(.leading, 14)
                    .padding(.trailing, 20)
            }
            .frame(height: model.notch.rect.height)
            .padding(.horizontal, IslandMetrics.shoulder)
            .modifier(EarForeground(material: model.material))
        } else {
            VStack(spacing: 0) {
                Color.clear.frame(height: model.notch.rect.height)
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                    HUDBar(level: level, color: color)
                    Text("\(Int((level * 100).rounded()))").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .frame(width: 26, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .frame(height: IslandMetrics.belowBand - 2)
            }
            .padding(.horizontal, IslandMetrics.shoulder)
        }
    }

    private var parts: (String, Double, Color) {
        switch style {
        case .volume(let level, let muted, _):
            let symbol = muted || level == 0 ? "speaker.slash.fill"
                : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            return (symbol, muted ? 0 : level, .white)
        case .brightness(let level):
            return (level < 0.5 ? "sun.min.fill" : "sun.max.fill", level, .yellow)
        default:
            return ("questionmark", 0, .white)
        }
    }
}

private struct HUDBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.22))
                Capsule().fill(color == .white ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
                    .frame(width: max(0, g.size.width * min(1, max(0, level))))
            }
        }
        .frame(height: 6)
        .animation(.snappy(duration: 0.18), value: level)
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}

struct DeviceAlertContent: View {
    let device: BluetoothDeviceInfo

    var body: some View {
        Image(systemName: device.kind.symbolName)
            .font(.system(size: 30, weight: .regular))
            .symbolEffect(.bounce, value: device.id)
            .frame(width: 44)
        VStack(alignment: .leading, spacing: 1) {
            Text(device.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("Connected").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        HStack(spacing: 10) {
            if let l = device.batteryLeft { BatteryDot(label: "L", percent: l) }
            if let r = device.batteryRight { BatteryDot(label: "R", percent: r) }
            if let c = device.batteryCase { BatteryDot(label: "Case", percent: c) }
            if let b = device.battery, device.batteryLeft == nil { BatteryDot(label: nil, percent: b) }
        }
    }
}

struct BatteryDot: View {
    let label: String?
    let percent: Int

    var body: some View {
        VStack(spacing: 3) {
            Ring(fraction: Double(percent) / 100, color: percent <= 20 ? .red : .green, lineWidth: 3.5)
                .frame(width: 32, height: 32)
                .overlay(Text("\(percent)").font(.system(size: 10, weight: .bold)).monospacedDigit())
            if let label { Text(label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary) }
        }
    }
}

struct DownloadAlertContent: View {
    let name: String
    let path: String
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable().frame(width: 40, height: 40)
        VStack(alignment: .leading, spacing: 1) {
            Text("Downloaded").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        Spacer(minLength: 8)
        IslandCapsuleButton(title: "Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)); env.engine.dismissAlert() }
        IslandCapsuleButton(title: "Show") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            env.engine.dismissAlert()
        }
        if model.settings[module: .shelf].enabled {
            IslandIconButton(systemName: "tray.and.arrow.down", size: 28, label: "Keep on the shelf") {
                env.shelf.add(urls: [URL(fileURLWithPath: path)])
                env.engine.dismissAlert()
            }
        }
    }
}
