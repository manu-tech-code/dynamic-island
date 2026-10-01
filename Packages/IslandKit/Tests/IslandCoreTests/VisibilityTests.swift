import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct VisibilityTests {
    @Test func defaultsToAlwaysAndMigrates() throws {
        #expect(IslandSettings().visibility == .always)
        // Settings saved before the option existed keep the island as it was.
        let old = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"fullScreen":"hide"}"#.utf8))
        #expect(old.visibility == .always)
        #expect(old.fullScreen == .hide)
        // A value from a future version falls back instead of failing.
        let unknown = try JSONDecoder().decode(IslandSettings.self, from: Data(#"{"visibility":"someday"}"#.utf8))
        #expect(unknown.visibility == .always)
    }

    @Test func roundTrips() {
        var s = IslandSettings()
        s.visibility = .onHover
        #expect(IslandSettings.decode(s.encoded()).visibility == .onHover)
    }

    @Test func revealAreaCoversTheCameraWithRoomToSpare() {
        let notch = CGRect(x: 663.5, y: 950, width: 185, height: 32) // M5 MacBook Pro 14", points
        let area = IslandMetrics.revealArea(notch: notch)
        #expect(area.contains(CGPoint(x: notch.midX, y: notch.midY)))       // the camera itself
        #expect(area.contains(CGPoint(x: notch.minX - 20, y: notch.midY)))  // just beside it
        #expect(area.contains(CGPoint(x: notch.midX, y: notch.minY - 4)))   // just below it
        #expect(!area.contains(CGPoint(x: notch.minX - 60, y: notch.midY))) // menu bar items stay clear
        #expect(area.maxY == notch.maxY)                                    // nothing above the screen
    }
}
