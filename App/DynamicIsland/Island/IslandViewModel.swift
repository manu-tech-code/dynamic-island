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
    /// The pointer is on the track's artwork (or on the title row it opened), so the title shows.
    private(set) var peek = false
    @ObservationIgnored private var peekTask: Task<Void, Never>?
    @ObservationIgnored private var overMedia = false
    /// Bumped when the pointer arrives on the closed island; the island bounces once.
    private(set) var bounce = 0
    /// Where the artwork ("artwork") and the open title row ("title") are, in the
    /// island's coordinate space, reported by the views for the controller's pointer tests.
    @ObservationIgnored var mediaRects: [String: CGRect] = [:]
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

    #if DEBUG
    /// Offline renders: a presentation that still behaves live (not a preview).
    var debugPresentation: IslandPresentation?
    #endif

    var settings: IslandSettings { env.settings.settings }
    var ranked: RankedActivities { env.engine.ranked }

    var presentation: IslandPresentation {
        if let forced { return resolvedForced(forced) }
        #if DEBUG
        if let debugPresentation { return debugPresentation }
        #endif
        let engine = env.engine
        if let alert = engine.alert, userState == .none { return .alert(alert) }
        switch userState {
        case .expanded(let id) where engine.activity(id: id) != nil: return .expanded(activityID: id)
        case .dashboard: return .dashboard
        case .shelf: return .shelf
        default: return ranked.isEmpty ? .idle : .compact
        }
    }

    /// Show the island › When the pointer is at the camera: the compact island
    /// stays tucked under the notch until the pointer reaches the camera.
    /// Alerts, HUDs and open states still show as usual.
    var hidesUntilHover: Bool { settings.visibility == .onHover && !isPreview }
    /// The pointer brought the island out (only matters while it hides until hover).
    private(set) var revealed = false
    /// Tucked under the notch: the compact island keeps its content laid out as
    /// usual, but its sides close in to the notch and each ear's content slides
    /// in with its edge, under the camera. Coming out runs the same motion back.
    var isTucked: Bool {
        if let previewTuck { return previewTuck && presentation == .compact }
        return hidesUntilHover && !revealed && !announcing && presentation == .compact
    }

    /// The Settings preview of the reveal: tucked or out, played by the preview itself.
    private(set) var previewTuck: Bool?

    func setPreviewTuck(_ tucked: Bool) {
        guard previewTuck != tucked else { return }
        let animation = reduceMotion ? IslandMotion.reduced : IslandMotion.revealShape(settings.revealStyle, opening: !tucked)
        withAnimation(animation) { previewTuck = tucked }
    }

    /// The island comes out from under the notch, or tucks back in.
    func setRevealed(_ on: Bool) {
        guard revealed != on else { return }
        let animation = reduceMotion ? IslandMotion.reduced : IslandMotion.revealShape(settings.revealStyle, opening: on)
        withAnimation(animation) { revealed = on }
    }

    // MARK: while music plays

    /// Where what stays out of a tucked island is: out beside the notch, back
    /// inside it while the island is out over that spot, or put away.
    enum IndicatorPhase: Equatable { case hidden, shown, absorbed }

    /// Settings › While music plays, when the island hides until hover.
    var playingIndicatorStyle: PlayingStyle? {
        guard hidesUntilHover || previewTuck != nil, settings.whilePlaying != .tucked else { return nil }
        return settings.whilePlaying
    }

    var indicatorPhase: IndicatorPhase {
        guard isPlayingMusic else { return .hidden }
        return isTucked ? .shown : .absorbed
    }

    /// A song is playing on the compact island (a paused one stays tucked away).
    var isPlayingMusic: Bool {
        ranked.visible.contains { if case .nowPlaying(let info) = $0.payload { info.isPlaying } else { false } }
    }

    /// A new song is showing its title for a moment (Settings › Now Playing).
    private(set) var announcing = false
    @ObservationIgnored private var announceTask: Task<Void, Never>?

    /// The song changed: its title shows under the island for a moment, the
    /// island coming out from under the notch if it was tucked.
    func announceTrack() {
        guard settings.nowPlaying.titleOnTrackChange, !isPreview,
              presentation == .compact else { return }
        if !announcing {
            let animation = reduceMotion ? IslandMotion.reduced
                : isTucked ? IslandMotion.revealShape(settings.revealStyle, opening: true) : IslandMotion.peekOpen
            withAnimation(animation) { announcing = true }
        }
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard let self, !Task.isCancelled else { return }
            self.endAnnouncement()
        }
    }

    private func endAnnouncement() {
        guard announcing else { return }
        let tucks = hidesUntilHover && !revealed
        let animation = reduceMotion ? IslandMotion.reduced
            : tucks ? IslandMotion.revealShape(settings.revealStyle, opening: false) : IslandMotion.peekClose
        withAnimation(animation) { announcing = false }
    }

    /// The reveal style in effect (Reduce Motion keeps everything to one fade).
    var revealStyle: RevealStyle? {
        guard !reduceMotion, hidesUntilHover || previewTuck != nil else { return nil }
        return settings.revealStyle
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
        presentation == .compact && settings.dashboardButton == .always
    }

    private var layoutContext: IslandMetrics.Context {
        IslandMetrics.Context(notch: notch.rect.size, style: settings.compactStyle, iconLimit: settings.backgroundApps.maxIcons,
                              dashboardButton: showsDashboardButton, widthScale: widthScale, dashboardRows: dashboardRows,
                              compactMaxWidth: settings.compactMaxWidth > 0 ? settings.compactMaxWidth : nil)
    }

    /// What the compact island shows, and where: it fits its content, within the user's width limit.
    var compactFit: IslandMetrics.CompactFit {
        let c = layoutContext
        return IslandMetrics.fitCompact(notch: c.notch, style: c.style, ranked: ranked, iconLimit: c.iconLimit,
                                        dashboardButton: c.dashboardButton, maxWidth: c.compactMaxWidth)
    }

    /// The track playing on the compact island, while it shows its title under the ears.
    var peekingTrack: NowPlayingInfo? {
        guard peek && settings.nowPlaying.titleOnHover || announcing, !isPreview, !isTucked, presentation == .compact,
              case .nowPlaying(let info)? = compactFit.ranked.primary?.payload, !info.title.isEmpty else { return nil }
        return info
    }

    /// The device whose name and batteries show under its compact alert, while
    /// the pointer is on the device's icon.
    var peekingDevice: BluetoothDeviceInfo? {
        guard peek, !isPreview, case .alert(let a) = presentation, case .deviceConnected(let d) = a.style, d.hasBattery else { return nil }
        return d
    }

    /// Where a peek can open: the track's artwork on the compact island, or a device alert's icon.
    var allowsPeek: Bool {
        if presentation == .compact { return !isTucked }
        if case .alert(let a) = presentation, case .deviceConnected = a.style { return true }
        return false
    }

    private var peekHeight: CGFloat {
        if let info = peekingTrack {
            return IslandMetrics.nowPlayingPeekHeight(style: settings.compactStyle, hasArtist: !info.artist.isEmpty)
        }
        // A device: its name and a line of batteries, like a title and an artist.
        return peekingDevice == nil ? 0 : IslandMetrics.nowPlayingPeekHeight(style: settings.compactStyle, hasArtist: true)
    }

    /// Height of the Hybrid material's black collar: the notch, plus the title
    /// row while peeking beside the notch (it belongs to the ears).
    var collarHeight: CGFloat {
        notch.rect.height + (settings.compactStyle == .beside ? peekHeight : 0)
    }

    /// The island's size: what it lays out at, except while tucked under the notch.
    var bodySize: CGSize {
        isTucked ? IslandMetrics.idleSize(notch: notch.rect.size) : layoutSize
    }

    /// The size content is laid out at. While tucked, the compact content keeps
    /// this layout and slides under the notch instead of being laid out again.
    var layoutSize: CGSize {
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
        // Hovering doesn't resize the island (it bounces); only the track's title adds room.
        if let track = peekingTrack {
            if settings.compactStyle == .below {
                let fit = compactFit.ranked
                let title = (track.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
                size.width = IslandMetrics.belowPeekWidth(band: size.width, titleWidth: title, secondaries: fit.secondaries.count,
                                                          dashboardButton: showsDashboardButton,
                                                          maxWidth: settings.compactMaxWidth > 0 ? settings.compactMaxWidth : nil)
            }
            size.height += peekHeight
        } else if peekingDevice != nil {
            size.height += peekHeight
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
    /// state, for turning a drag into a scale. nil where resizing doesn't apply:
    /// the compact island fits its content, so only open states resize.
    var resizeBase: CGFloat? {
        switch presentation {
        case .idle, .compact, .alert: return nil
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
        // Peeking stays in the small-card corner family (18 pt), however tall the band gets.
        IslandMetrics.radius(forHeight: peekHeight > 0 ? min(bodySize.height, 70) : bodySize.height)
    }

    var material: IslandMaterial { settings.material }

    /// Colour behind the island while music plays, taken from the artwork.
    var glowColor: Color? {
        guard settings.glowFromArtwork, !isTucked, let color = env.nowPlaying.artworkColor,
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
        let animation: Animation = reduceMotion ? IslandMotion.reduced : open ? IslandMotion.open : IslandMotion.close
        withAnimation(animation, body)
    }

    func showPage(_ page: NowPlayingPage) {
        animate(open: page != .player) { nowPlayingPage = nowPlayingPage == page ? .player : page }
    }

    func setHover(_ inside: Bool) {
        guard hover != inside else { return }
        withAnimation(reduceMotion ? nil : IslandMotion.hover) { hover = inside }
        // When the island hides until hover, coming out is the motion: no bounce on top.
        if inside, !isOpen, !reduceMotion, !hidesUntilHover { bounce += 1 }
    }

    /// Should this point (in the island's coordinate space) show the title? Only
    /// the artwork opens it; once open, the title row keeps it open.
    func isOverMedia(_ point: CGPoint) -> Bool {
        if let art = mediaRects["artwork"], art.insetBy(dx: -5, dy: -5).contains(point) { return true }
        if let icon = mediaRects["alertIcon"], icon.insetBy(dx: -5, dy: -5).contains(point) { return true }
        if peek, let row = mediaRects["title"], row.insetBy(dx: 0, dy: -3).contains(point) { return true }
        return false
    }

    /// The pointer moved on or off the track. Shows the title almost at once
    /// (a brief rest filters out a pass across the menu bar) and hides it after
    /// a short grace, so crossing from the ear to the title row keeps it open.
    func setOverMedia(_ on: Bool) {
        guard on != overMedia else { return }
        overMedia = on
        // A device alert stays up while its details are being read.
        if case .alert = presentation { on ? env.engine.holdAlert() : env.engine.releaseAlert() }
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(on ? 60 : 140))
            guard !Task.isCancelled, let self, self.overMedia == on, self.peek != on else { return }
            let animation: Animation = self.reduceMotion ? IslandMotion.reduced : on ? IslandMotion.peekOpen : IslandMotion.peekClose
            withAnimation(animation) { self.peek = on }
        }
    }

    #if DEBUG
    /// Offline renders of the hover state.
    func debugPeek(hover: Bool, peek: Bool) { self.hover = hover; self.peek = peek }
    #endif

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
