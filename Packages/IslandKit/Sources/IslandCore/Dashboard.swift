import CoreGraphics
import Foundation

public enum WidgetSize: String, Codable, CaseIterable, Sendable, Identifiable {
    case small, medium
    public var id: String { rawValue }
    public var columns: Int { self == .small ? 1 : 2 }
    public var displayName: String { self == .small ? "Small" : "Medium" }
}

/// Everything that can sit on the dashboard.
public enum DashboardWidgetKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case nowPlaying, calendar, timer, battery, cpu, memory, storage, network
    case weather, shelf, clipboard, shortcuts, devices

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .calendar: "Calendar"
        case .timer: "Timer"
        case .battery: "Battery"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .weather: "Weather"
        case .shelf: "Shelf"
        case .clipboard: "Clipboard"
        case .shortcuts: "Shortcuts"
        case .devices: "Devices"
        }
    }

    public var symbolName: String {
        switch self {
        case .nowPlaying: "music.note"
        case .calendar: "calendar"
        case .timer: "timer"
        case .battery: "battery.75percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "arrow.up.arrow.down"
        case .weather: "cloud.sun.fill"
        case .shelf: "tray.full"
        case .clipboard: "doc.on.clipboard"
        case .shortcuts: "square.stack.3d.forward.dottedline"
        case .devices: "airpodspro"
        }
    }

    public var summary: String {
        switch self {
        case .nowPlaying: "Artwork, track and controls"
        case .calendar: "Your next events and a Join button"
        case .timer: "Running timer or quick presets"
        case .battery: "Charge, power source and time left"
        case .cpu: "Processor load with a live graph"
        case .memory: "Memory in use and pressure"
        case .storage: "Free space on your startup disk"
        case .network: "Download and upload speed"
        case .weather: "Conditions now and the next hours"
        case .shelf: "Files you dropped on the island"
        case .clipboard: "Recent copies, click to copy again"
        case .shortcuts: "Run your Shortcuts in one click"
        case .devices: "Connected AirPods and Bluetooth batteries"
        }
    }

    public var allowedSizes: [WidgetSize] {
        switch self {
        case .nowPlaying, .calendar, .cpu, .network, .weather, .shelf, .clipboard, .shortcuts, .devices: [.small, .medium]
        case .timer, .battery, .memory, .storage: [.small]
        }
    }

    /// The module that must be on for this widget to show, if any.
    public var module: ActivityKind? {
        switch self {
        case .nowPlaying: .nowPlaying
        case .calendar: .calendar
        case .timer: .timer
        case .battery: .battery
        case .shelf: .shelf
        case .devices: .devices
        case .cpu, .memory, .storage, .network, .weather, .clipboard, .shortcuts: nil
        }
    }

    public var isSystemStat: Bool { [.cpu, .memory, .storage, .network].contains(self) }
}

public struct DashboardItem: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var kind: DashboardWidgetKind
    public var size: WidgetSize
    public var id: DashboardWidgetKind { kind }

    public init(_ kind: DashboardWidgetKind, _ size: WidgetSize = .small) {
        self.kind = kind
        self.size = kind.allowedSizes.contains(size) ? size : kind.allowedSizes[0]
    }

    public static let defaults: [DashboardItem] = [
        DashboardItem(.nowPlaying, .medium), DashboardItem(.calendar), DashboardItem(.timer),
        DashboardItem(.battery), DashboardItem(.cpu), DashboardItem(.memory), DashboardItem(.storage),
    ]
}

/// A 4-column grid, like Notification Center widgets: small takes one slot,
/// medium takes two. Rows flow left to right; the dashboard grows by rows.
public enum DashboardLayout {
    public static let columns = 4
    public static let maxRows = 3
    public static let width: CGFloat = 680
    public static let cardHeight: CGFloat = 150
    public static let spacing: CGFloat = 10
    public static let topPadding: CGFloat = 10
    public static let bottomPadding: CGFloat = 14

    /// Packs items into rows in order. A medium item that doesn't fit the
    /// current row starts the next one. Items past `maxRows` are dropped.
    public static func rows(_ items: [DashboardItem]) -> [[DashboardItem]] {
        var rows: [[DashboardItem]] = []
        var current: [DashboardItem] = []
        var used = 0
        for item in items {
            let w = item.size.columns
            if used + w > columns {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(item)
            used += w
        }
        if !current.isEmpty { rows.append(current) }
        return Array(rows.prefix(maxRows))
    }

    /// Island body size for a dashboard with `rows` rows below the camera.
    public static func size(rows: Int, notchHeight: CGFloat) -> CGSize {
        let r = CGFloat(max(1, rows))
        return CGSize(width: width, height: notchHeight + topPadding + r * cardHeight + (r - 1) * spacing + bottomPadding)
    }
}
