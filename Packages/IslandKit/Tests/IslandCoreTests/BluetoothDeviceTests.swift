import Foundation
import Testing
@testable import IslandCore

@Suite struct BluetoothDeviceTests {
    let audio = BluetoothDeviceKind.majorAudio

    @Test func earbudsFromAnyMaker() {
        for name in ["oraimo SpaceBuds", "oraimo FreePods 4", "Galaxy Buds2 Pro", "Pixel Buds Pro", "HUAWEI FreeBuds 5i",
                     "WF-1000XM5", "Soundcore Liberty 4 TWS", "Nothing Ear (a) earbuds"] {
            #expect(BluetoothDeviceKind.classify(name: name, majorClass: audio, minorClass: 0x01) == .earbuds, "\(name)")
        }
        #expect(BluetoothDeviceKind.classify(name: "AirPods Pro", majorClass: audio, minorClass: 0x01) == .airpodsPro)
    }

    @Test func classDecidesWhenTheNameDoesNot() {
        #expect(BluetoothDeviceKind.classify(name: "WH-1000XM5", majorClass: audio, minorClass: 0x06) == .headphones)
        #expect(BluetoothDeviceKind.classify(name: "Bedroom TV", majorClass: audio, minorClass: 0x05) == .speaker)
        // A soundbar calling itself a headset doesn't become earbuds.
        #expect(BluetoothDeviceKind.classify(name: "TCL S522W", majorClass: audio, minorClass: 0x01) == .headphones)
        #expect(BluetoothDeviceKind.classify(name: "BT5.4 Mouse", majorClass: BluetoothDeviceKind.majorPeripheral, minorClass: 0) == .mouse)
        #expect(BluetoothDeviceKind.earbuds.isAudio)
        #expect(!BluetoothDeviceKind.mouse.isAudio)
    }

    @Test func readsOtherMakersBatteriesFromTheSystemReport() throws {
        let json = #"""
        {"SPBluetoothDataType":[{"device_connected":[
          {"oraimo SpaceBuds":{"device_address":"82:06:20:00:16:CD","device_batteryLevelLeft":"70%","device_batteryLevelRight":"60%"}},
          {"Galaxy Buds2":{"device_address":"AA:BB:CC:00:11:22","device_batteryLevelMain":"55%"}},
          {"BT5.4 Mouse":{"device_address":"E0:68:EE:7A:45:40"}}
        ]}]}
        """#
        let report = BluetoothBatteryReport.parse(Data(json.utf8))
        #expect(report[BluetoothBatteryReport.normalize("82-06-20-00-16-cd")] == .init(left: 70, right: 60))
        #expect(report["aa:bb:cc:00:11:22"]?.main == 55)
        #expect(report["e0:68:ee:7a:45:40"] == nil) // no battery reported: not listed
        #expect(BluetoothBatteryReport.parse(Data("junk".utf8)).isEmpty)
    }
}
