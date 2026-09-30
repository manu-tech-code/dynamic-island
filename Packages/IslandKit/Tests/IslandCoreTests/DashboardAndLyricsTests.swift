import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct DashboardTests {
    @Test func defaultsFillTwoRows() {
        let rows = DashboardLayout.rows(DashboardItem.defaults)
        #expect(rows.count == 2)
        #expect(rows[0].map(\.kind) == [.nowPlaying, .calendar, .timer])
        #expect(rows[0].first?.size == .medium) // Now Playing takes half the width
    }

    @Test func mediumThatDoesNotFitStartsNextRow() {
        let rows = DashboardLayout.rows([.init(.cpu), .init(.memory), .init(.storage), .init(.nowPlaying, .medium)])
        #expect(rows.map { $0.map(\.kind) } == [[.cpu, .memory, .storage], [.nowPlaying]])
    }

    @Test func dropsRowsBeyondTheMaximum() {
        let many = Array(repeating: DashboardItem(.nowPlaying, .medium), count: 10)
        #expect(DashboardLayout.rows(many).count == DashboardLayout.maxRows)
    }

    @Test func heightGrowsByRows() {
        let one = DashboardLayout.size(rows: 1, notchHeight: 32)
        let two = DashboardLayout.size(rows: 2, notchHeight: 32)
        #expect(two.height - one.height == DashboardLayout.cardHeight + DashboardLayout.spacing)
        #expect(one.width == DashboardLayout.width)
    }

    @Test func sizesAreClampedToWhatTheWidgetAllows() {
        #expect(DashboardItem(.battery, .medium).size == .small)
        #expect(DashboardItem(.cpu, .medium).size == .medium)
    }

    @Test func settingsDecodeWidgetsAndSkipUnknownKinds() {
        let json = #"{"dashboard":[{"kind":"cpu","size":"medium"},{"kind":"hologram","size":"small"},{"kind":"cpu","size":"small"},{"kind":"battery","size":"medium"}]}"#
        let s = IslandSettings.decode(Data(json.utf8))
        #expect(s.dashboard == [DashboardItem(.cpu, .medium), DashboardItem(.battery, .small)])
    }

    @Test func disabledModuleHidesItsWidget() {
        var s = IslandSettings()
        s[module: .nowPlaying].enabled = false
        #expect(!s.visibleDashboard.contains { $0.kind == .nowPlaying })
        #expect(s.visibleDashboard.contains { $0.kind == .cpu })
    }

    @Test func overflowChipFitsItsDigits() {
        #expect(IslandMetrics.overflowChipWidth(10) > IslandMetrics.overflowChipWidth(7))
        #expect(IslandMetrics.overflowChipWidth(0) == 0)
    }
}

@Suite struct LyricsTests {
    let lrc = """
    [ar:Iniko]
    [ti:Jericho]
    [00:06.77] First line
    [00:08.98] Second line
    [00:12.00][01:02.50] Chorus
    [00:15.3]
    """

    @Test func parsesTimestampsAndSorts() {
        let lines = LyricsParser.parseLRC(lrc)
        #expect(lines.map(\.text) == ["First line", "Second line", "Chorus", "", "Chorus"])
        #expect(abs(lines[0].time - 6.77) < 0.001)
        #expect(abs(lines[4].time - 62.5) < 0.001)
        #expect(lines.map(\.id) == [0, 1, 2, 3, 4])
    }

    @Test func currentLine() {
        let lyrics = Lyrics(synced: LyricsParser.parseLRC(lrc), plain: nil)
        #expect(lyrics.currentIndex(at: 1) == nil)
        #expect(lyrics.currentIndex(at: 6.77) == 0)
        #expect(lyrics.currentIndex(at: 10) == 1)
        #expect(lyrics.currentIndex(at: 500) == 4)
    }

    @Test func offsetShiftsEarlier() {
        let lines = LyricsParser.parseLRC("[offset:+500]\n[00:10.00] Hi")
        #expect(abs(lines[0].time - 9.5) < 0.001)
    }

    @Test func ignoresGarbage() {
        #expect(LyricsParser.parseLRC("no stamps here\n[xx:yy] nope").isEmpty)
    }
}
