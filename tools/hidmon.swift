//
//  hidmon.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  hidmon: read-only monitor for the Komplete Kontrol S61 MK1 vendor HID interface.
//
//    swiftc -O tools/hidmon.swift -o hidmon
//    ./hidmon monitor [seconds]   # log input reports; decodes report 0x01 button bits and knobs
//    ./hidmon features            # GET_REPORT every feature report the descriptor declares
//
//  Never sends output reports or SET_REPORT, so it cannot change device state.

import Foundation
import IOKit.hid

let vid = 0x17cc, pid = 0x1360
let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "monitor"
let seconds = args.count > 2 ? Double(args[2]) ?? 30 : 30

setvbuf(stdout, nil, _IOLBF, 0)
let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: vid, kIOHIDProductIDKey: pid,
                                    kIOHIDPrimaryUsagePageKey: 0xff01] as CFDictionary)
let openRes = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
guard openRes == kIOReturnSuccess else { print("IOHIDManagerOpen failed: 0x\(String(openRes, radix: 16))"); exit(1) }
guard let devs = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, let dev = devs.first else {
    print("S61 MK1 HID interface not found"); exit(1)
}
print("opened \(IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) ?? "?" as CFTypeRef)  " +
      "version \(IOHIDDeviceGetProperty(dev, kIOHIDVersionNumberKey as CFString) ?? 0 as CFTypeRef)")

func hex(_ p: UnsafePointer<UInt8>, _ n: Int) -> String {
    (0..<n).map { String(format: "%02x", p[$0]) }.joined(separator: " ")
}

if mode == "features" {
    var ids: [Int] = [0xc0, 0xf0, 0xf8]
    ids += Array(0xd0...0xdf)
    for id in ids {
        var buf = [UInt8](repeating: 0, count: 64)
        var len = CFIndex(buf.count)
        let r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, CFIndex(id), &buf, &len)
        if r == kIOReturnSuccess {
            print(String(format: "feature 0x%02x (%2d bytes): ", id, len) + buf.withUnsafeBufferPointer { hex($0.baseAddress!, len) })
        } else {
            print(String(format: "feature 0x%02x: error 0x%08x", id, r))
        }
    }
    exit(0)
}

// ---- monitor mode ----
final class State { var last = [UInt8: [UInt8]](); let t0 = Date() }
let state = State()
let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)

let cb: IOHIDReportCallback = { ctx, _, _, _, reportID, report, length in
    let st = Unmanaged<State>.fromOpaque(ctx!).takeUnretainedValue()
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let id = UInt8(truncatingIfNeeded: reportID)
    let prev = st.last[id]
    st.last[id] = bytes
    if prev == bytes { return }
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    let t = f.string(from: Date())
    var line = "\(t) id=0x\(String(format: "%02x", id)) len=\(length)"
    if id == 0x01, length >= 38, let p = prev, p.count == bytes.count {
        // payload starts at byte 1: 40 button bits (bytes 1-5), 2x4-bit (byte 6), 8 knobs u16 (bytes 7-22) ...
        for bit in 0..<40 {
            let byte = 1 + bit / 8, mask = UInt8(1 << (bit % 8))
            if (p[byte] ^ bytes[byte]) & mask != 0 {
                line += "  BUTTON bit \(bit) (byte \(byte) mask 0x\(String(format: "%02x", mask))) \((bytes[byte] & mask) != 0 ? "DOWN" : "up")"
            }
        }
        if p[6] != bytes[6] { line += "  nibbles[6] \(String(format: "%02x->%02x", p[6], bytes[6]))" }
        for k in 0..<8 {
            let o = 7 + k * 2
            let a = Int(p[o]) | Int(p[o + 1]) << 8, b = Int(bytes[o]) | Int(bytes[o + 1]) << 8
            if a != b { line += "  knob\(k + 1) \(a)->\(b)" }
        }
        var other: [String] = []
        for i in 23..<bytes.count where p[i] != bytes[i] { other.append(String(format: "b%d:%02x->%02x", i, p[i], bytes[i])) }
        if !other.isEmpty { line += "  " + other.joined(separator: " ") }
    } else {
        line += "  " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
    print(line)
}

IOHIDDeviceRegisterInputReportCallback(dev, reportBuf, 256, cb, Unmanaged.passUnretained(state).toOpaque())
IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
print("monitoring for \(Int(seconds)) s — press buttons / turn knobs")
CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false)
print("done")
