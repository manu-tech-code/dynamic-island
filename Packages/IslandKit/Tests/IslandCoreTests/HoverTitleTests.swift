import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct HoverTitleTests {
    let notch = CGSize(width: 185, height: 32)

    @Test func peekKeepsTheCompactCornerRadius() {
        for hasArtist in [true, false] {
            let beside = notch.height + IslandMetrics.nowPlayingPeekHeight(style: .beside, hasArtist: hasArtist)
            #expect(beside < 72)
            #expect(IslandMetrics.radius(forHeight: beside) == CGFloat(18))
        }
    }

    @Test func belowBandWithoutArtistDoesNotGrow() {
        // The band already shows the title; with no artist there's nothing to add.
        #expect(IslandMetrics.nowPlayingPeekHeight(style: .below, hasArtist: false) == 0)
        #expect(IslandMetrics.nowPlayingPeekHeight(style: .below, hasArtist: true) > 0)
    }

    @Test func belowBandWidensForTheTitle() {
        let short = IslandMetrics.belowPeekWidth(band: 261, titleWidth: 40, secondaries: 0, overflow: 1, dashboardButton: true, maxWidth: nil)
        #expect(short == CGFloat(261)) // fits already: never narrower
        let medium = IslandMetrics.belowPeekWidth(band: 261, titleWidth: 150, secondaries: 0, overflow: 1, dashboardButton: true, maxWidth: nil)
        #expect(medium > 261 && medium < 261 + 160)
        let long = IslandMetrics.belowPeekWidth(band: 261, titleWidth: 900, secondaries: 0, overflow: 1, dashboardButton: true, maxWidth: nil)
        #expect(long == CGFloat(261 + 160)) // then it scrolls
        let limited = IslandMetrics.belowPeekWidth(band: 261, titleWidth: 900, secondaries: 0, overflow: 1, dashboardButton: true, maxWidth: 300)
        #expect(limited == CGFloat(300)) // the user's compact limit wins
    }

    @Test func titleOnHoverDefaultsOnForOldSettings() throws {
        // Settings saved before the option existed.
        let old = #"{"nowPlaying":{"keepPausedMinutes":5,"lyricsEnabled":false,"showUpNext":true}}"#
        let s = try JSONDecoder().decode(IslandSettings.self, from: Data(old.utf8))
        #expect(s.nowPlaying.titleOnHover)
        #expect(s.nowPlaying.keepPausedMinutes == 5)
        #expect(s.nowPlaying.lyricsEnabled == false)
    }

    @Test func titleOnHoverRoundTrips() throws {
        var s = IslandSettings()
        s.nowPlaying.titleOnHover = false
        let back = try JSONDecoder().decode(IslandSettings.self, from: JSONEncoder().encode(s))
        #expect(back.nowPlaying.titleOnHover == false)
    }
}
