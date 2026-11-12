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
//
//  When that script is installed (REAPER's Scripts/__startup.lua starts it), the light guide also shows the bridge's
//  own state (issue #15): a rainbow runs up the keys when the keyboard connects, the keys are purple while the bridge
//  waits for REAPER, and red while the OSC link to REAPER can't start.

import Foundation
import IOKit.hid

extension Bridge {
    /// Whether the light guide shows track colours: REAPER mode with reaper.lightGuide on.
    var lightGuideInUse: Bool { cfg.reaper.enabled && cfg.reaper.lightGuide }

    /// Whether the script that sends the colours is set up to start with REAPER: its line in Scripts/__startup.lua
    /// (put there by the editor's Install…, or by hand). Read again at most every 2 seconds.
    var lightGuideScriptInstalled: Bool {
        if let c = scriptCheck, Date().timeIntervalSince(c.at) < 2 { return c.installed }
        let path = (cfg.reaper.resourcePath as NSString).expandingTildeInPath + "/Scripts/__startup.lua"
        let installed = (try? String(contentsOfFile: path, encoding: .utf8))?.contains("PrimoKKMK1Bridge_TrackColor.lua") ?? false
        scriptCheck = (Date(), installed)
        return installed
    }

    func sysEx(_ m: [UInt8]) {
        guard m.count >= 6, m[0] == 0xF0, m[1] == 0x7D, m[2] == 0x50, m[3] == 0x4B else { return }
        switch m[4] {
        case 0x01 where m.count >= 9: trackColor = (Int(m[5] & 0x7F), Int(m[6] & 0x7F), Int(m[7] & 0x7F))
        case 0x02: trackColor = nil
        default: return
        }
        sendLightGuide()
    }

    /// What the light guide shows now, in REAPER colour values (0-127 each; nil = off), and what that is, for the log.
    func lightGuideState() -> (colour: (red: Int, green: Int, blue: Int)?, what: String) {
        guard lightGuideInUse else { return (nil, "off") }
        if lightGuideScriptInstalled {
            if reaperError != nil { return ((127, 0, 0), "red, the OSC link to REAPER can't start") }
            if !(reaper?.connected ?? false) { return ((64, 0, 127), "purple, waiting for REAPER") }
        }
        guard let c = trackColor else { return (nil, "off") }
        return (c, "track colour \(c.red) \(c.green) \(c.blue)")
    }

    /// After connecting: clear the light guide if it's not in use. In use, with the script installed, play the
    /// startup animation when the keyboard has just connected (not after a wake or a MIDI-mode recovery); otherwise
    /// show the current state. Without anything to show, it keeps what it showed (after a restart for a config change,
    /// the keys stay lit) until the script's next message, at most 2 seconds away.
    func lightGuideAfterConnect(animate: Bool) {
        if !lightGuideInUse {
            sendLightGuide(off: true)
        } else if animate && lightGuideScriptInstalled {
            animateLightGuide()
        } else if lightGuideState().colour != nil {
            sendLightGuide()
        }
    }

    /// Every key in the current state's colour (see lightGuideState), or off. Waits while the startup animation runs:
    /// it ends in the current state.
    func sendLightGuide(off: Bool = false) {
        if off {
            lightGuideAnimation?.cancel()
            lightGuideAnimation = nil
        } else if lightGuideAnimation != nil {
            return
        }
        guard device != nil else { return }
        var rgb: [Double] = [0, 0, 0]
        var what = "off"
        if !off {
            let state = lightGuideState()
            what = state.what
            if let c = state.colour { rgb = [Double(c.red), Double(c.green), Double(c.blue)] }
        }
        if writeLightGuide(Array(repeating: rgb, count: mk1KeyCount[devicePID] ?? 61)), verbose {
            log("light guide: \(what)")
        }
    }

    /// The startup animation, about 1.2 seconds: a rainbow runs up the keys from the lowest, then fades into the
    /// current state (purple while waiting for REAPER, the track colour, red, or off).
    func animateLightGuide() {
        lightGuideAnimation?.cancel()
        if verbose { log("light guide: startup animation") }
        let keys = mk1KeyCount[devicePID] ?? 61
        let fill = 0.7, fade = 0.5, front = 3.0, start = Date()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.025)
        timer.setEventHandler { [weak self] in
            guard let self, self.device != nil else {
                timer.cancel()
                self?.lightGuideAnimation = nil
                return
            }
            let t = Date().timeIntervalSince(start)
            guard t < fill + fade else {
                timer.cancel()
                self.lightGuideAnimation = nil
                self.sendLightGuide()
                return
            }
            let target: [Double] = self.lightGuideState().colour.map { [Double($0.red), Double($0.green), Double($0.blue)] } ?? [0, 0, 0]
            let mix = max(0, (t - fill) / fade)  // 0 while the rainbow runs up, then to 1 at the end
            let frame: [[Double]] = (0..<keys).map { k in
                // The wave's front reaches the top key just as the fill ends; it's `front` keys wide, so it's soft.
                let past = t * (Double(keys) + front) / fill - Double(k)
                let on = max(0, min(1, past / front))
                let hue = 0.83 * Double(k) / Double(max(1, keys - 1))  // red at the bottom to violet at the top
                let lit = rainbow(hue)
                return (0..<3).map { (i: Int) -> Double in lit[i] * 127 * on * (1 - mix) + target[i] * mix }
            }
            self.writeLightGuide(frame)
        }
        lightGuideAnimation = timer
        timer.resume()
    }

    /// Send one colour per key (REAPER colour values, 0-127 each), white-balanced and at reaper.lightGuideBrightness.
    /// False if nothing was sent: the same as last time, no keyboard, or the report failed.
    @discardableResult
    func writeLightGuide(_ keys: [[Double]]) -> Bool {
        guard let dev = device else { return false }
        let level = Double(cfg.reaper.lightGuideBrightness) / 100
        let wb = [lightGuideWhiteBalance.red, lightGuideWhiteBalance.green, lightGuideWhiteBalance.blue]
        let payload = keys.flatMap { rgb in (0..<3).map { UInt8(max(0, min(127, (rgb[$0] * wb[$0] * level).rounded()))) } }
        guard payload != lightGuideSent else { return false }
        var report: [UInt8] = [reportLightGuide] + payload  // report ID first, as IOHIDDeviceSetReport expects
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportLightGuide), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("light guide report failed: 0x\(String(st, radix: 16))")
            return false
        }
        lightGuideSent = payload
        return true
    }
}

/// A fully saturated, full-brightness colour for a hue from 0 (red) through 1/3 (green) and 2/3 (blue): red, green
/// and blue, 0-1 each.
func rainbow(_ hue: Double) -> [Double] {
    let h = (hue - hue.rounded(.down)) * 6
    let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
    switch Int(h) {
    case 0: return [1, x, 0]
    case 1: return [x, 1, 0]
    case 2: return [0, 1, x]
    case 3: return [0, x, 1]
    case 4: return [x, 0, 1]
    default: return [1, 0, x]
    }
}
