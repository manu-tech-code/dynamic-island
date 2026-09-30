import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct LayoutTests {
    let notch = CGSize(width: 185, height: 32)

    func ranked(_ payloads: [ActivityPayload], overflow: Int = 0) -> RankedActivities {
        let acts = payloads.enumerated().map { Activity(id: "\($0.offset)", kind: kind($0.element), payload: $0.element) }
        let extra = (0..<overflow).map { Activity(id: "o\($0)", kind: .timer, payload: .timer(TimerInfo(label: "", duration: 60, endDate: nil))) }
        return RankedActivities(visible: acts, overflow: extra)
    }

    func kind(_ p: ActivityPayload) -> ActivityKind {
        switch p {
        case .nowPlaying: .nowPlaying
        case .timer: .timer
        case .calendar: .calendar
        case .battery: .battery
        case .backgroundApps: .backgroundApps
        case .shelf: .shelf
        case .download: .downloads
        case .privacy: .privacy
        }
    }

    let music = ActivityPayload.nowPlaying(NowPlayingInfo(title: "x"))

    @Test func idleHidesUnderTheNotch() {
        let s = IslandMetrics.bodySize(for: .idle, notch: notch, style: .beside, ranked: .init(), backgroundIconLimit: 4)
        #expect(s.width < notch.width && s.height < notch.height)
    }

    @Test func compactBesideMatchesDesign() {
        // Artwork | notch | waveform: ears of 16 + 20 + 14 pt, 32 pt tall.
        let s = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([music]), backgroundIconLimit: 4)
        #expect(s == CGSize(width: 185 + 2 * 50, height: 32))
    }

    @Test func compactBelowKeepsMenuBarClear() {
        let s = IslandMetrics.compactSize(notch: notch, style: .below, ranked: ranked([music]), backgroundIconLimit: 4)
        #expect(s.width == CGFloat(185 + 24))
        #expect(s.height == CGFloat(32) + IslandMetrics.belowBand)
    }

    @Test func secondariesWidenTheEarsButOverflowDoesNot() {
        let one = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([music]), backgroundIconLimit: 4)
        let two = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([music, music]), backgroundIconLimit: 4)
        let more = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([music, music], overflow: 3), backgroundIconLimit: 4)
        #expect(two.width > one.width)
        #expect(more.width == two.width) // activities past the limit aren't on the island
    }

    @Test func backgroundAppsRespectIconLimit() {
        let apps = (0..<9).map { RunningAppInfo(pid: Int32($0), bundleID: "b\($0)", name: "App \($0)") }
        let four = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([.backgroundApps(apps)]), backgroundIconLimit: 4)
        let nine = IslandMetrics.compactSize(notch: notch, style: .beside, ranked: ranked([.backgroundApps(apps)]), backgroundIconLimit: 9)
        #expect(nine.width > four.width)
    }

    @Test func expandedUnknownActivityFallsBackToDashboard() {
        let s = IslandMetrics.bodySize(for: .expanded(activityID: "gone"), notch: notch, style: .beside, ranked: .init(), backgroundIconLimit: 4)
        #expect(s == IslandMetrics.dashboard)
    }

    @Test func radiusGrowsWithHeight() {
        #expect(IslandMetrics.radius(forHeight: 32) == 12)
        #expect(IslandMetrics.radius(forHeight: 60) == 18)
        #expect(IslandMetrics.radius(forHeight: 88) == 28)
        #expect(IslandMetrics.radius(forHeight: 188) == 34)
        #expect(IslandMetrics.radius(forHeight: 252) == 38)
    }

    @Test func hardwareNotchFromAuxiliaryAreas() {
        // Values measured on the M5 MacBook Pro 14".
        let n = NotchMath.notch(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949), safeAreaTop: 32,
                                auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
                                auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))
        #expect(n.isHardware)
        #expect(n.rect == CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    @Test func virtualNotchOnExternalDisplay() {
        let n = NotchMath.notch(screenFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1050), safeAreaTop: 0,
                                auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        #expect(!n.isHardware)
        #expect(n.rect.width == CGFloat(185))
        #expect(n.rect.height == CGFloat(30))
        #expect(n.rect.midX == CGFloat(1512 + 960))
        #expect(n.rect.maxY == CGFloat(982))
    }
}
