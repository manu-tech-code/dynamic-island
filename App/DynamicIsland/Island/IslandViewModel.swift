import AppKit
import IslandCore
import SwiftUI

/// Which page the expanded Now Playing island shows.
enum NowPlayingPage: Equatable { case player, lyrics, upNext }

/// Island state for one display: what it shows, how big it is, and what a
/// click does. The engine decides what's live; this adds what the user opened.
@Observable
final class IslandViewModel {
    enum UserState: Equatable { case none, expanded(String), dashboard }

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
        expandedActivity?.kind == .nowPlaying && nowPlayingPage != .player
    }

    /// Identity of the content; a change swaps content with a transition.
    var contentKey: String {
        switch presentation {
        case .idle: "idle"
        case .compact: "compact-\(settings.compactStyle.rawValue)"
        case .expanded(let id): "expanded-\(id)-\(nowPlayingPage)"
        case .dashboard: "dashboard"
        case .alert(let a): "alert-\(a.id)"
        }
    }

    var bodySize: CGSize {
        let p = presentation
        var size: CGSize
        if case .expanded(let id) = p, let a = env.engine.activity(id: id) {
            size = a.kind == .nowPlaying && nowPlayingPage != .player
                ? IslandMetrics.nowPlayingDetail : IslandMetrics.expandedSize(for: a.kind)
        } else {
            size = IslandMetrics.bodySize(for: p, notch: notch.rect.size, style: settings.compactStyle,
                                          ranked: ranked, backgroundIconLimit: settings.backgroundApps.maxIcons,
                                          dashboardRows: settings.dashboardRows)
        }
        if hover {
            let g = IslandMetrics.hoverGrowth(for: p)
            size.width += g.width
            size.height += g.height
        }
        return size
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
        case .expanded, .dashboard: collapse()
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

    func toggleDashboard() {
        if userState == .dashboard { collapse() } else { openDashboard() }
    }

    func collapse() {
        guard userState != .none else { return }
        animate(open: false) { userState = .none; nowPlayingPage = .player }
    }

    /// Drops an expanded state whose activity has ended.
    func pruneIfStale() {
        if case .expanded(let id) = userState, env.engine.activity(id: id) == nil {
            animate(open: false) { userState = .none }
        }
    }
}
