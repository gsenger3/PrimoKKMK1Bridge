//
//  Bridge+Lights.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The button lights (HID output report 0x80): brightness per button and view, and DAW feedback.

import Foundation
import IOKit.hid

extension Bridge {
    // MARK: button lights

    func lightLevel(_ def: ButtonDef, shiftHeld: Bool) -> UInt8 {
        // The button lights are single-colour, so Instance shows the view by brightness: mix off, track
        // half-way, Komplete Kontrol full.
        if let r = reaper, !shiftHeld, reaperCommands[def.bit] == .toggleView {
            switch r.view {
            case .mix: return 0
            case .track: return UInt8(cfg.lightBrightness / 4)
            case .kk: return UInt8(cfg.lightBrightness)
            }
        }
        if let r = reaper, !shiftHeld, r.view == .kk, kkButtonCCs[def.bit] != nil {
            return UInt8(held.contains(def.bit) ? cfg.lightBrightness : cfg.lightIdleBrightness)
        }
        if let r = reaper, let command = (shiftHeld ? reaperShiftCommands : reaperCommands)[def.bit] {
            return UInt8(held.contains(def.bit) || r.isActive(command) ? cfg.lightBrightness : cfg.lightIdleBrightness)
        }
        guard (cfg.buttons[def.name] ?? nil) != nil else { return 0 }  // unmapped buttons stay dark
        if held.contains(def.bit) { return UInt8(cfg.lightBrightness) }
        var state = lightState[cfg.channel * 32 + def.bit]
        if shiftHeld, let sc = cfg.shiftChannel, let s = lightState[sc * 32 + def.bit] { state = s }
        return UInt8((state ?? 0) > 0 ? cfg.lightBrightness : cfg.lightIdleBrightness)
    }

    /// Coalesce light changes from one run-loop pass into a single report.
    func scheduleLights() {
        guard cfg.lights, device != nil, !lightFlushPending else { return }
        lightFlushPending = true
        DispatchQueue.main.async { [self] in
            lightFlushPending = false
            sendLights()
        }
    }

    func sendLights(force: Bool = false, allOff: Bool = false) {
        guard cfg.lights, let dev = device else { return }
        let shiftHeld = prev.map { isSet($0, shiftBit) } ?? false
        var report = [UInt8](repeating: 0, count: 1 + lightCount)
        report[0] = reportLights
        if !allOff {
            for def in buttonDefs { if let slot = lightSlot[def.name] { report[1 + slot] = lightLevel(def, shiftHeld: shiftHeld) } }
        }
        guard force || report != lightsSent else { return }
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportLights), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("light report failed: 0x\(String(st, radix: 16))")
            return
        }
        if verbose, let old = lightsSent {
            let changes = buttonDefs.compactMap { d -> String? in
                guard let s = lightSlot[d.name], old[1 + s] != report[1 + s] else { return nil }
                return "\(d.name) \(report[1 + s])"
            }
            if !changes.isEmpty { log("lights: " + changes.joined(separator: ", ")) }
        }
        lightsSent = report
    }

    /// A control change the DAW sent back to the feedback port.
    func feedback(channel: Int, cc: Int, value: Int) {
        guard channel == cfg.channel || channel == cfg.shiftChannel else { return }
        if cfg.knobMode == .absolute, cfg.knobCCs.contains(cc) { absValues[channel * 128 + cc] = value; scheduleDisplays() }
        if cfg.navigateTurnMode == .absolute, cfg.navigateTurnCC == cc { absValues[channel * 128 + cc] = value }
        guard let bit = buttonByCC[cc] else { return }
        lightState[channel * 32 + bit] = value
        if verbose { log("feedback CC\(cc) ch\(channel) = \(value)") }
        scheduleLights()
    }
}
