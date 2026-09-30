import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct Phase3Tests {
    let notch = CGSize(width: 185, height: 32)
    let apps = (0..<12).map { RunningAppInfo(pid: Int32($0), bundleID: "b\($0)", name: "App \($0)") }
    let music = Activity(id: "m", kind: .nowPlaying, payload: .nowPlaying(NowPlayingInfo(title: "x")))

    @Test func dashboardColumnsFollowWidth() {
        #expect(DashboardLayout.columns(forWidth: DashboardLayout.width(scale: 0.75)) == 3)
        #expect(DashboardLayout.columns(forWidth: DashboardLayout.width(scale: 1)) == 4)
        #expect(DashboardLayout.columns(forWidth: DashboardLayout.width(scale: 1.35)) == 5)
        #expect(DashboardLayout.slotWidth(forWidth: 510) > 130)
    }

    @Test func narrowerDashboardNeedsMoreRows() {
        var s = IslandSettings()
        s.openWidthScale = 1
        let standard = s.dashboardRows
        s.openWidthScale = 0.75
        #expect(s.dashboardRows > standard)
    }

    @Test func widthScaleScalesOpenStates() {
        let wide = IslandMetrics.bodySize(for: .shelf, ranked: .init(), expandedKind: nil, context: .init(notch: notch, widthScale: 1.2))
        let narrow = IslandMetrics.bodySize(for: .shelf, ranked: .init(), expandedKind: nil, context: .init(notch: notch, widthScale: 0.8))
        #expect(wide.width > narrow.width)
        #expect(wide.height == narrow.height) // only the width changes
        let player = IslandMetrics.bodySize(for: .expanded(activityID: "m"), ranked: .init(), expandedKind: .nowPlaying,
                                            context: .init(notch: notch, widthScale: 0.5))
        #expect(player.width == CGFloat(360)) // never below the minimum
    }

    @Test func compactLimitFoldsIconsIntoOverflow() {
        let ranked = RankedActivities(visible: [Activity(id: "a", kind: .backgroundApps, payload: .backgroundApps(apps))])
        let free = IslandMetrics.fitCompact(notch: notch, style: .beside, ranked: ranked, iconLimit: 12, dashboardButton: false, maxWidth: nil)
        let capped = IslandMetrics.fitCompact(notch: notch, style: .beside, ranked: ranked, iconLimit: 12, dashboardButton: false, maxWidth: 400)
        #expect(free.size.width > 400)
        #expect(capped.size.width <= 400)
        #expect(capped.iconLimit < 12)
    }

    @Test func compactLimitMovesExtraActivitiesToOverflow() {
        let timer = Activity(id: "t", kind: .timer, payload: .timer(TimerInfo(label: "", duration: 60, endDate: nil)))
        let cal = Activity(id: "c", kind: .calendar, payload: .calendar(CalendarEventInfo(id: "c", title: "", start: .now, end: .now)))
        let ranked = RankedActivities(visible: [music, timer, cal])
        let fit = IslandMetrics.fitCompact(notch: notch, style: .beside, ranked: ranked, iconLimit: 4, dashboardButton: true, maxWidth: 330)
        #expect(fit.ranked.visible.count < 3)
        #expect(fit.ranked.visible.first?.id == "m") // the primary always stays
        #expect(fit.ranked.all.count == 3)
    }

    @Test func dashboardButtonWidensTheEars() {
        let ranked = RankedActivities(visible: [music])
        let without = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked, backgroundIconLimit: 4)
        let with = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked, backgroundIconLimit: 4, dashboardButton: true)
        #expect(with.width - without.width == 2 * IslandMetrics.dashboardButton)
    }

    @Test func newSettingsRoundTripAndClamp() {
        var s = IslandSettings()
        s.openWidthScale = 1.2
        s.compactMaxWidth = 420
        s.dashboardButton = .always
        s.fullScreen = .hide
        s.hotKey = HotKeySpec(keyCode: 2, carbonModifiers: 256 | 512, label: "⇧⌘D")
        s.displays = .menuBarDisplay
        #expect(IslandSettings.decode(s.encoded()) == s)
        let clamped = IslandSettings.decode(Data(#"{"openWidthScale":9,"compactMaxWidth":50}"#.utf8))
        #expect(clamped.openWidthScale == IslandSettings.widthScaleRange.upperBound)
        #expect(clamped.compactMaxWidth == IslandSettings.compactMaxWidthRange.lowerBound)
        #expect(IslandSettings().hotKey == .default)
    }
}
