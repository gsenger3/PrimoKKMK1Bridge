//
//  kkmap.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  kkmap: guided control mapper for the Komplete Kontrol S61 MK1.
//
//  Reads the "- item" lines of a Markdown file in order, prompts for each control, and records which
//  HID button bits, encoder nibbles and MIDI messages that control produces. Writes BUTTON_MAP.md,
//  button_map.json and a raw capture_mapping.log into OUT_DIR after every control.
//
//    swiftc -O tools/kkmap.swift -o build/kkmap
//    build/kkmap [--native] "KKS61 Button Map.md" device
//
//  While running: s + Enter = skip this control, b + Enter = go back one, q + Enter = save and quit.
//  Without --native it is read-only toward the keyboard. With --native it sends one output report,
//  0xA0 00 00 (the host "init" that DrivenByMoss sends), which switches the keyboard from MIDI mode to
//  native/host mode so Scale, Arp, the page arrows and knob touch report over HID. Replug to undo.

import CoreMIDI
import Foundation
import IOKit.hid

setvbuf(stdout, nil, _IOLBF, 0)
var argv = Array(CommandLine.arguments.dropFirst())
let native = argv.contains("--native")
argv.removeAll { $0 == "--native" }
guard argv.count >= 2 else { print("usage: kkmap [--native] <button-map.md> <out-dir>"); exit(2) }
let mdPath = argv[0], outDir = argv[1]

struct Item { let line: Int; let section: String; let label: String }

func loadItems(_ path: String) -> [Item] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(1) }
    var section = "", out: [Item] = []
    for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
        let l = raw.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("#") {
            section = l.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        } else if l.hasPrefix("- ") || l.hasPrefix("* ") {
            let label = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !label.isEmpty { out.append(Item(line: i + 1, section: section, label: label)) }
        }
    }
    return out
}

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined(separator: " ") }

final class Gesture {
    var sources: [String] = []
    var minV: [String: Int] = [:], maxV: [String: Int] = [:]
    var encSteps: [String: Int] = [:]
    var notes: [String] = []
    func add(_ key: String, value: Int?) {
        if !sources.contains(key) { sources.append(key) }
        if let v = value { minV[key] = min(minV[key] ?? v, v); maxV[key] = max(maxV[key] ?? v, v) }
    }
    func describe() -> [String] {
        sources.map { k in
            if let st = encSteps[k] { return "\(k) (\(st > 0 ? "+" : "")\(st) steps)" }
            if let a = minV[k], let b = maxV[k] { return a == b ? "\(k) = \(a)" : "\(k) [\(a)..\(b)]" }
            return k
        } + notes
    }
}

final class App {
    let items: [Item]
    var idx = 0
    var current: Gesture?
    var results: [Int: [String]] = [:]
    var lastEvent = Date.distantPast
    var buttonsDown = Set<Int>()
    var prev01: [UInt8]?
    var prev0f: [UInt8]?
    let tf = DateFormatter()
    let logHandle: FileHandle

    init(items: [Item]) {
        self.items = items
        tf.dateFormat = "HH:mm:ss.SSS"
        let logPath = outDir + "/capture_mapping.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logHandle = FileHandle(forWritingAtPath: logPath)!
    }

    func log(_ s: String) { logHandle.write((tf.string(from: Date()) + " " + s + "\n").data(using: .utf8)!) }

    func event(_ key: String, value: Int? = nil) {
        guard idx < items.count else { return }
        if current == nil { current = Gesture() }
        current!.add(key, value: value)
        lastEvent = Date()
    }

    func extend() { if current != nil { lastEvent = Date() } }

