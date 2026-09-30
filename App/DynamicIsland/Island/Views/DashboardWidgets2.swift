import AppKit
import IslandCore
import SwiftUI

struct WeatherWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let w = env.weather
        if let r = w.report {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(Int(r.temperature.rounded()))°").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(r.condition.summary).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                    Text([r.high.map { "H \(Int($0.rounded()))°" }, r.low.map { "L \(Int($0.rounded()))°" }].compactMap { $0 }.joined(separator: "  "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: r.condition.symbolName).symbolRenderingMode(.multicolor).font(.system(size: 26))
            }
            Spacer(minLength: 0)
            if size == .medium {
                HStack {
                    ForEach(r.hours.prefix(6)) { h in
                        VStack(spacing: 3) {
                            Text(h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)))).font(.system(size: 10)).foregroundStyle(.secondary)
                            Image(systemName: WeatherCondition(code: h.code, isDay: h.isDay).symbolName).symbolRenderingMode(.multicolor).font(.system(size: 13))
                            Text("\(Int(h.temperature.rounded()))°").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text(w.placeName ?? r.place ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Spacer(minLength: 0)
            switch w.state {
            case .needsLocation:
                Text("Choose a place in Settings").font(.system(size: 12)).foregroundStyle(.secondary)
                IslandCapsuleButton(title: "Set Location") { env.openSettings() }
            case .failed(let m):
                Text(m).font(.system(size: 12)).foregroundStyle(.secondary)
                IslandCapsuleButton(title: "Try Again") { w.refresh() }
            default:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Getting weather…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ShelfWidget: View {
    let size: WidgetSize
    let model: IslandViewModel
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let shelf = env.shelf
        if shelf.items.isEmpty {
            Spacer(minLength: 0)
            Text("Drag files onto the island to keep them here").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            HStack(spacing: 8) {
                ForEach(shelf.items.prefix(size == .medium ? 5 : 2)) { item in
                    Image(nsImage: shelf.icon(for: item)).resizable().aspectRatio(contentMode: .fit).frame(width: 38, height: 38)
                        .onDrag { NSItemProvider(contentsOf: shelf.url(for: item)) ?? NSItemProvider() }
                        .help(item.name)
                }
                if shelf.items.count > (size == .medium ? 5 : 2) { OverflowChip(count: shelf.items.count - (size == .medium ? 5 : 2)) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                IslandCapsuleButton(title: "Open Shelf", fillWidth: true) { model.openShelf() }
                IslandIconButton(systemName: "airdrop", size: 26, label: "AirDrop all") { shelf.airDrop(shelf.items) }
            }
        }
    }
}

struct ClipboardWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let clip = env.clipboard
        if !env.settings.settings.clipboard.enabled {
            Spacer(minLength: 0)
            Text("Clipboard history is off").font(.system(size: 12)).foregroundStyle(.secondary)
            IslandCapsuleButton(title: "Turn On") { env.settings.settings.clipboard.enabled = true }
            Spacer(minLength: 0)
        } else if clip.entries.isEmpty {
            Spacer(minLength: 0)
            Text("Copy something and it shows up here").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(clip.entries.prefix(size == .medium ? 4 : 3)) { entry in
                    ClipRow(entry: entry, showSource: size == .medium)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ClipRow: View {
    let entry: ClipboardEntry
    let showSource: Bool
    @Environment(AppEnvironment.self) private var env
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            env.clipboard.copy(entry)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(copied ? .green : .secondary).frame(width: 14)
                Text(entry.preview).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
                if showSource, let app = entry.sourceApp { Text(app).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy again")
    }

    private var symbol: String {
        switch entry.content {
        case .text: "text.alignleft"
        case .link: "link"
        case .files: "doc"
        case .image: "photo"
        }
    }
}

struct ShortcutsWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let pinned = env.settings.settings.shortcuts.pinned
        if pinned.isEmpty {
            Spacer(minLength: 0)
            Text("Pin shortcuts in Settings › Dashboard").font(.system(size: 11.5)).foregroundStyle(.secondary)
            IslandCapsuleButton(title: "Choose…") { env.openSettings() }
            Spacer(minLength: 0)
        } else {
            let columns = size == .medium ? 2 : 1
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), alignment: .leading, spacing: 6) {
                ForEach(pinned.prefix(size == .medium ? 6 : 3), id: \.self) { name in
                    ShortcutButton(name: name)
                }
            }
            Spacer(minLength: 0)
            if let error = env.shortcuts.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }
}

private struct ShortcutButton: View {
    let name: String
    @Environment(AppEnvironment.self) private var env
    @State private var hovering = false

    var body: some View {
        let running = env.shortcuts.running.contains(name)
        Button { env.shortcuts.run(name) } label: {
            HStack(spacing: 6) {
                if running { ProgressView().controlSize(.mini) } else {
                    Image(systemName: "square.stack.3d.forward.dottedline.fill").font(.system(size: 10)).foregroundStyle(.pink)
                }
                Text(name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(.primary.opacity(hovering ? 0.16 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Run “\(name)”")
    }
}

struct DevicesWidget: View {
    let size: WidgetSize
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        // Audio devices first (they're what people check), then the rest.
        let devices = env.devices.connected.sorted { $0.kind.isAudio && !$1.kind.isAudio }
        if devices.isEmpty {
            Spacer(minLength: 0)
            Text(env.settings.settings[module: .devices].enabled ? "No devices connected" : "Turn on AirPods and Bluetooth in Modules")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(devices.prefix(size == .medium ? 3 : 2)) { d in
                    HStack(spacing: 8) {
                        Image(systemName: d.kind.symbolName).font(.system(size: 15)).frame(width: 20)
                        Text(d.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DevicesModuleSettings.batteryText(d)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
