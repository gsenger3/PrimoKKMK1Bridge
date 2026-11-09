//
//  midisend.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  midisend: send control changes to a MIDI destination by name (for testing PrimoKKMK1Bridge's light feedback).
//    swiftc -O tools/midisend.swift -o build/midisend
//    build/midisend "Primo Komplete Kontrol MK1" CHANNEL CC VALUE [CC VALUE ...]

import CoreMIDI
import Foundation

let a = CommandLine.arguments
func usage() -> Never { print("usage: midisend DESTINATION CHANNEL CC VALUE [CC VALUE ...]"); exit(2) }
guard a.count >= 5, (a.count - 3) % 2 == 0, let ch = Int(a[2]), (1...16).contains(ch) else { usage() }
var pairs: [(UInt8, UInt8)] = []
for i in stride(from: 3, to: a.count, by: 2) {
    guard let cc = Int(a[i]), let v = Int(a[i + 1]), (0...127).contains(cc), (0...127).contains(v) else { usage() }
    pairs.append((UInt8(cc), UInt8(v)))
}

var client = MIDIClientRef(), port = MIDIPortRef()
MIDIClientCreate("midisend" as CFString, nil, nil, &client)
MIDIOutputPortCreate(client, "out" as CFString, &port)
var dest: MIDIEndpointRef = 0
for i in 0..<MIDIGetNumberOfDestinations() {
    let d = MIDIGetDestination(i)
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(d, kMIDIPropertyDisplayName, &cf)
    if (cf?.takeRetainedValue() as String?) == a[1] { dest = d }
}
guard dest != 0 else { print("no MIDI destination named \"\(a[1])\""); exit(1) }

for (cc, v) in pairs {
    let bytes: [UInt8] = [0xB0 | UInt8(ch - 1), cc, v]
    var list = MIDIPacketList()
    withUnsafeMutablePointer(to: &list) { lp in
        let pkt = MIDIPacketListInit(lp)
        _ = MIDIPacketListAdd(lp, MemoryLayout<MIDIPacketList>.size, pkt, 0, bytes.count, bytes)
        MIDISend(port, dest, lp)
    }
    print("sent ch\(ch) CC\(cc) = \(v) to \(a[1])")
}
usleep(200_000)
