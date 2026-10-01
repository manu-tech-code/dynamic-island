import CoreGraphics
import Foundation
import Testing
@testable import IslandCore

@Suite struct CompactAlertTests {
    let notch = CGSize(width: 185, height: 32)
    let pods = BluetoothDeviceInfo(id: "p", name: "AirPods Pro", kind: .airpodsPro, batteryLeft: 80, batteryRight: 64, batteryCase: 45)

    @Test func statusAlertsAreCompactAndButtonAlertsStayCards() {
        let compact: [IslandAlert.Style] = [.deviceConnected(pods), .deviceDisconnected(name: "x", kind: .airpods),
                                            .chargerConnected(percent: 80), .chargerDisconnected(percent: 80), .lowBattery(percent: 9)]
        let cards: [IslandAlert.Style] = [.timerFinished(label: "x"), .downloadFinished(name: "x", path: "/x"),
                                          .message(title: "x", subtitle: "y", symbol: "z"),
                                          .eventStarting(CalendarEventInfo(id: "e", title: "x", start: .now, end: .now))]
        for s in compact { #expect(IslandAlert(kind: .devices, style: s).isCompact) }
        for s in cards { #expect(!IslandAlert(kind: .devices, style: s).isCompact) }
    }

    @Test func airPodsAlertIsCompactSized() {
        let beside = IslandMetrics.alertSize(for: .deviceConnected(pods), notch: notch, compactStyle: .beside)
        #expect(beside == CGSize(width: notch.width + 2 * 50, height: notch.height)) // icon | ring, like the island
        let below = IslandMetrics.alertSize(for: .deviceConnected(pods), notch: notch, compactStyle: .below)
        #expect(below.height == notch.height + IslandMetrics.belowBand)
        // Power alerts carry the percentage too, so they're a little wider.
        #expect(IslandMetrics.alertSize(for: .chargerConnected(percent: 80), notch: notch).width > beside.width)
    }

    @Test func ringShowsTheLowerEarbud() {
        #expect(pods.ringPercent == 64)
        #expect(BluetoothDeviceInfo(id: "k", name: "Keyboard", kind: .keyboard, battery: 50).ringPercent == 50)
        #expect(BluetoothDeviceInfo(id: "c", name: "Case", kind: .airpods, batteryCase: 30).ringPercent == 30)
        #expect(BluetoothDeviceInfo(id: "n", name: "None", kind: .speaker).ringPercent == nil)
    }

    @Test func lockIndicatorIsOneGlyphWide() {
        let s = IslandMetrics.lockSize(notch: notch)
        #expect(s == CGSize(width: notch.width + 2 * 50, height: notch.height))
    }
}
