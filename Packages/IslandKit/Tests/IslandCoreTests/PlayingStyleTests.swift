import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct PlayingStyleTests {
    let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32) // M5 MacBook Pro 14", points

    @Test func defaultsToTuckedAndRoundTrips() throws {
        #expect(IslandSettings().whilePlaying == .tucked)
        // Settings from before the option keep the island under the notch.
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"visibility":"onHover"}"#.utf8))
        #expect(old.whilePlaying == .tucked)
        let unknown = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"whilePlaying":"hologram"}"#.utf8))
        #expect(unknown.whilePlaying == .tucked)
        for style in PlayingStyle.allCases {
            var s = IslandSettings()
            s.whilePlaying = style
            #expect(IslandSettings.decode(s.encoded()).whilePlaying == style)
        }
        #expect(Set(PlayingStyle.allCases.map(\.displayName)).count == PlayingStyle.allCases.count)
    }

    @Test func titleOnTrackChangeIsOnAndKeepsTheOtherNowPlayingSettings() throws {
        #expect(IslandSettings().nowPlaying.titleOnTrackChange)
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"nowPlaying":{"keepPausedMinutes":7,"titleOnHover":false}}"#.utf8))
        #expect(old.nowPlaying.titleOnTrackChange)
        #expect(old.nowPlaying.keepPausedMinutes == 7)
        #expect(!old.nowPlaying.titleOnHover)
    }

    @Test func nothingExtraToPointAtWhenNothingStaysOutBesideTheNotch() {
        #expect(IslandMetrics.playingHoverArea(style: .tucked, notch: notch) == nil)
        #expect(IslandMetrics.playingHoverArea(style: .underglow, notch: notch) == nil)
    }

    @Test func bubblesSitBesideTheNotchAndCanBePointedAt() throws {
        let d = IslandMetrics.playingBubbleDiameter(notch: notch.size)
        #expect(d == 30)
        let right = try #require(IslandMetrics.playingHoverArea(style: .bubble, notch: notch))
        let centre = CGPoint(x: notch.maxX + IslandMetrics.playingBubbleGap + d / 2, y: notch.midY)
        #expect(right.contains(centre))
        #expect(!IslandMetrics.revealArea(notch: notch).contains(CGPoint(x: notch.maxX + IslandMetrics.playingBubbleGap + d - 1, y: notch.midY)))
        #expect(right.minX > notch.maxX)                      // only the bubble, not the menu bar on the left
        let both = try #require(IslandMetrics.playingHoverArea(style: .twoBubbles, notch: notch))
        #expect(both.contains(centre))
        #expect(both.contains(CGPoint(x: notch.minX - IslandMetrics.playingBubbleGap - d / 2, y: notch.midY)))
        #expect(abs(both.midX - notch.midX) < 0.001)           // symmetric
        #expect(both.maxY <= notch.maxY + 4)
    }

    @Test func theDropHangsBelowTheCamera() throws {
        let area = try #require(IslandMetrics.playingHoverArea(style: .drip, notch: notch))
        let dropCentre = CGPoint(x: notch.midX, y: notch.minY - IslandMetrics.playingDropGap - IslandMetrics.playingDropDiameter / 2)
        #expect(area.contains(dropCentre))
        #expect(!IslandMetrics.revealArea(notch: notch).contains(dropCentre))
        #expect(area.width < notch.width)                      // just the drop, not the menu bar
    }

    @Test func slimEarsReachPastTheCameraArea() throws {
        let area = try #require(IslandMetrics.playingHoverArea(style: .slim, notch: notch))
        let artwork = CGPoint(x: notch.minX - IslandMetrics.playingSlimEar + 2, y: notch.midY)
        #expect(area.contains(artwork))
        #expect(!IslandMetrics.revealArea(notch: notch).contains(artwork))
        #expect(!area.contains(CGPoint(x: notch.minX - 60, y: notch.midY)))
    }
}
