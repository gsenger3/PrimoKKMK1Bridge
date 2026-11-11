//
//  Bridge+LightGuide.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/11/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The light guide (HID output report 0x82) in REAPER mode: every key in the selected track's colour. REAPER's OSC
//  doesn't report track colours, so reaper/PrimoKKMK1Bridge_TrackColor.lua, running in REAPER, sends the colour to
//  the bridge's MIDI destination as SysEx:
//    F0 7D 50 4B 01 rr gg bb F7   the selected track's colour, 0-127 each (7D: the non-commercial manufacturer ID)
//    F0 7D 50 4B 02 F7            the selected track has no colour (or there's none selected): keys off

import Foundation
import IOKit.hid

extension Bridge {
    /// Whether the light guide shows track colours: REAPER mode with reaper.lightGuide on.
    var lightGuideInUse: Bool { cfg.reaper.enabled && cfg.reaper.lightGuide }

    func sysEx(_ m: [UInt8]) {
        guard m.count >= 6, m[0] == 0xF0, m[1] == 0x7D, m[2] == 0x50, m[3] == 0x4B else { return }
        switch m[4] {
        case 0x01 where m.count >= 9: trackColor = (Int(m[5] & 0x7F), Int(m[6] & 0x7F), Int(m[7] & 0x7F))
        case 0x02: trackColor = nil
        default: return
        }
        sendLightGuide()
    }

    /// After connecting: clear the light guide if it's not in use. In use, it keeps what it showed (after a restart
    /// for a config change, the keys stay lit) until the script's next message, at most 2 seconds away.
    func lightGuideAfterConnect() {
        if !lightGuideInUse { sendLightGuide(off: true) } else if trackColor != nil { sendLightGuide() }
    }

    /// Every key in the track colour, white-balanced and at reaper.lightGuideBrightness; off without one.
    func sendLightGuide(off: Bool = false) {
        guard let dev = device else { return }
        var rgb: [UInt8] = [0, 0, 0]
        if !off, lightGuideInUse, let c = trackColor {
            let level = Double(cfg.reaper.lightGuideBrightness) / 100
            let wb = lightGuideWhiteBalance
            rgb = [(Double(c.red), wb.red), (Double(c.green), wb.green), (Double(c.blue), wb.blue)]
                .map { UInt8(max(0, min(127, ($0.0 * $0.1 * level).rounded()))) }
        }
        let keys = mk1KeyCount[devicePID] ?? 61
        let payload = Array((0..<keys).map { _ in rgb }.joined())
        guard payload != lightGuideSent else { return }
        var report: [UInt8] = [reportLightGuide] + payload  // report ID first, as IOHIDDeviceSetReport expects
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportLightGuide), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("light guide report failed: 0x\(String(st, radix: 16))")
            return
        }
        lightGuideSent = payload
        if verbose {
            log(rgb == [0, 0, 0] ? "light guide: off"
                : "light guide: track colour \(trackColor.map { "\($0.red) \($0.green) \($0.blue)" } ?? "-") → keys \(rgb.map(String.init).joined(separator: " "))")
        }
    }
}
