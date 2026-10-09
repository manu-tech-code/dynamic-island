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
    /// The messages that reached the island lately (from the dashboard's top bar).
    case recentMessages
    case alert(IslandAlert)

    public var isOpen: Bool {
        switch self {
        case .expanded, .dashboard, .shelf, .recentMessages: true
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

    /// Width of the primary activity's own content in the leading and the
    /// trailing ear. Background apps have none: their icons are balanced
    /// across both ears.
    public static func primaryEarWidths(_ payload: ActivityPayload) -> (leading: CGFloat, trailing: CGFloat) {
        switch payload {
        case .nowPlaying: (glyph, glyph)                               // artwork | waveform
        case .timer(let t): (glyph, t.duration >= 3600 ? 56 : 40)      // ring | countdown
        case .calendar: (glyph, 34)                                    // icon | "in 5m"
        case .battery: (24, 30)                                        // icon | "15%"
        case .backgroundApps: (0, 0)
        case .shelf: (glyph, glyph)                                    // tray | count
        case .download: (glyph, 38)                                    // ring | "100%"
        case .privacy(let p): (p.microphone && p.camera ? 36 : glyph, 18)
        case .messages(let apps): (iconRowWidth(count: min(2, apps.count)), 26)  // app icons | unread count
        case .agents(let sessions):                                    // badges, spinner | "4:12"
            (iconRowWidth(count: min(2, Set(sessions.map(\.agent)).count)) + glyphSpacing + agentSpinner, 44)
        }
    }

    /// The working agents' spinner, beside their badges.
    public static let agentSpinner: CGFloat = 14

    public static func iconRowWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * glyph + CGFloat(count - 1) * glyphSpacing
    }

    /// Width of the secondary activities' glyphs in the band below the notch.
    public static func secondaryWidth(count: Int) -> CGFloat {
        count > 0 ? 8 + iconRowWidth(count: count) : 0
    }

    /// The dashboard button at the outer end of the trailing ear.
    public static let dashboardButtonSize: CGFloat = 22

    /// What each ear of the compact island holds beside the notch. The island
    /// stays centred on the notch, so both ears are as wide as the fuller one;
    /// the items that can go on either side (more app icons, other activities)
    /// go to whichever side is shorter, so as little room as possible is empty.
    public struct CompactEars: Equatable, Sendable {
        /// Background app icons in each ear, in order (primary background apps only).
        public var leadingApps = 0
        public var trailingApps = 0
        /// Ids of the secondary activities in each ear.
        public var leadingSecondaries: [String] = []
        public var trailingSecondaries: [String] = []
        /// Content width of each ear, before padding.
        public var leading: CGFloat = 0
        public var trailing: CGFloat = 0
        public var content: CGFloat { max(leading, trailing) }
        public init() {}
    }

    public static func compactEars(primary: Activity, secondaries: some Collection<Activity>, iconLimit: Int, dashboardButton: Bool) -> CompactEars {
        var e = CompactEars()
        func add(_ width: CGFloat, leading: Bool) {
            if leading { e.leading += (e.leading > 0 ? glyphSpacing : 0) + width }
            else { e.trailing += (e.trailing > 0 ? glyphSpacing : 0) + width }
        }
        let own = primaryEarWidths(primary.payload)
        if own.leading > 0 { add(own.leading, leading: true) }
        if own.trailing > 0 { add(own.trailing, leading: false) }
        if dashboardButton { add(dashboardButtonSize, leading: false) }
        if case .backgroundApps(let apps) = primary.payload {
            for _ in 0..<min(apps.count, max(1, iconLimit)) {
                let left = e.leading <= e.trailing
                add(glyph, leading: left)
                if left { e.leadingApps += 1 } else { e.trailingApps += 1 }
            }
        }
        for a in secondaries {
            let left = e.leading <= e.trailing
            add(glyph, leading: left)
            if left { e.leadingSecondaries.append(a.id) } else { e.trailingSecondaries.append(a.id) }
        }
        return e
    }

    /// The compact island fits what's on it: nothing is reserved for items that
    /// aren't shown, and activities past the limit simply aren't on it (they
    /// stay in the dashboard).
    public static func compactSize(notch: CGSize, style: CompactStyle, ranked: RankedActivities, backgroundIconLimit: Int,
                                   dashboardButton showButton: Bool = false) -> CGSize {
        guard let primary = ranked.primary else { return idleSize(notch: notch) }
        switch style {
        case .beside:
            let ears = compactEars(primary: primary, secondaries: ranked.secondaries, iconLimit: backgroundIconLimit,
                                   dashboardButton: showButton)
            let ear = earOuterPadding + ears.content + earInnerGap
            return CGSize(width: notch.width + 2 * ear, height: notch.height)
        case .below:
            var content: CGFloat = 0
            if case .backgroundApps(let apps) = primary.payload {
                content = iconRowWidth(count: min(apps.count, max(1, backgroundIconLimit)))
            }
            content += secondaryWidth(count: ranked.secondaries.count)
            let button = showButton ? dashboardButtonSize + 8 : 0
            let width = max(notch.width + 24, 2 * earOuterPadding + content + (content > 0 ? 60 : 0)) + button
            return CGSize(width: width, height: notch.height + belowBand)
        }
    }

    /// The compact island after applying the user's width limit: background
    /// app icons, then extra activities, leave it until it fits.
    public struct CompactFit: Equatable, Sendable {
        public var ranked: RankedActivities
        public var iconLimit: Int
        public var size: CGSize
        /// What each ear shows (beside the notch).
        public var ears: CompactEars
    }

    public static func fitCompact(notch: CGSize, style: CompactStyle, ranked: RankedActivities, iconLimit: Int,
                                  dashboardButton: Bool, maxWidth: CGFloat?) -> CompactFit {
        var r = ranked
        var limit = max(1, iconLimit)
        func measure() -> CGSize {
            compactSize(notch: notch, style: style, ranked: r, backgroundIconLimit: limit, dashboardButton: dashboardButton)
        }
        func result(_ size: CGSize) -> CompactFit {
            let ears = r.primary.map { compactEars(primary: $0, secondaries: r.secondaries, iconLimit: limit, dashboardButton: dashboardButton) }
            return CompactFit(ranked: r, iconLimit: limit, size: size, ears: ears ?? CompactEars())
        }
        var size = measure()
        guard let maxWidth, maxWidth > 0 else { return result(size) }
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
        return result(size)
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
        case .messages: CGSize(width: 440, height: 150)
        case .agents: CGSize(width: 460, height: 176)
        }
    }

    /// The shelf, opened by a drag or a click; also the drop target.
    public static let shelf = CGSize(width: 600, height: 216)
    /// Recent messages: the ears, then four rows (more scroll).
    public static let recentMessages = CGSize(width: 560, height: 250)

    // MARK: the window

    /// The compact island never gets wider than this, even with no limit set:
    /// past it, background app icons and then extra activities leave it, as
    /// with the limit in Settings.
    public static let compactWidest = IslandSettings.compactMaxWidthRange.upperBound
    /// Room around the island for the artwork's glow.
    public static let glowMargin: CGFloat = 44

    /// The island's window: as wide and as tall as the island can get (the
    /// dashboard at the widest width with every row, the compact island at its
    /// widest), plus the glow. It's clear and lets clicks through outside the
    /// island, so the room costs nothing, and nothing is ever cut off.
    public static func panelSize(notchHeight: CGFloat) -> CGSize {
        let wide = IslandSettings.widthScaleRange.upperBound
        let open = [DashboardLayout.width(scale: wide), scaled(nowPlayingDetail, wide).width, scaled(shelf, wide).width,
                    scaled(recentMessages, wide).width] + ActivityKind.allCases.map { expandedSize(for: $0, widthScale: wide).width }
        let width = max(open.max() ?? 0, compactWidest) + 2 * shoulder
        let height = max(DashboardLayout.size(rows: DashboardLayout.maxRows, notchHeight: notchHeight).height,
                         nowPlayingDetail.height, recentMessages.height,
                         backgroundAppsExpandedSize(count: 99, widthScale: IslandSettings.widthScaleRange.lowerBound).height)
        return CGSize(width: (width + 2 * glowMargin).rounded(.up), height: (height + glowMargin).rounded(.up))
    }

    /// Content width of a compact alert's fuller ear: the icon on the left; a
    /// ring (devices) or the percentage and a ring (power) on the right.
    public static func compactAlertContent(for style: IslandAlert.Style) -> CGFloat {
        switch style {
        case .chargerConnected, .chargerDisconnected, .lowBattery: 40 + glyphSpacing + 18 // "100%" and the ring
        case .messages(_, .ticker): tickerEar                                             // the sender | the message
        default: glyph
        }
    }

    /// Where the pointer brings a hidden island out (see `IslandVisibility.onHover`):
    /// the camera housing, a little wider on each side and a sliver below it, so
    /// it's easy to hit without covering the menu bar. In screen coordinates
    /// (origin bottom-left), like the notch rect.
    public static let revealMargin: CGFloat = 28
    public static func revealArea(notch: CGRect) -> CGRect {
        CGRect(x: notch.minX - revealMargin, y: notch.minY - 6,
               width: notch.width + 2 * revealMargin, height: notch.height + 6)
    }

    // MARK: while music plays (hover to show)

    /// Settings › While music plays: the gap between the notch and a bubble.
    public static let playingBubbleGap: CGFloat = 8
    /// Each slim ear: the artwork or the waveform, with 8 pt on either side.
    public static let playingSlimEar: CGFloat = 36
    /// The drop hangs this far below the notch, and is this wide.
    public static let playingDropGap: CGFloat = 6
    public static let playingDropDiameter: CGFloat = 26
    /// How much of the record shows past the notch.
    public static let playingRecordPeek: CGFloat = 24
    /// Bubbles are as tall as the notch, less a point at the top and bottom.
    public static func playingBubbleDiameter(notch: CGSize) -> CGFloat { max(20, notch.height - 2) }

    /// Where the pointer also brings a tucked island out while music plays: on
    /// what stays out of it. nil when nothing does, or it's within `revealArea`
    /// anyway. Screen coordinates (origin bottom-left), like the notch rect.
    public static func playingHoverArea(style: PlayingStyle, notch: CGRect) -> CGRect? {
        let d = playingBubbleDiameter(notch: notch.size), m: CGFloat = 4
        let right = CGRect(x: notch.maxX + playingBubbleGap, y: notch.maxY - 1 - d, width: d, height: d)
        let left = CGRect(x: notch.minX - playingBubbleGap - d, y: right.minY, width: d, height: d)
        switch style {
        case .tucked, .underglow:
            return nil
        case .slim:
            return CGRect(x: notch.minX - playingSlimEar, y: notch.minY, width: notch.width + 2 * playingSlimEar, height: notch.height)
                .insetBy(dx: -m, dy: -m)
        case .bubble:
            return right.insetBy(dx: -m, dy: -m)
        case .twoBubbles:
            return left.union(right).insetBy(dx: -m, dy: -m)
        case .drip:
            let below = playingDropGap + playingDropDiameter
            return CGRect(x: notch.midX - playingDropDiameter / 2, y: notch.minY - below, width: playingDropDiameter, height: notch.height + below)
                .insetBy(dx: -m, dy: -m)
        case .record:
            return CGRect(x: notch.maxX, y: notch.minY, width: playingRecordPeek, height: notch.height).insetBy(dx: -m, dy: -m)
        }
    }

    /// The lock that opens when the Mac unlocks: a lock in the left ear.
    public static func lockSize(notch: CGSize) -> CGSize {
        CGSize(width: notch.width + 2 * (earOuterPadding + glyph + earInnerGap), height: notch.height)
    }

    public static func alertSize(for style: IslandAlert.Style, notch: CGSize = CGSize(width: 185, height: 32),
                                 compactStyle: CompactStyle = .beside) -> CGSize {
        if IslandAlert(kind: .battery, style: style).isCompact {
            // Status alerts are compact: ears beside the notch, or a band below it.
            switch compactStyle {
            case .beside:
                let ear = earOuterPadding + compactAlertContent(for: style) + earInnerGap
                return CGSize(width: notch.width + 2 * ear, height: notch.height)
            case .below:
                return CGSize(width: max(notch.width + 24, 280), height: notch.height + belowBand)
            }
        }
        switch style {
        case .volume, .brightness:
            // The HUD lives where compact content does.
            let width = compactStyle == .beside ? notch.width + 2 * 116 : max(notch.width + 24, 280)
            return CGSize(width: width, height: compactStyle == .beside ? notch.height : notch.height + belowBand)
        case .eventStarting: return CGSize(width: 460, height: 100)
        case .downloadFinished: return CGSize(width: 460, height: 88)
        case .message: return CGSize(width: 440, height: 88)
        case .messages(let list, .stack): return CGSize(width: 380, height: 84 + 6 * CGFloat(min(2, max(0, list.count - 1))))
        case .messages: return messageCard
        default: return CGSize(width: 400, height: 88)
        }
    }

    // MARK: messages

    /// A message as a card: the app in the ears, the sender and two lines, Open.
    public static let messageCard = CGSize(width: 380, height: 118)
    /// The ticker's ears: the sender on the left, the message scrolling on the right.
    public static let tickerEar: CGFloat = 112
    /// A stack, fanned out on hover: the ears, then a row per message.
    public static func messageListHeight(count: Int) -> CGFloat { 32 + CGFloat(count) * 30 + 8 }

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
    public static func belowPeekWidth(band: CGFloat, titleWidth: CGFloat, secondaries: Int,
                                      dashboardButton: Bool, maxWidth: CGFloat?, maxExtra: CGFloat = 160) -> CGFloat {
        // Padding, artwork, the spacer and the waveform, with the band's 8 pt spacing.
        let chrome: CGFloat = 2 * 14 + 18 + 8 + 8 + 4 + 8 + 18
        let glyphs = secondaryWidth(count: secondaries)
        let used = chrome + (glyphs > 0 ? 8 + glyphs : 0) + (dashboardButton ? 8 + dashboardButtonSize : 0)
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
            // Fits its content; the width setting is for open states.
            return fitCompact(notch: c.notch, style: c.style, ranked: ranked, iconLimit: c.iconLimit,
                              dashboardButton: c.dashboardButton, maxWidth: c.compactMaxWidth).size
        case .expanded:
            guard let kind = expandedKind else { return dashboardSize(c) }
            return expandedSize(for: kind, widthScale: c.widthScale)
        case .dashboard: return dashboardSize(c)
        case .shelf: return scaled(shelf, c.widthScale)
        case .recentMessages: return scaled(recentMessages, c.widthScale)
        case .alert(let alert): return alertSize(for: alert.style, notch: c.notch, compactStyle: c.style)
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
        case .recentMessages: return recentMessages
        case .alert(let alert): return alertSize(for: alert.style, notch: notch, compactStyle: style)
        }
    }
}
