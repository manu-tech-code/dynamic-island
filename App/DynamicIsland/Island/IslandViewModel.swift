import AppKit
import IslandCore
import SwiftUI

/// Which page the expanded Now Playing island shows.
enum NowPlayingPage: Equatable { case player, lyrics, upNext }

/// Island state for one display: what it shows, how big it is, and what a
/// click does. The engine decides what's live; this adds what the user opened.
@Observable
final class IslandViewModel {
    enum UserState: Equatable { case none, expanded(String), dashboard, shelf }

    let env: AppEnvironment
    var notch: NotchRect
    private(set) var hover = false
    private(set) var userState: UserState = .none
    private(set) var nowPlayingPage: NowPlayingPage = .player
    /// Pins the presentation, for the preview in Settings.
    var forced: IslandPresentation?
    /// Shows an AppKit menu at the pointer; set by the island's controller.
    @ObservationIgnored var presentMenu: (NSMenu) -> Void = { _ in }

    init(env: AppEnvironment, notch: NotchRect) {
        self.env = env
        self.notch = notch
    }

    var isPreview: Bool { forced != nil }

    var settings: IslandSettings { env.settings.settings }
    var ranked: RankedActivities { env.engine.ranked }

    var presentation: IslandPresentation {
        if let forced { return resolvedForced(forced) }
        let engine = env.engine
        if let alert = engine.alert, userState == .none { return .alert(alert) }
        switch userState {
        case .expanded(let id) where engine.activity(id: id) != nil: return .expanded(activityID: id)
        case .dashboard: return .dashboard
        case .shelf: return .shelf
        default: return ranked.isEmpty ? .idle : .compact
        }
    }

    /// A forced expanded state with no id shows whatever is primary.
    private func resolvedForced(_ p: IslandPresentation) -> IslandPresentation {
        if case .expanded(let id) = p, env.engine.activity(id: id) == nil {
            if let first = ranked.primary ?? env.engine.live.first { return .expanded(activityID: first.id) }
            return .dashboard
        }
        if p == .compact, ranked.isEmpty { return .idle }
        return p
    }

    var isOpen: Bool { presentation.isOpen }

    var expandedActivity: Activity? {
        if case .expanded(let id) = presentation { return env.engine.activity(id: id) }
        return nil
    }

    /// Lyrics and Up Next scroll, so scrolling there mustn't close the island.
    var hasScrollableContent: Bool {
        if presentation == .shelf || expandedActivity?.kind == .shelf { return true }
        return expandedActivity?.kind == .nowPlaying && nowPlayingPage != .player
    }

    /// Identity of the content; a change swaps content with a transition.
    var contentKey: String {
        switch presentation {
        case .idle: "idle"
        case .compact: "compact-\(settings.compactStyle.rawValue)"
        case .expanded(let id): "expanded-\(id)-\(nowPlayingPage)"
        case .dashboard: "dashboard"
        case .shelf: "shelf"
        case .alert(let a): "alert-\(a.id)"
        }
    }

    /// Width while the user drags a resize handle; committed to settings on release.
    var liveWidthScale: Double?
    var widthScale: Double { liveWidthScale ?? settings.openWidthScale }

    var dashboardWidth: CGFloat { DashboardLayout.width(scale: widthScale) }
    var dashboardColumns: Int { DashboardLayout.columns(forWidth: dashboardWidth) }
    var dashboardRows: Int {
        max(1, DashboardLayout.rows(settings.visibleDashboard, columns: dashboardColumns).count)
    }

    /// The dashboard button at the end of the compact island's right ear.
    var showsDashboardButton: Bool {
        guard !isPreview || settings.dashboardButton == .always, presentation == .compact else { return false }
        switch settings.dashboardButton {
        case .always: return true
        case .onHover: return hover
        case .off: return false
        }
    }

    private var layoutContext: IslandMetrics.Context {
        IslandMetrics.Context(notch: notch.rect.size, style: settings.compactStyle, iconLimit: settings.backgroundApps.maxIcons,
                              dashboardButton: showsDashboardButton, widthScale: widthScale, dashboardRows: dashboardRows,
                              compactMaxWidth: settings.compactMaxWidth > 0 ? settings.compactMaxWidth : nil)
    }

