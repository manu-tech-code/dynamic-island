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
    case shelf
    case alert(IslandAlert)

    public var isOpen: Bool {
        switch self {
        case .expanded, .dashboard, .shelf: true
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
        case .shelf: return 34
        case .download: return 38
        case .privacy: return 22
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

    /// Room for the dashboard button at the outer end of the trailing ear.
    public static let dashboardButton: CGFloat = 22 + glyphSpacing

    public static func compactSize(notch: CGSize, style: CompactStyle, ranked: RankedActivities, backgroundIconLimit: Int,
                                   dashboardButton showButton: Bool = false) -> CGSize {
        guard let primary = ranked.primary else { return idleSize(notch: notch) }
        let button = showButton ? dashboardButton : 0
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
            trailing += secondaryWidth(secondaries: secondaries, overflow: overflow) + button
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
            let width = max(notch.width + 24, 2 * earOuterPadding + content + (content > 0 ? 60 : 0)) + button
            return CGSize(width: width, height: notch.height + belowBand)
        }
    }

    /// The compact island after applying the user's width limit: background
    /// app icons, then extra activities, fold into "+N" until it fits.
    public struct CompactFit: Equatable, Sendable {
        public var ranked: RankedActivities
        public var iconLimit: Int
        public var size: CGSize
    }

    public static func fitCompact(notch: CGSize, style: CompactStyle, ranked: RankedActivities, iconLimit: Int,
                                  dashboardButton: Bool, maxWidth: CGFloat?) -> CompactFit {
        var r = ranked
        var limit = max(1, iconLimit)
        func measure() -> CGSize {
            compactSize(notch: notch, style: style, ranked: r, backgroundIconLimit: limit, dashboardButton: dashboardButton)
        }
        var size = measure()
        guard let maxWidth, maxWidth > 0 else { return CompactFit(ranked: r, iconLimit: limit, size: size) }
        while size.width > maxWidth {
            if case .backgroundApps(let apps)? = r.primary?.payload, limit > 1, min(apps.count, limit) > 1 {
                limit = min(apps.count, limit) - 1
            } else if r.visible.count > 1 {
                r.overflow.insert(r.visible.removeLast(), at: 0)
            } else {
                break // one activity is the minimum; it keeps its natural size
            }
            size = measure()
        }
        return CompactFit(ranked: r, iconLimit: limit, size: size)
    }

    /// The compact island at the user's width. The ears scale around the
    /// notch; narrower folds icons and extra activities into "+N" (content is
    /// never clipped), wider just gives the ears more room.
    public static func fitCompact(notch: CGSize, style: CompactStyle, ranked: RankedActivities, iconLimit: Int,
                                  dashboardButton: Bool, maxWidth: CGFloat?, scale: Double) -> CompactFit {
        let natural = fitCompact(notch: notch, style: style, ranked: ranked, iconLimit: iconLimit,
                                 dashboardButton: dashboardButton, maxWidth: maxWidth)
        guard scale != 1, ranked.primary != nil else { return natural }
        let target = scaledCompactWidth(natural: natural.size.width, notch: notch, style: style, scale: scale)
        let cap = maxWidth.map { min($0, target) } ?? target
        if scale < 1 {
            var fit = fitCompact(notch: notch, style: style, ranked: ranked, iconLimit: iconLimit,
                                 dashboardButton: dashboardButton, maxWidth: cap)
            fit.size.width = max(fit.size.width, cap)
            return fit
        }
        var fit = natural
        fit.size.width = max(natural.size.width, cap)
        return fit
    }

    /// Scales the ears (beside) or the band (below); the notch itself never changes.
    public static func scaledCompactWidth(natural: CGFloat, notch: CGSize, style: CompactStyle, scale: Double) -> CGFloat {
        switch style {
        case .beside:
            let minEar = earOuterPadding + glyph + earInnerGap
            let ear = max(0, (natural - notch.width) / 2)
            return notch.width + 2 * max(minEar, (ear * CGFloat(scale)).rounded())
        case .below:
            return max(notch.width + 24, (natural * CGFloat(scale)).rounded())
        }
    }

    /// Background apps, expanded: as many columns as fit the width, as many
    /// rows as the apps need (up to three).
    public static func backgroundAppsGrid(count: Int, width: CGFloat) -> (columns: Int, rows: Int) {
        let columns = max(3, Int((width - 32 + 6) / (70 + 6)))
        let rows = min(3, max(1, Int((Double(min(count, columns * 3)) / Double(columns)).rounded(.up))))
        return (columns, rows)
    }

    public static func backgroundAppsExpandedSize(count: Int, widthScale: Double) -> CGSize {
        let width = expandedSize(for: .backgroundApps, widthScale: widthScale).width
        let rows = CGFloat(backgroundAppsGrid(count: count, width: width).rows)
        return CGSize(width: width, height: 32 + 10 + rows * 72 + (rows - 1) * 8 + 16)
    }

    public static func idleSize(notch: CGSize) -> CGSize {
        CGSize(width: notch.width - 2, height: notch.height - 1)
    }

    // MARK: open states

    /// Expanded size at the user's width (height stays; width never below 360).
    public static func expandedSize(for kind: ActivityKind, widthScale: Double) -> CGSize {
        let base = expandedSize(for: kind)
        return CGSize(width: max(360, (base.width * CGFloat(widthScale)).rounded()), height: base.height)
    }

    public static func scaled(_ size: CGSize, _ widthScale: Double) -> CGSize {
        CGSize(width: max(360, (size.width * CGFloat(widthScale)).rounded()), height: size.height)
    }

    public static func expandedSize(for kind: ActivityKind) -> CGSize {
        switch kind {
        case .nowPlaying: CGSize(width: 520, height: 188)
        case .timer: CGSize(width: 440, height: 150)
        case .calendar: CGSize(width: 480, height: 164)
        case .battery: CGSize(width: 420, height: 124)
        case .backgroundApps: CGSize(width: 560, height: 176)
        case .shelf: CGSize(width: 600, height: 216)
        case .downloads: CGSize(width: 460, height: 132)
        case .privacy: CGSize(width: 400, height: 112)
        case .devices: CGSize(width: 460, height: 150)
        case .hud: CGSize(width: 420, height: 100)
        }
    }

    /// The shelf, opened by a drag or a click; also the drop target.
    public static let shelf = CGSize(width: 600, height: 216)

    public static func alertSize(for style: IslandAlert.Style, notch: CGSize = CGSize(width: 185, height: 32),
                                 compactStyle: CompactStyle = .beside, scale: Double = 1) -> CGSize {
        switch style {
        case .volume, .brightness:
            // The HUD lives where compact content does, at the compact width.
            let natural = compactStyle == .beside ? notch.width + 2 * 116 : max(notch.width + 24, 280)
            let width = scaledCompactWidth(natural: natural, notch: notch, style: compactStyle, scale: scale)
            return CGSize(width: width, height: compactStyle == .beside ? notch.height : notch.height + belowBand)
        case .eventStarting, .deviceConnected: return CGSize(width: 460, height: 100)
        case .downloadFinished: return CGSize(width: 460, height: 88)
        case .message: return CGSize(width: 440, height: 88)
        default: return CGSize(width: 400, height: 88)
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

    /// Extra height under the compact island while the pointer rests on a track:
    /// title and artist lines under the ears (beside), or the artist under the
    /// band's title (below). Beside, the shape stays under 72 pt, so it keeps
    /// the small-corner radius; the island keeps its compact radius while peeking.
    public static func nowPlayingPeekHeight(style: CompactStyle, hasArtist: Bool) -> CGFloat {
        switch style {
        case .beside: hasArtist ? 38 : 24
        case .below: hasArtist ? 18 : 0
        }
    }

    /// Below the notch, the band's title gets whatever its icons leave. While the
    /// title peeks, the band widens until the title fits: by at most `maxExtra`
    /// (past that it scrolls), never past `maxWidth`, and never narrower.
    public static func belowPeekWidth(band: CGFloat, titleWidth: CGFloat, secondaries: Int, overflow: Int,
                                      dashboardButton: Bool, maxWidth: CGFloat?, maxExtra: CGFloat = 160) -> CGFloat {
        // Padding, artwork, the spacer and the waveform, with the band's 8 pt spacing.
        let chrome: CGFloat = 2 * 14 + 18 + 8 + 8 + 4 + 8 + 18
        let glyphs = secondaryWidth(secondaries: secondaries, overflow: overflow)
        let used = chrome + (glyphs > 0 ? 8 + glyphs : 0) + (dashboardButton ? 8 + 22 : 0)
        var width = min(max(band, used + titleWidth.rounded(.up) + 2), band + maxExtra)
        if let maxWidth, maxWidth > 0 { width = min(width, max(band, maxWidth)) }
        return width
    }

    /// Everything besides the presentation that decides the island's size.
    public struct Context: Equatable, Sendable {
        public var notch: CGSize
        public var style: CompactStyle
        public var iconLimit: Int
        public var dashboardButton: Bool
        public var widthScale: Double
        public var dashboardRows: Int
        public var compactMaxWidth: CGFloat?

        public init(notch: CGSize, style: CompactStyle = .beside, iconLimit: Int = 4, dashboardButton: Bool = false,
                    widthScale: Double = 1, dashboardRows: Int = 1, compactMaxWidth: CGFloat? = nil) {
            self.notch = notch; self.style = style; self.iconLimit = iconLimit; self.dashboardButton = dashboardButton
            self.widthScale = widthScale; self.dashboardRows = dashboardRows; self.compactMaxWidth = compactMaxWidth
        }
    }

    /// Body size for a presentation, before hover growth. `expandedKind` is the
    /// kind of the expanded activity (it may not be on the compact island).
    public static func bodySize(for presentation: IslandPresentation, ranked: RankedActivities, expandedKind: ActivityKind?,
                                context c: Context) -> CGSize {
        switch presentation {
        case .idle: return idleSize(notch: c.notch)
        case .compact:
            return fitCompact(notch: c.notch, style: c.style, ranked: ranked, iconLimit: c.iconLimit,
                              dashboardButton: c.dashboardButton, maxWidth: c.compactMaxWidth, scale: c.widthScale).size
        case .expanded:
            guard let kind = expandedKind else { return dashboardSize(c) }
            return expandedSize(for: kind, widthScale: c.widthScale)
        case .dashboard: return dashboardSize(c)
        case .shelf: return scaled(shelf, c.widthScale)
        case .alert(let alert): return alertSize(for: alert.style, notch: c.notch, compactStyle: c.style, scale: c.widthScale)
        }
    }

    static func dashboardSize(_ c: Context) -> CGSize {
        DashboardLayout.size(rows: c.dashboardRows, notchHeight: c.notch.height, width: DashboardLayout.width(scale: c.widthScale))
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
        case .shelf: return shelf
        case .alert(let alert): return alertSize(for: alert.style, notch: notch, compactStyle: style)
        }
    }
}
