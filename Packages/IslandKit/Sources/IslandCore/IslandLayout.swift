import CoreGraphics
import Foundation

public enum IslandMaterial: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Black where it meets the notch, dissolving into system Liquid Glass.
    case hybrid
    /// System Liquid Glass everywhere.
    case glass
    /// Opaque black, like the iPhone.
    case black

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .hybrid: "Hybrid"
        case .glass: "Glass"
        case .black: "Black"
        }
    }
}

public enum CompactStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Content in "ears" beside the camera. Covers menu bar items next to the notch.
    case beside
    /// Content in a band hanging below the camera. Covers no menu bar items.
    case below

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .beside: "Beside the notch"
        case .below: "Below the notch"
        }
    }
}

/// What the island is currently showing.
public enum IslandPresentation: Equatable, Sendable {
    case idle
    case compact
    case expanded(activityID: String)
    case dashboard
    case alert(IslandAlert)

    public var isOpen: Bool {
        switch self {
        case .expanded, .dashboard: true
        default: false
        }
    }
}

/// Every size the island takes, in points. The body width excludes the two
/// concave shoulders where the shape meets the bezel.
public enum IslandMetrics {
    public static let shoulder: CGFloat = 6
    public static let belowBand: CGFloat = 28
    /// Space between the outer edge of an ear and its content.
    public static let earOuterPadding: CGFloat = 16
    /// Space between ear content and the camera housing.
    public static let earInnerGap: CGFloat = 14
    public static let glyph: CGFloat = 20
    public static let glyphSpacing: CGFloat = 6
    /// Default one-row dashboard; the real height follows the widget rows.
    public static let dashboard = DashboardLayout.size(rows: 1, notchHeight: 32)
    /// Now Playing with lyrics or Up Next open.
    public static let nowPlayingDetail = CGSize(width: 520, height: 340)

    /// Width of the "+N" chip, sized for its digits.
    public static func overflowChipWidth(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return 16 + 7.5 * CGFloat(String(count).count + 1)
    }

    // MARK: compact

    /// Widest of the leading/trailing content for the primary activity.
    public static func primaryEarContent(_ payload: ActivityPayload) -> CGFloat {
        switch payload {
        case .nowPlaying: return 24
        case .timer(let t): return t.duration >= 3600 ? 56 : 40
        case .calendar: return 34
        case .battery: return 30
        case .backgroundApps(let apps): return iconRowWidth(count: Int((Double(apps.count) / 2).rounded(.up)))
        }
    }

    public static func iconRowWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * glyph + CGFloat(count - 1) * glyphSpacing
    }

    /// Extra trailing width for secondary activities and the overflow chip.
    public static func secondaryWidth(secondaries: Int, overflow: Int) -> CGFloat {
        var w: CGFloat = 0
        if secondaries > 0 { w += 8 + iconRowWidth(count: secondaries) }
        if overflow > 0 { w += glyphSpacing + overflowChipWidth(overflow) }
        return w
    }

    public static func compactSize(notch: CGSize, style: CompactStyle, ranked: RankedActivities, backgroundIconLimit: Int) -> CGSize {
        guard let primary = ranked.primary else { return idleSize(notch: notch) }
        let secondaries = ranked.secondaries.count
        let overflow = ranked.overflow.count
        switch style {
        case .beside:
            var leading = primaryEarContent(primary.payload)
            var trailing = leading
            if case .backgroundApps(let apps) = primary.payload {
                let shown = min(apps.count, max(1, backgroundIconLimit))
                let hidden = apps.count - shown
                let left = Int((Double(shown) / 2).rounded(.up))
                leading = iconRowWidth(count: left)
                trailing = iconRowWidth(count: shown - left) + (hidden > 0 ? glyphSpacing + overflowChipWidth(hidden) : 0)
            }
            trailing += secondaryWidth(secondaries: secondaries, overflow: overflow)
            let ear = earOuterPadding + max(leading, trailing) + earInnerGap
            return CGSize(width: notch.width + 2 * ear, height: notch.height)
        case .below:
            var content: CGFloat = 0
            if case .backgroundApps(let apps) = primary.payload {
                let shown = min(apps.count, max(1, backgroundIconLimit))
                let hidden = apps.count - shown
                content = iconRowWidth(count: shown) + (hidden > 0 ? glyphSpacing + overflowChipWidth(hidden) : 0)
            }
            content += secondaryWidth(secondaries: secondaries, overflow: overflow)
            let width = max(notch.width + 24, 2 * earOuterPadding + content + (content > 0 ? 60 : 0))
            return CGSize(width: width, height: notch.height + belowBand)
        }
    }

    public static func idleSize(notch: CGSize) -> CGSize {
        CGSize(width: notch.width - 2, height: notch.height - 1)
    }

    // MARK: open states

    public static func expandedSize(for kind: ActivityKind) -> CGSize {
        switch kind {
        case .nowPlaying: CGSize(width: 520, height: 188)
        case .timer: CGSize(width: 440, height: 150)
        case .calendar: CGSize(width: 480, height: 164)
        case .battery: CGSize(width: 420, height: 124)
        case .backgroundApps: CGSize(width: 560, height: 176)
        }
    }

    public static func alertSize(for style: IslandAlert.Style) -> CGSize {
        switch style {
        case .eventStarting: CGSize(width: 460, height: 96)
        default: CGSize(width: 400, height: 88)
        }
    }

    /// Bottom corner radius. Larger shapes get rounder corners so inner
    /// content can stay concentric (inner radius = outer − padding).
    public static func radius(forHeight h: CGFloat) -> CGFloat {
        switch h {
        case ..<40: 12
        case ..<72: 18
        case ..<112: 28
        case ..<220: 34
        default: 38
        }
    }

    /// How much the island leans toward the pointer on hover.
    public static func hoverGrowth(for presentation: IslandPresentation) -> CGSize {
        switch presentation {
        case .idle: CGSize(width: 16, height: 4)
        case .compact: CGSize(width: 12, height: 4)
        case .expanded, .dashboard: CGSize(width: 4, height: 2)
        case .alert: .zero
        }
    }

    /// Body size for a presentation, before hover growth.
    public static func bodySize(for presentation: IslandPresentation, notch: CGSize, style: CompactStyle,
                                ranked: RankedActivities, backgroundIconLimit: Int, dashboardRows: Int = 1) -> CGSize {
        switch presentation {
        case .idle: return idleSize(notch: notch)
        case .compact: return compactSize(notch: notch, style: style, ranked: ranked, backgroundIconLimit: backgroundIconLimit)
        case .expanded(let id):
            guard let a = ranked.all.first(where: { $0.id == id }) else { return DashboardLayout.size(rows: dashboardRows, notchHeight: notch.height) }
            return expandedSize(for: a.kind)
        case .dashboard: return DashboardLayout.size(rows: dashboardRows, notchHeight: notch.height)
        case .alert(let alert): return alertSize(for: alert.style)
        }
    }
}
