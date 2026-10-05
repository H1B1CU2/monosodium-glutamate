import CoreAudio
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct AudioDeviceRoutingTests {
    static func main() {
        let devices = (1...25).map {
            AudioDeviceRouting.Device(id: AudioDeviceID($0), uid: "device-\($0)",
                                      name: "Device \($0)", transport: kAudioDeviceTransportTypeUSB)
        }
        let page = AudioDeviceRouting.page(devices, reservedKey: 12, number: 0)
        expect(page.devicesByKey[1]?.uid == "device-1", "F1 should select the first route")
        expect(page.devicesByKey[12] == nil, "modifier F12 must never select a route")
        expect(page.moreKey == 11 && page.count == 3, "overflow should reserve F11 for pagination")
        let last = AudioDeviceRouting.page(devices, reservedKey: 12, number: 2)
        expect(last.devicesByKey[1]?.uid == "device-21", "last page should retain stable ordering")
        expect(last.devicesByKey[11] == nil, "pagination key must not also select a route")
        let single = AudioDeviceRouting.page(Array(devices.prefix(1)), reservedKey: nil, number: 0)
        expect(single.devicesByKey[1]?.uid == "device-1" && single.moreKey == nil,
               "one route should have one chooser key and no pagination")

        // 2-key devices test (MacBook Pro Microphone, Nothing Headphone (a), etc.)
        let longDevices = [
            AudioDeviceRouting.Device(id: 101, uid: "mbp-mic", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioDeviceRouting.Device(id: 102, uid: "nothing", name: "Nothing Headphone (a)", transport: kAudioDeviceTransportTypeBluetooth),
            AudioDeviceRouting.Device(id: 103, uid: "samsung", name: "Samsung galaxy Z flip 5 Microphone", transport: kAudioDeviceTransportTypeBluetooth)
        ]
        let p2key = AudioDeviceRouting.page(longDevices, reservedKey: 12, number: 0)
        expect(p2key.count == 1, "3 long devices should fit on 1 page using 2 keys each (6 slots of 11)")
        expect(p2key.items.count == 3, "should have 3 items")
        expect(p2key.items[0].keys == 1...2, "first device should span keys 1...2")
        expect(p2key.items[1].keys == 3...4, "second device should span keys 3...4")
        expect(p2key.items[2].keys == 5...6, "third device should span keys 5...6")
        expect(p2key.devicesByKey[1]?.uid == "mbp-mic" && p2key.devicesByKey[2]?.uid == "mbp-mic",
               "both F1 and F2 should map to the first device")
        expect(p2key.devicesByKey[3]?.uid == "nothing" && p2key.devicesByKey[4]?.uid == "nothing",
               "both F3 and F4 should map to the second device")
        expect(p2key.devicesByKey[5]?.uid == "samsung" && p2key.devicesByKey[6]?.uid == "samsung",
               "both F5 and F6 should map to the third device")

        // Mixed 1-key and 2-key devices test
        let mixed = [
            AudioDeviceRouting.Device(id: 201, uid: "usb", name: "USB Mic", transport: kAudioDeviceTransportTypeUSB),
            AudioDeviceRouting.Device(id: 202, uid: "mbp-mic", name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioDeviceRouting.Device(id: 203, uid: "line", name: "Line In", transport: kAudioDeviceTransportTypeBuiltIn)
        ]
        let pmixed = AudioDeviceRouting.page(mixed, reservedKey: 12, number: 0)
        expect(pmixed.items[0].keys == 1...1, "short name USB Mic should use 1 key")
        expect(pmixed.items[1].keys == 2...3, "long name MacBook Pro Microphone should use 2 keys")
        expect(pmixed.items[2].keys == 4...4, "short name Line In should use 1 key")
        expect(pmixed.devicesByKey[1]?.uid == "usb", "F1 maps to USB Mic")
        expect(pmixed.devicesByKey[2]?.uid == "mbp-mic" && pmixed.devicesByKey[3]?.uid == "mbp-mic", "F2 and F3 map to MacBook Pro Mic")
        expect(pmixed.devicesByKey[4]?.uid == "line", "F4 maps to Line In")

        for direction in [AudioDeviceRouting.Direction.input, .output] {
            let snapshot = AudioDeviceRouting.snapshot(direction)
            print("\(direction): \(snapshot.devices.count) available, selected listed: \(snapshot.selected != nil)")
        }
        print("AudioDeviceRoutingTests: PASS")
    }
}
