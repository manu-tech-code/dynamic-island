import IslandCore
import SwiftUI

/// Island state for one display: what it shows, how big it is, and what a
/// click does. The engine decides what's live; this adds what the user opened.
@Observable
final class IslandViewModel {
    enum UserState: Equatable { case none, expanded(String), dashboard }

    let env: AppEnvironment
    var notch: NotchRect
    private(set) var hover = false
    private(set) var userState: UserState = .none

    init(env: AppEnvironment, notch: NotchRect) {
        self.env = env
        self.notch = notch
    }

    var settings: IslandSettings { env.settings.settings }
    var ranked: RankedActivities { env.engine.ranked }

    var presentation: IslandPresentation {
        let engine = env.engine
        if let alert = engine.alert, userState == .none { return .alert(alert) }
        switch userState {
        case .expanded(let id) where engine.activity(id: id) != nil: return .expanded(activityID: id)
        case .dashboard: return .dashboard
        default: return ranked.isEmpty ? .idle : .compact
        }
    }

    var isOpen: Bool { presentation.isOpen }

    /// Identity of the content; a change swaps content with a transition.
    var contentKey: String {
        switch presentation {
        case .idle: "idle"
        case .compact: "compact-\(settings.compactStyle.rawValue)"
        case .expanded(let id): "expanded-\(id)"
        case .dashboard: "dashboard"
        case .alert(let a): "alert-\(a.id)"
        }
    }

    var bodySize: CGSize {
        let p = presentation
        var size: CGSize
        if case .expanded(let id) = p, let a = env.engine.activity(id: id) {
            size = IslandMetrics.expandedSize(for: a.kind)
        } else {
            size = IslandMetrics.bodySize(for: p, notch: notch.rect.size, style: settings.compactStyle,
                                          ranked: ranked, backgroundIconLimit: settings.backgroundApps.maxIcons)
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
        presentation == .dashboard ? 36 : IslandMetrics.radius(forHeight: bodySize.height)
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

    func setHover(_ inside: Bool) {
        guard hover != inside else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)) { hover = inside }
    }

    // MARK: actions

    /// A click on the island's background.
    func tap() {
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
        animate(open: true) { userState = .expanded(activityID) }
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
        animate(open: false) { userState = .none }
    }

    /// Drops an expanded state whose activity has ended.
    func pruneIfStale() {
        if case .expanded(let id) = userState, env.engine.activity(id: id) == nil {
            animate(open: false) { userState = .none }
        }
    }
}
