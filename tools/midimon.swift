// midimon: log MIDI from sources whose name contains FILTER (default "KOMPLETE KONTROL").
//   swiftc -O tools/midimon.swift -o build/midimon && build/midimon [seconds] ["Primo Komplete Kontrol MK1"]
import CoreMIDI
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 30 : 30
let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2].uppercased() : "KOMPLETE KONTROL"
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"

var client = MIDIClientRef(), port = MIDIPortRef()
MIDIClientCreate("s61-midimon" as CFString, nil, nil, &client)
MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { list, _ in
    var pkt = list.pointee.packet
    for _ in 0..<list.pointee.numPackets {
        let bytes = withUnsafeBytes(of: pkt.data) { Array($0.prefix(Int(pkt.length))) }
        print("\(fmt.string(from: Date())) MIDI " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        pkt = MIDIPacketNext(&pkt).pointee
    }
}
var found = 0
for i in 0..<MIDIGetNumberOfSources() {
    let src = MIDIGetSource(i)
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &name)
    let n = (name?.takeRetainedValue() as String?) ?? "?"
    if n.uppercased().contains(filter) { MIDIPortConnectSource(port, src, nil); print("listening on MIDI source: \(n)"); found += 1 }
}
if found == 0 { print("no MIDI source matching \"\(filter)\" found"); exit(1) }
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
print("done")
