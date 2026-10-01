import IOBluetooth
import IslandCore
import Observation

/// Bluetooth devices connecting and disconnecting (IOBluetooth), from any
/// maker. AirPods and Beats report left, right and case batteries through
/// IOBluetoothDevice properties that aren't in the public headers, so each one
/// is checked with `responds(to:)` before it's read. Other earbuds and
/// headphones (Samsung, oraimo, Sony…) that send their level show it in
/// macOS's Bluetooth report instead, which is read when Apple's properties are empty.
@Observable
final class DevicesService: NSObject {
    private(set) var connected: [BluetoothDeviceInfo] = []

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let engine: ActivityEngine
    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var startedAt = Date.distantFuture
    /// Levels from the system report, for devices without Apple's properties.
    @ObservationIgnored private var reported: [String: BluetoothBatteryReport.Levels] = [:]

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
            let info = withReported(Self.info(for: device))
            if let i = connected.firstIndex(where: { $0.id == info.id }), connected[i] != info { connected[i] = info }
        }
    }

    /// Other makers' earbuds: fills in what macOS's Bluetooth report knows.
    private func withReported(_ info: BluetoothDeviceInfo) -> BluetoothDeviceInfo {
        guard !info.hasBattery, let levels = reported[BluetoothBatteryReport.normalize(info.id)] else { return info }
        var filled = info
        filled.battery = levels.main
        filled.batteryLeft = levels.left
        filled.batteryRight = levels.right
        filled.batteryCase = levels.case
        return filled
    }

    /// `system_profiler` takes a second or two, so it runs off the main thread,
    /// and only when an audio device connects without Apple's battery properties.
    private func readSystemReport() async {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data
        }.value
        guard let data else { return }
        reported = BluetoothBatteryReport.parse(data)
        Log.info("bluetooth report: batteries for \(reported.count) device(s)")
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
        // Give earbuds a moment to report their batteries before announcing.
        let address = info.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.refreshBatteries()
            if let now = self.connected.first(where: { $0.id == address }), now.kind.isAudio, !now.hasBattery {
                await self.readSystemReport()
                self.refreshBatteries()
            }
            let latest = self.connected.first { $0.id == address } ?? info
            self.engine.post(IslandAlert(kind: .devices, style: .deviceConnected(latest), holdSeconds: 4))
        }
    }

    // MARK: reading a device

    static func info(for device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        let name = device.name ?? "Bluetooth device"
        return BluetoothDeviceInfo(
            id: device.addressString ?? name, name: name,
            kind: .classify(name: name, majorClass: device.deviceClassMajor, minorClass: device.deviceClassMinor),
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
}
