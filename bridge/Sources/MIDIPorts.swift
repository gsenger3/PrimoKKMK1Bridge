//
//  MIDIPorts.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  CoreMIDI: the virtual source and destination, DAW feedback, and the keyboard's keys merged in.

import CoreMIDI
import Foundation

// MARK: - MIDI ports (virtual source out, virtual destination for DAW feedback)

func stableUniqueID(_ s: String) -> MIDIUniqueID {
    var h: UInt32 = 2_166_136_261  // FNV-1a, so DAWs see the same port ID on every launch
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return MIDIUniqueID(bitPattern: h)
}

/// Control changes in a raw MIDI 1.0 byte stream (running status aware); everything else is skipped.
func controlChanges(in bytes: [UInt8]) -> [(channel: Int, cc: Int, value: Int)] {
    var out: [(channel: Int, cc: Int, value: Int)] = []
    var status: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let x = bytes[i]
        if x >= 0xF8 { i += 1; continue }  // realtime
        if x == 0xF0 {                     // SysEx
            while i < bytes.count && bytes[i] != 0xF7 { i += 1 }
            i += 1
            status = 0
            continue
        }
        if x >= 0x80 { status = x < 0xF0 ? x : 0; i += 1; continue }
        guard status != 0 else { i += 1; continue }
        let n = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
        guard i + n <= bytes.count else { break }
        if status & 0xF0 == 0xB0 { out.append((Int(status & 0x0F) + 1, Int(bytes[i]), Int(bytes[i + 1]))) }
        i += n
    }
    return out
}

func midiName(_ e: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &cf)
    return (cf?.takeRetainedValue() as String?) ?? ""
}

final class MIDIPorts {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let dryRun: Bool
    /// Called on the main queue for every control change the DAW sends to the destination.
    var onControlChange: ((Int, Int, Int) -> Void)?
    private(set) var feedbackAvailable = false

    /// Keyboard merge: everything the keyboard's own MIDI port sends (keys, pitch and mod strips, pedals) is
    /// passed on to the virtual source too, so one DAW input carries both the keys and the bridge's CCs.
    private let keysSource: String?  // "auto" (the keyboard's Port 1), a source name, or nil for no merge
    private var keysPort = MIDIPortRef()
    private var keysConnected: [MIDIEndpointRef] = []
    /// Called on the main queue with the names of the merged sources whenever they change.
    var onKeysChanged: (([String]) -> Void)?

    init(name: String, dryRun: Bool, keysSource: String? = nil) {
        self.dryRun = dryRun
        self.keysSource = keysSource
        guard !dryRun else { return }
        var st = MIDIClientCreateWithBlock("PrimoKKMK1Bridge" as CFString, &client) { [weak self] note in
            // A device came or went (e.g. the keyboard was replugged): reconnect the merge.
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectKeys() }
        }
        guard st == noErr else { fail("MIDIClientCreate failed (\(st))") }
        st = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard st == noErr else { fail("could not create the virtual MIDI port \"\(name)\" (\(st))") }
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, stableUniqueID(name))

        if keysSource != nil {
            st = MIDIInputPortCreateWithProtocol(client, "keyboard in" as CFString, ._1_0, &keysPort) { [weak self] list, _ in
                guard let self else { return }
                MIDIReceivedEventList(self.source, list)  // pass the keyboard's events straight on
            }
            if st != noErr { print("warning: could not create the keyboard merge port (\(st)); keys stay on the keyboard's own port") }
        }

        let listHeader = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4
        let lengthOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length) ?? 8
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        st = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { [weak self] list, _ in
            var found: [(channel: Int, cc: Int, value: Int)] = []
            var pkt = UnsafeRawPointer(list) + listHeader
            for _ in 0..<list.pointee.numPackets {
                let len = Int(pkt.loadUnaligned(fromByteOffset: lengthOffset, as: UInt16.self))
                found += controlChanges(in: Array(UnsafeRawBufferPointer(start: pkt + dataOffset, count: len)))
                pkt = UnsafeRawPointer(MIDIPacketNext(pkt.assumingMemoryBound(to: MIDIPacket.self)))
            }
            guard !found.isEmpty else { return }
            DispatchQueue.main.async { for m in found { self?.onControlChange?(m.channel, m.cc, m.value) } }
        }
        if st == noErr {
            MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, stableUniqueID(name + " feedback"))
            feedbackAvailable = true
        } else {
            print("warning: could not create the feedback port (\(st)); lights will only follow button presses")
        }
    }

    /// (Re)connect the keyboard's MIDI source(s) to the merge, if the matching sources changed.
    func connectKeys(report: Bool = false) {
        guard let want = keysSource, keysPort != 0 else { return }
        var matches: [MIDIEndpointRef] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != source else { continue }  // never our own port
            let n = midiName(src)
            let hit = want == "auto" ? n.uppercased().hasPrefix("KOMPLETE KONTROL S") && n.hasSuffix("Port 1") : n == want
            if hit { matches.append(src) }
        }
        guard matches != keysConnected || report else { return }
        for e in keysConnected { MIDIPortDisconnectSource(keysPort, e) }
        keysConnected = matches.filter { MIDIPortConnectSource(keysPort, $0, nil) == noErr }
        onKeysChanged?(keysConnected.map(midiName))
    }

    /// Remove the virtual ports and the MIDI client (before restarting with a new config).
    func close() {
        guard !dryRun else { return }
        for e in keysConnected { MIDIPortDisconnectSource(keysPort, e) }
        keysConnected = []
        if destination != 0 { MIDIEndpointDispose(destination) }
        if source != 0 { MIDIEndpointDispose(source) }
        MIDIClientDispose(client)
    }

    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        guard !dryRun else { return }
        var word = UInt32(0x2000_0000) | UInt32(status) << 16 | UInt32(d1) << 8 | UInt32(d2)  // UMP MIDI 1.0 voice
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { lp in
            let pkt = MIDIEventListInit(lp, ._1_0)
            _ = MIDIEventListAdd(lp, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &word)
            MIDIReceivedEventList(source, lp)
        }
    }
}
