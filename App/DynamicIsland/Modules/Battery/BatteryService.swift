import Foundation
import IOKit.ps
import IslandCore
import Observation

/// Mac battery and power adapter state from IOKit, pushed by the system (no polling).
@Observable
final class BatteryService: ActivityProvider {
    let kind = ActivityKind.battery
    private(set) var info = BatteryInfo(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var alertedThresholds: Set<Int> = []
    @ObservationIgnored private var started = false

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        info = Self.read()
    }

    /// Only low battery lives on the island; plugging in and out are alerts.
    var activities: [Activity] {
        guard info.hasBattery, !info.isPluggedIn,
              let lowest = settings.settings.battery.lowBatteryPercents.min(), info.percent <= lowest else { return [] }
        return [Activity(id: "battery-low", kind: .battery, payload: .battery(info), relevance: 1)]
    }

    func start() {
        guard !started else { return }
        started = true
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { service.powerChanged() }
        }, context)?.takeRetainedValue() else {
            Log.error("IOPSNotificationCreateRunLoopSource failed")
            return
        }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private func powerChanged() {
        let old = info
        let new = Self.read()
        info = new
        guard new.hasBattery else { return }
        let s = settings.settings.battery
        if s.alertOnPower, new.isPluggedIn != old.isPluggedIn {
            engine.post(IslandAlert(kind: .battery, style: new.isPluggedIn ? .chargerConnected(percent: new.percent)
                                                                            : .chargerDisconnected(percent: new.percent)))
        }
        if new.isPluggedIn {
            alertedThresholds.removeAll()
        } else {
            for threshold in s.lowBatteryPercents.sorted(by: >) where new.percent <= threshold && !alertedThresholds.contains(threshold) {
                alertedThresholds.insert(threshold)
                engine.post(IslandAlert(kind: .battery, style: .lowBattery(percent: new.percent), holdSeconds: 4))
                break
            }
        }
    }

    static func read() -> BatteryInfo {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return BatteryInfo(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (d[minutesKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return BatteryInfo(hasBattery: true, percent: percent, isCharging: charging, isPluggedIn: plugged, minutesRemaining: minutes)
        }
        return BatteryInfo(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)
    }
}
