import IOBluetooth
import IslandCore
import Observation

/// Bluetooth devices connecting and disconnecting (IOBluetooth). AirPods and
/// Beats report left, right and case batteries through IOBluetoothDevice
/// properties that aren't in the public headers, so each one is checked with
/// `responds(to:)` before it's read.
@Observable
final class DevicesService: NSObject {
    private(set) var connected: [BluetoothDeviceInfo] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var startedAt = Date.distantFuture

    init(settings: SettingsStore, engine: ActivityEngine) {
        self.settings = settings
        self.engine = engine
        super.init()
    }

    func start() {
        guard connectNote == nil else { return }
        startedAt = Date()
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        for case let device as IOBluetoothDevice in (IOBluetoothDevice.pairedDevices() ?? []) where device.isConnected() {
            track(device, announce: false)
        }
        Log.info("bluetooth: \(connected.count) connected at launch")
    }

    /// Re-reads batteries (AirPods report them a few seconds after connecting).
    func refreshBatteries() {
        for case let device as IOBluetoothDevice in (IOBluetoothDevice.pairedDevices() ?? []) where device.isConnected() {
            let info = Self.info(for: device)
            if let i = connected.firstIndex(where: { $0.id == info.id }), connected[i] != info { connected[i] = info }
        }
    }

    // IOBluetooth calls these on its own coordinator queue (macOS 27), not
    // the main thread, so they hop to the main actor before touching state.
    @objc nonisolated private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let box = SendableBox(device)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // The system also reports devices that were already connected when we registered.
                let announce = Date().timeIntervalSince(self.startedAt) > 3
                self.track(box.value, announce: announce)
            }
        }
    }

    @objc nonisolated private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let box = SendableBox(device)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.disconnected(box.value) }
        }
    }

    private func disconnected(_ device: IOBluetoothDevice) {
        let id = device.addressString ?? device.name ?? "?"
        disconnectNotes.removeValue(forKey: id)?.unregister()
        guard let info = connected.first(where: { $0.id == id }) else { return }
        connected.removeAll { $0.id == id }
        Log.info("bluetooth disconnected: \(info.name)")
        if settings.settings.devices.alertOnDisconnect, info.kind.isAudio {
            engine.post(IslandAlert(kind: .devices, style: .deviceDisconnected(name: info.name, kind: info.kind), holdSeconds: 2.5))
        }
    }

    private func track(_ device: IOBluetoothDevice, announce: Bool) {
        let info = Self.info(for: device)
        if !connected.contains(where: { $0.id == info.id }) { connected.append(info) }
        if disconnectNotes[info.id] == nil {
            disconnectNotes[info.id] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
        guard announce else { return }
        Log.info("bluetooth connected: \(info.name) (\(info.kind))")
        guard settings.settings.devices.alertOnConnect, info.kind.isAudio || info.hasBattery else { return }
        // Give AirPods a moment to report their batteries before announcing.
        let address = info.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.refreshBatteries()
            let latest = self.connected.first { $0.id == address } ?? info
            self.engine.post(IslandAlert(kind: .devices, style: .deviceConnected(latest), holdSeconds: 4))
        }
    }

    // MARK: reading a device

    static func info(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let name = device.name ?? "Bluetooth device"
        return BluetoothDeviceInfo(
            id: device.addressString ?? name, name: name, kind: kind(of: device, name: name),
            battery: percent(device, "batteryPercentSingle") ?? percent(device, "batteryPercentCombined"),
            batteryLeft: percent(device, "batteryPercentLeft"),
            batteryRight: percent(device, "batteryPercentRight"),
            batteryCase: percent(device, "batteryPercentCase"))
    }

    private static func percent(_ device: IOBluetoothDevice, _ key: String) -> Int? {
        guard device.responds(to: NSSelectorFromString(key)),
              let value = device.value(forKey: key) as? NSNumber else { return nil }
        let v = value.intValue
        return (1...100).contains(v) ? v : nil
    }

    private static func kind(of device: IOBluetoothDevice, name: String) -> BluetoothDeviceKind {
        let n = name.lowercased()
        if n.contains("airpods max") { return .airpodsMax }
        if n.contains("airpods pro") { return .airpodsPro }
        if n.contains("airpods") { return .airpods }
        if n.contains("beats") || n.contains("powerbeats") { return .beats }
        // Many Bluetooth LE devices report no useful class, so names come first.
        if n.contains("keyboard") { return .keyboard }
        if n.contains("trackpad") { return .trackpad }
        if n.contains("mouse") { return .mouse }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return .gameController }
        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            return n.contains("speaker") || n.contains("boom") || n.contains("soundlink") ? .speaker : .headphones
        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            if n.contains("keyboard") { return .keyboard }
            if n.contains("trackpad") { return .trackpad }
            if n.contains("mouse") { return .mouse }
            if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return .gameController }
            return .other
        default:
            return .other
        }
    }
}

extension BluetoothDeviceKind {
    var isAudio: Bool {
        switch self {
        case .airpods, .airpodsPro, .airpodsMax, .beats, .headphones, .speaker: true
        default: false
        }
    }
}
