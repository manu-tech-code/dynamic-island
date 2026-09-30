import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct FluidCompactTests {
    let notch = CGSize(width: 185, height: 32)
    let apps = (0..<13).map { RunningAppInfo(pid: Int32($0), bundleID: "b\($0)", name: "App \($0)") }
    let music = Activity(id: "m", kind: .nowPlaying, payload: .nowPlaying(NowPlayingInfo(title: "x", isPlaying: true)))
    let timer = Activity(id: "t", kind: .timer, payload: .timer(TimerInfo(label: "", duration: 60, endDate: nil)))

    func width(_ visible: [Activity], overflow: [Activity] = [], limit: Int = 4, button: Bool = true) -> CGFloat {
        IslandMetrics.compactSize(notch: notch, style: .beside, ranked: RankedActivities(visible: visible, overflow: overflow),
                                  backgroundIconLimit: limit, dashboardButton: button).width
    }

    func ear(_ content: CGFloat) -> CGFloat { IslandMetrics.earOuterPadding + content + IslandMetrics.earInnerGap }

    @Test func oneAppIconFitsJustThatIcon() {
        // 13 apps, one icon allowed: the icon on the left, the button on the right, no "+12".
        let a = Activity(id: "a", kind: .backgroundApps, payload: .backgroundApps(apps))
        let e = IslandMetrics.compactEars(primary: a, secondaries: [], iconLimit: 1, dashboardButton: true)
        #expect(e.leadingApps == 1 && e.trailingApps == 0)
        #expect(e.leading == IslandMetrics.glyph)
        #expect(e.trailing == IslandMetrics.dashboardButtonSize)
        #expect(width([a], limit: 1) == notch.width + 2 * ear(IslandMetrics.dashboardButtonSize))
    }

    @Test func extrasGoToTheShorterSide() {
        // Artwork on the left; waveform and button on the right: the second activity balances the left.
        let e = IslandMetrics.compactEars(primary: music, secondaries: [timer], iconLimit: 4, dashboardButton: true)
        #expect(e.leadingSecondaries == ["t"])
        #expect(e.trailingSecondaries.isEmpty)
        #expect(abs(e.leading - e.trailing) <= IslandMetrics.glyph + IslandMetrics.glyphSpacing)
    }

    @Test func appIconsBalanceAcrossTheEars() {
        let a = Activity(id: "a", kind: .backgroundApps, payload: .backgroundApps(apps))
        for limit in 1...8 {
            let e = IslandMetrics.compactEars(primary: a, secondaries: [], iconLimit: limit, dashboardButton: true)
            #expect(e.leadingApps + e.trailingApps == limit)
            // Never more than one icon's worth of empty room on the shorter side.
            #expect(abs(e.leading - e.trailing) <= IslandMetrics.glyph + IslandMetrics.glyphSpacing)
        }
    }

    @Test func growsAndShrinksWithWhatIsActive() {
        let calendar = Activity(id: "c", kind: .calendar, payload: .calendar(CalendarEventInfo(id: "c", title: "", start: .now, end: .now)))
        #expect(width([music, timer], button: false) > width([music], button: false))
        // With the button, the right ear is fuller: a second activity first fills the empty room on the left…
        #expect(width([music, timer]) == width([music]))
        // …and only a third makes the island wider.
        #expect(width([music, timer, calendar]) > width([music, timer]))
        #expect(width([music], overflow: [timer]) == width([music])) // past the limit: not shown, no room kept
    }

    @Test func hiddenAppsTakeNoRoom() {
        let few = Activity(id: "a", kind: .backgroundApps, payload: .backgroundApps(Array(apps.prefix(1))))
        let many = Activity(id: "a", kind: .backgroundApps, payload: .backgroundApps(apps))
        #expect(width([few], limit: 1) == width([many], limit: 1))
    }

    @Test func removedOnHoverModeReadsAsShow() throws {
        let s = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"dashboardButton":"onHover"}"#.utf8))
        #expect(s.dashboardButton == .always)
        let off = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"dashboardButton":"off"}"#.utf8))
        #expect(off.dashboardButton == .off)
        #expect(IslandSettings().dashboardButton == .always)
    }
}