    /// What the compact island actually shows at the user's width and limit.
    var compactFit: IslandMetrics.CompactFit {
        let c = layoutContext
        return IslandMetrics.fitCompact(notch: c.notch, style: c.style, ranked: ranked, iconLimit: c.iconLimit,
                                        dashboardButton: c.dashboardButton, maxWidth: c.compactMaxWidth, scale: c.widthScale)
    }

    /// The compact island at the standard width, used to turn a drag into a scale.
    private var naturalCompactWidth: CGFloat {
        let c = layoutContext
        return IslandMetrics.fitCompact(notch: c.notch, style: c.style, ranked: ranked, iconLimit: c.iconLimit,
                                        dashboardButton: c.dashboardButton, maxWidth: c.compactMaxWidth).size.width
    }

    var bodySize: CGSize {
        let p = presentation
        var size: CGSize
        let kind = expandedActivity?.kind
        if kind == .nowPlaying, nowPlayingPage != .player {
            size = IslandMetrics.scaled(IslandMetrics.nowPlayingDetail, widthScale)
        } else if kind == .backgroundApps, case .backgroundApps(let apps)? = expandedActivity?.payload {
            size = IslandMetrics.backgroundAppsExpandedSize(count: apps.count, widthScale: widthScale)
        } else {
            size = IslandMetrics.bodySize(for: p, ranked: ranked, expandedKind: kind, context: layoutContext)
        }
        if hover {
            let g = IslandMetrics.hoverGrowth(for: p)
            size.width += g.width
            size.height += g.height
        }
        return size
    }

    /// What VoiceOver reads for the compact island.
    var accessibilitySummary: String {
        let fit = compactFit
        let now = Date()
        var parts = fit.ranked.visible.map { a -> String in
            switch a.payload {
            case .nowPlaying(let i): "\(i.title)\(i.artist.isEmpty ? "" : " by \(i.artist)"), \(i.isPlaying ? "playing" : "paused")"
            case .timer(let t): "\(t.label), \(IslandFormat.countdown(t.remaining(at: now))) left"
            case .calendar(let e): "\(e.title), \(IslandFormat.untilLong(e.start, from: now))"
            case .battery(let b): "Battery low, \(b.percent) percent"
            case .backgroundApps(let apps): "\(apps.count) background apps"
            case .shelf(let items): "\(items.count) items on the shelf"
            case .download(let d): "Downloading \(d.name)\(d.fraction.map { ", \(Int($0 * 100)) percent" } ?? "")"
            case .privacy(let p): p.microphone && p.camera ? "Microphone and camera in use" : p.microphone ? "Microphone in use" : "Camera in use"
            }
        }
        if !fit.ranked.overflow.isEmpty { parts.append("and \(fit.ranked.overflow.count) more") }
        return "Dynamic Island. " + (parts.isEmpty ? "Nothing live" : parts.joined(separator: ". "))
    }

    /// Room for content in each ear of an open state (beside the notch).
    var earContentWidth: CGFloat {
        max(0, (bodySize.width - notch.rect.width) / 2 - IslandMetrics.earInnerGap - 18 - IslandMetrics.shoulder)
    }

    /// Open states narrower than this use their compact layouts.
    var isNarrow: Bool { bodySize.width < 470 }

    /// How many points of width one unit of scale is worth in the current
    /// state, for turning a drag into a scale. nil where resizing doesn't apply.
    var resizeBase: CGFloat? {
        switch presentation {
        case .compact:
            // The ears scale around the notch (beside) or the band scales (below).
            let natural = naturalCompactWidth
            return settings.compactStyle == .beside ? max(40, natural - notch.rect.width) : natural
        case .idle, .alert: return nil
        default: return baseOpenWidth
        }
    }

    /// The standard (scale 1) width of the current open state.
    var baseOpenWidth: CGFloat? {
        switch presentation {
        case .dashboard: return DashboardLayout.width
        case .shelf: return IslandMetrics.shelf.width
        case .expanded:
            guard let kind = expandedActivity?.kind else { return nil }
            return kind == .nowPlaying && nowPlayingPage != .player ? IslandMetrics.nowPlayingDetail.width : IslandMetrics.expandedSize(for: kind).width
        default: return nil
        }
    }