    func onHID(_ id: Int, _ b: [UInt8]) {
        log("HID 0x\(String(format: "%02x", id)) " + hex(b))
        switch id {
        case 0x01 where b.count >= 38:
            var p = prev01 ?? b
            if prev01 == nil { for i in 1...5 { p[i] = 0 } }  // at rest every button is up
            prev01 = b
            for bit in 0..<40 {
                let byte = 1 + bit / 8, m = UInt8(1 << (bit % 8))
                guard (p[byte] ^ b[byte]) & m != 0 else { continue }
                if b[byte] & m != 0 {
                    buttonsDown.insert(bit)
                    event("HID button bit \(bit) (byte \(byte), mask 0x\(String(format: "%02x", m)))")
                } else {
                    buttonsDown.remove(bit)
                    extend()
                }
            }
            for (name, shift) in [("HID encoder, byte 6 low nibble", 0), ("HID encoder, byte 6 high nibble", 4)] {
                let a = Int((p[6] >> UInt8(shift)) & 0x0f), c = Int((b[6] >> UInt8(shift)) & 0x0f)
                if a != c {
                    var d = c - a
                    if d > 8 { d -= 16 } else if d < -8 { d += 16 }
                    event(name)
                    current?.encSteps[name, default: 0] += d
                }
            }
            if native {  // in native mode the knobs report raw positions (0-999, wrapping) instead of MIDI CCs
                for k in 0..<8 {
                    let o = 7 + k * 2
                    let a = Int(p[o]) | Int(p[o + 1]) << 8, c = Int(b[o]) | Int(b[o + 1]) << 8
                    guard a != c else { continue }
                    var d = c - a
                    if d < -500 { d += 1000 } else if d > 500 { d -= 1000 }
                    let name = "HID knob \(k + 1) position (bytes \(o)-\(o + 1))"
                    event(name)
                    current?.encSteps[name, default: 0] += d
                }
            }
            if p[37] != b[37] { current?.notes.append("base note \(p[37]) → \(b[37])") }
        case 0x0f:
            // Not press/release: byte 1 flips between 0 and 1 and stays there (a state, sent on change).
            prev0f = b
            event("HID report 0x0f byte 1 → \(b.count > 1 ? Int(b[1]) : -1)")
        default:
            event("HID report 0x\(String(format: "%02x", id))")
        }
    }

    func onMIDI(_ bytes: [UInt8], port: String) {
        log("MIDI \(port) " + hex(bytes))
        var i = 0
        var status: UInt8 = 0
        while i < bytes.count {
            let x = bytes[i]
            if x >= 0xF8 { i += 1; continue }  // realtime
            if x == 0xF0 {
                var j = i
                while j < bytes.count && bytes[j] != 0xF7 { j += 1 }
                event("MIDI SysEx (\(port))")
                i = j + 1
                continue
            }
            if x >= 0x80 { status = x; i += 1 }
            guard status >= 0x80 && status < 0xF0 else { i += 1; continue }
            let hi = status & 0xF0, ch = Int(status & 0x0F) + 1
            let n = (hi == 0xC0 || hi == 0xD0) ? 1 : 2
            guard i + n <= bytes.count else { break }
            let d1 = Int(bytes[i]), d2 = n == 2 ? Int(bytes[i + 1]) : 0
            i += n
            switch hi {
            case 0xB0: event("MIDI CC\(d1) ch\(ch) (\(port))", value: d2)
            case 0xE0: event("MIDI pitch bend ch\(ch) (\(port))", value: d2 << 7 | d1)
            case 0xC0: event("MIDI program change ch\(ch) (\(port))", value: d1)
            case 0x90 where d2 > 0 && idx < items.count && items[idx].label.lowercased().contains("key"):
                event("MIDI note \(d1) on ch\(ch) (\(port))", value: d2)  // only for "key" prompts
            default: break  // notes and aftertouch from the keys are logged but not attributed
            }
        }
    }

    func tick() {
        guard let g = current, idx < items.count else { return }
        let quiet = Date().timeIntervalSince(lastEvent)
        guard quiet > 1.0 && (buttonsDown.isEmpty || quiet > 4.0) else { return }
        current = nil
        let d = g.describe()
        results[idx] = d
        print("   → " + d.joined(separator: "; "))
        log("ITEM \(idx + 1) \(items[idx].label): " + d.joined(separator: "; "))
        advance()
    }

    func advance() {
        idx += 1
        save()
        if idx >= items.count { finish() } else { prompt() }
    }

    func prompt() {
        let it = items[idx]
        let l = it.label.lowercased()
        let how = l.contains("strip") ? "slide along it"
            : (l.hasPrefix("encoder") || l == "knob") ? "turn it a few clicks"
            : "press it once"
        print("\n[\(idx + 1)/\(items.count)] \(it.section) › \u{1B}[1m\(it.label)\u{1B}[0m — \(how)")
    }