    /// Drag on a side handle: the island is centred, so each point of drag
    /// changes the width by two.
    func resize(by dx: CGFloat, from start: Double) {
        guard let base = resizeBase else { return }
        let r = IslandSettings.widthScaleRange
        let scale = min(max(start + Double(2 * dx / base), r.lowerBound), r.upperBound)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { liveWidthScale = scale }
    }

    func endResize() {
        guard let scale = liveWidthScale else { return }
        env.settings.settings.openWidthScale = (scale * 100).rounded() / 100
        liveWidthScale = nil
    }

    var outerSize: CGSize {
        let b = bodySize
        return CGSize(width: b.width + 2 * IslandMetrics.shoulder, height: b.height)
    }

    var radius: CGFloat {
        IslandMetrics.radius(forHeight: bodySize.height)
    }

    var material: IslandMaterial { settings.material }

    /// Colour behind the island while music plays, taken from the artwork.
    var glowColor: Color? {
        guard settings.glowFromArtwork, let color = env.nowPlaying.artworkColor,
              env.nowPlaying.info?.isPlaying == true else { return nil }
        switch presentation {
        case .compact where ranked.primary?.kind == .nowPlaying: return Color(nsColor: color)
        case .expanded(let id) where env.engine.activity(id: id)?.kind == .nowPlaying: return Color(nsColor: color)
        default: return nil
        }
    }

    // MARK: motion

    var reduceMotion: Bool { env.look.reduceMotion }

    private func animate(open: Bool, _ body: () -> Void) {
        let animation: Animation = reduceMotion ? .easeInOut(duration: 0.2)
            : open ? .spring(duration: 0.5, bounce: 0.22) : .spring(duration: 0.42, bounce: 0.06)
        withAnimation(animation, body)
    }

    func showPage(_ page: NowPlayingPage) {
        animate(open: page != .player) { nowPlayingPage = nowPlayingPage == page ? .player : page }
    }

    func setHover(_ inside: Bool) {
        guard hover != inside else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) { hover = inside }
    }

    // MARK: actions

    /// A click on the island's background.
    func tap() {
        guard !isPreview else { return }
        switch presentation {
        case .idle: openDashboard()
        case .compact:
            if let primary = ranked.primary { open(primary.id) } else { openDashboard() }
        case .expanded, .dashboard, .shelf: collapse()
        case .alert: env.engine.dismissAlert()
        }
    }

    func open(_ activityID: String) {
        env.look.refresh()
        animate(open: true) { userState = .expanded(activityID); nowPlayingPage = .player }
    }

    func openDashboard() {
        env.look.refresh()
        animate(open: true) { userState = .dashboard }
    }

    /// A drag carrying something is near the notch, or a drop is hovering.
    private(set) var dropTargeted = false
    /// The shelf was opened by a drag, so it closes again if nothing is dropped.
    private(set) var shelfOpenedByDrag = false

    func openShelf(byDrag: Bool = false) {
        guard userState != .shelf else { return }
        env.look.refresh()
        shelfOpenedByDrag = byDrag
        animate(open: true) { userState = .shelf }
    }

    func setDropTargeted(_ on: Bool) {
        guard dropTargeted != on else { return }
        withAnimation(.snappy(duration: 0.2)) { dropTargeted = on }
    }

    /// Something was dropped on the island: keep the shelf open for it.
    func didDrop() {
        shelfOpenedByDrag = false
        dropTargeted = false
        if userState != .shelf { openShelf() }
    }

    func toggleDashboard() {
        if userState == .dashboard { collapse() } else { openDashboard() }
    }

    func collapse() {
        guard userState != .none else { return }
        shelfOpenedByDrag = false
        dropTargeted = false
        animate(open: false) { userState = .none; nowPlayingPage = .player }
    }

    /// Drops an expanded state whose activity has ended.
    func pruneIfStale() {
        if case .expanded(let id) = userState, env.engine.activity(id: id) == nil {
            animate(open: false) { userState = .none }
        }
    }
}