    func onInput(_ s: String) {
        guard idx < items.count else { return }
        switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "s":
            current = nil
            results[idx] = ["(skipped)"]
            print("   → skipped")
            advance()
        case "b":
            current = nil
            if idx > 0 { idx -= 1; results[idx] = nil }
            print("   ↩ back one")
            prompt()
        case "q":
            save()
            print("saved \(results.count) of \(items.count); quitting")
            exit(0)
        default:
            print("   (s + Enter = skip, b + Enter = back one, q + Enter = save and quit)")
        }
    }

    func save() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# KKS61 MK1 control map\n\nCaptured \(df.string(from: Date())) with `tools/kkmap` from "
            + "`\((mdPath as NSString).lastPathComponent)`. Firmware 72, \(native ? "native mode (init report a0 00 00 sent)" : "stock MIDI mode"), no NI software running.\n\n"
            + "| # | Section | Control | Reports as |\n|---|---|---|---|\n"
        var json: [[String: Any]] = []
        for (i, it) in items.enumerated() {
            let r = results[i]
            md += "| \(i + 1) | \(it.section) | \(it.label) | \(r?.joined(separator: "<br>") ?? "—") |\n"
            json.append(["index": i + 1, "line": it.line, "section": it.section, "label": it.label, "reports": r ?? []])
        }
        try? md.write(toFile: outDir + "/BUTTON_MAP.md", atomically: true, encoding: .utf8)
        if let d = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: outDir + "/button_map.json"))
        }
    }

    func finish() {
        save()
        print("\nAll \(items.count) controls captured → \(outDir)/BUTTON_MAP.md and button_map.json")
        exit(0)
    }
}

// ---- setup ----
let items = loadItems(mdPath)
guard !items.isEmpty else { print("no '- item' lines in \(mdPath)"); exit(1) }
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let app = App(items: items)

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x17cc, kIOHIDProductIDKey: 0x1360,
                                    kIOHIDPrimaryUsagePageKey: 0xff01] as CFDictionary)
guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
      let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devs.first else {
    print("Komplete Kontrol S61 MK1 HID interface not found — is it plugged in?"); exit(1)
}
let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
let hidCB: IOHIDReportCallback = { ctx, _, _, _, rid, rpt, len in
    let a = Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue()
    a.onHID(Int(rid), Array(UnsafeBufferPointer(start: rpt, count: len)))
}
IOHIDDeviceRegisterInputReportCallback(dev, reportBuf, 512, hidCB, Unmanaged.passUnretained(app).toOpaque())
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

if native {
    var initReport: [UInt8] = [0xA0, 0x00, 0x00]  // report ID first, as IOHIDDeviceSetReport expects
    let r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0xA0, &initReport, initReport.count)
    app.log("SENT output report a0 00 00 -> 0x\(String(r, radix: 16))")
    if r == kIOReturnSuccess {
        print("Sent init report a0 00 00: keyboard should now be in native mode. Unplug and replug it to return to MIDI mode.")
    } else {
        print("Init report failed (0x\(String(r, radix: 16))); continuing in MIDI mode.")
    }
}

var midiClient = MIDIClientRef(), midiPort = MIDIPortRef()
var portNames: [String] = []
MIDIClientCreate("kkmap" as CFString, nil, nil, &midiClient)
MIDIInputPortCreateWithBlock(midiClient, "in" as CFString, &midiPort) { list, refCon in
    let tag = refCon.map { Int(bitPattern: $0) } ?? 0
    var pkt = list.pointee.packet
    var all: [[UInt8]] = []
    for _ in 0..<list.pointee.numPackets {
        all.append(withUnsafeBytes(of: pkt.data) { Array($0.prefix(Int(pkt.length))) })
        pkt = MIDIPacketNext(&pkt).pointee
    }
    DispatchQueue.main.async {
        let name = tag > 0 && tag <= portNames.count ? portNames[tag - 1] : "?"
        for bytes in all { app.onMIDI(bytes, port: name) }
    }
}
for i in 0..<MIDIGetNumberOfSources() {
    let src = MIDIGetSource(i)
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(src, kMIDIPropertyDisplayName, &cf)
    let n = (cf?.takeRetainedValue() as String?) ?? "?"
    if n.uppercased().contains("KOMPLETE KONTROL S61") {
        portNames.append(n.replacingOccurrences(of: "KOMPLETE KONTROL S61 ", with: ""))
        MIDIPortConnectSource(midiPort, src, UnsafeMutableRawPointer(bitPattern: portNames.count))
    }
}

FileHandle.standardInput.readabilityHandler = { h in
    let d = h.availableData
    if d.isEmpty { h.readabilityHandler = nil; return }
    let s = String(decoding: d, as: UTF8.self)
    DispatchQueue.main.async { for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty || s == "\n" { app.onInput(String(line)) } }
}
Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in app.tick() }

print("KKS61 guided mapper — \(items.count) controls from \((mdPath as NSString).lastPathComponent)")
print("MIDI ports: \(portNames.joined(separator: ", ")).  HID: connected.")
print("Operate each control when prompted, then let go and wait ~1 s; it moves on by itself.")
print("Type s + Enter to skip a control, b + Enter to go back one, q + Enter to save and quit.")
app.prompt()
CFRunLoopRun()
