//
//  Bridge.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The bridge: its state, the keyboard's connection, and HID reports turned into MIDI or REAPER commands.
//  Lights, displays and REAPER handling are in the Bridge+*.swift extensions.

import Foundation
import IOKit
import IOKit.hid

// MARK: - Bridge

final class Bridge {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    let cfg: Config
    let midi: MIDIPorts
    let verbose: Bool
    var clock: () -> String = { Bridge.timeFormatter.string(from: Date()) }

    var device: IOHIDDevice?
    var prev: [UInt8]?
    var pressChannel: [Int: Int] = [:]  // button bit -> channel its press went out on
    var knobAccum = [Int](repeating: 0, count: 8)
    var absValues: [Int: Int] = [:]     // channel * 128 + cc -> current absolute value
    var lastInit = Date.distantPast
    var rootPowerPort: io_connect_t = 0

    let buttonByCC: [Int: Int]          // cc -> button bit, for DAW feedback
    var held = Set<Int>()               // button bits currently down
    var lightState: [Int: Int] = [:]    // channel * 32 + bit -> last value the DAW sent
    var lightsSent: [UInt8]?
    var lightFlushPending = false

    let displays = Displays()
    var displaySent: [[UInt8]?] = [nil, nil, nil]
    var displayFlushPending = false
    var lastDisplayFlush = Date.distantPast
    var displayFailed = false
    var forcedRefreshPending = false
    var overlay: TrackOverlay?
    var message: (label: String, top: String, bottom: String, extra: String, until: Date)?  // a short notice
    var loggedTrack = ""
    var immediate = false               // replay: draw at once instead of on the run loop
    var onDisplayFrame: (([String]) -> Void)?

    var reaper: ReaperSession?
    var logOSC = false                        // --log-osc: print what REAPER sends
    let reaperCommands: [Int: ReaperCommand]       // button bit -> REAPER command (REAPER mode, without Shift)
    let reaperShiftCommands: [Int: ReaperCommand]  // button bit -> REAPER command while Shift is held
    let kkButtonCCs: [Int: Int]                    // button bit -> CC in the Komplete Kontrol view
    var pressCC: [Int: Int] = [:]                  // button bit -> CC its press sent, when not its usual one
    var reaperHeld: [Int: ReaperCommand] = [:]     // buttons whose press went to REAPER, and the command it ran

    var devicePID = 0                              // the connected model, for its key count
    var trackColor: (red: Int, green: Int, blue: Int)?  // the selected REAPER track's colour (0-127 each), from the script
    var lightGuideSent: [UInt8]?                   // the last light guide report, to skip repeats

    init(cfg: Config, midi: MIDIPorts, verbose: Bool) {
        self.cfg = cfg
        self.midi = midi
        self.verbose = verbose
        var byCC: [Int: Int] = [:]
        for d in buttonDefs { if let cc = cfg.buttons[d.name] ?? nil { byCC[cc] = d.bit } }
        buttonByCC = byCC
        func commands(_ map: [String: String?]) -> [Int: ReaperCommand] {
            guard cfg.reaper.enabled else { return [:] }
            var out: [Int: ReaperCommand] = [:]
            for d in buttonDefs { if let s = map[d.name] ?? nil, let c = ReaperCommand(s) { out[d.bit] = c } }
            return out
        }
        reaperCommands = commands(cfg.reaper.buttons)
        reaperShiftCommands = commands(cfg.reaper.shiftButtons)
        var kkCCs: [Int: Int] = [:]
        if cfg.reaper.enabled {
            for d in buttonDefs { if let cc = cfg.reaper.kompleteKontrol.buttons[d.name] ?? nil { kkCCs[d.bit] = cc } }
        }
        kkButtonCCs = kkCCs
    }

    func log(_ s: String) { print("\(clock()) \(s)") }

    func sendCC(_ channel: Int, _ cc: Int, _ value: Int, _ what: String) {
        midi.send(0xB0 | UInt8(channel - 1), UInt8(cc), UInt8(value))
        if verbose { log(what.padding(toLength: 24, withPad: " ", startingAt: 0) + "CC\(cc) ch\(channel) = \(value)") }
    }

    // MARK: device lifecycle

    func attached(_ dev: IOHIDDevice) {
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        device = dev
        devicePID = pid
        lightGuideSent = nil
        prev = nil
        pressChannel = [:]
        pressCC = [:]
        reaperHeld = [:]
        held = []
        lightsSent = nil
        displaySent = [nil, nil, nil]
        displayFailed = false
        knobAccum = Array(repeating: 0, count: 8)
        log("connected: Komplete Kontrol \(mk1Models[pid] ?? String(format: "0x%04x", pid))")
        lastInit = .distantPast
        sendInit(reason: "connect")
    }

    func removed(_ dev: IOHIDDevice) {
        guard let d = device, CFEqual(d, dev) else { return }
        releaseHeld()
        device = nil
        prev = nil
        held = []
        lightsSent = nil
        displaySent = [nil, nil, nil]
        log("disconnected; waiting for the keyboard")
    }

    /// Switch the keyboard to native mode. Rate-limited so a burst of MIDI-mode reports sends it once.
    func sendInit(reason: String) {
        guard let dev = device, Date().timeIntervalSince(lastInit) > 2 else { return }
        lastInit = Date()
        var report: [UInt8] = [reportInit, 0x00, 0x00]  // report ID first, as IOHIDDeviceSetReport expects
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportInit), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("init report failed: 0x\(String(st, radix: 16)) (\(reason))")
            return
        }
        log("native mode on (\(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            sendLights(force: true)
            renderDisplays()
            flushDisplays(force: true)
            lightGuideAfterConnect()
        }
    }

    /// Send "off" for anything still held, so the DAW never sees a stuck button or touch.
    func releaseHeld() {
        for (_, c) in reaperHeld { reaper?.perform(c, down: false) }
        reaperHeld = [:]
        for (bit, ch) in pressChannel {
            if let def = buttonDefs.first(where: { $0.bit == bit }), let cc = pressCC[bit] ?? cfg.buttons[def.name] ?? nil {
                sendCC(ch, cc, 0, "\(def.name) up (released)")
            }
        }
        pressChannel = [:]
        pressCC = [:]
        guard let p = prev else { return }
        if let r = reaper {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) { r.touch(k, false) }
            return
        }
        if cfg.knobTouchCCs.count == 8 {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) {
                sendCC(cfg.channel, cfg.knobTouchCCs[k], 0, "Knob \(k + 1) untouch (released)")
            }
        }
        if let cc = cfg.navigateTouchCC, isSet(p, navigateTouchBit) { sendCC(cfg.channel, cc, 0, "Navigate untouch (released)") }
    }

    // MARK: reports

    func handleReport(_ id: UInt8, _ bytes: [UInt8]) {
        switch id {
        case reportUI where bytes.count >= 38:
            handleUI(bytes)
        case reportPage:
            log("keyboard is in MIDI mode (page report)")
            sendInit(reason: "recovered from MIDI mode")
        default:
            break
        }
    }

    func handleUI(_ b: [UInt8]) {
        var p = prev ?? b
        if prev == nil { for i in 1...5 { p[i] = 0 } }  // first report: buttons start up, positions start where they are
        prev = b
        let shiftHeld = isSet(b, shiftBit)
        let layer = (shiftHeld ? cfg.shiftChannel : nil) ?? cfg.channel
        let toReaper = reaper != nil && !shiftHeld  // without Shift the controls drive REAPER

        for def in buttonDefs {
            let was = isSet(p, def.bit), now = isSet(b, def.bit)
            guard was != now else { continue }
            if def.bit == shiftBit {
                if let cc = cfg.buttons[def.name] ?? nil { sendCC(cfg.channel, cc, now ? 127 : 0, "\(def.name) \(now ? "down" : "up")") }
                if let r = reaper {  // knobs held through the change: touch what they change now (volume or pan)
                    for k in 0..<8 where isSet(p, knobTouchFirstBit + k) && isSet(b, knobTouchFirstBit + k) { r.retouch(k, shift: now) }
                }
            } else if now {
                if let r = reaper, !shiftHeld, r.view == .kk, let cc = kkButtonCCs[def.bit] {
                    let ch = cfg.reaper.kompleteKontrol.channel
                    pressChannel[def.bit] = ch
                    pressCC[def.bit] = cc
                    sendCC(ch, cc, 127, "\(def.name) down (KK)")
                } else if let r = reaper, let command = (shiftHeld ? reaperShiftCommands : reaperCommands)[def.bit] {
                    reaperHeld[def.bit] = command
                    if verbose { log("\(shiftHeld ? "Shift + " : "")\(def.name) down") }
                    if command == .previousPage || command == .nextPage { overlay = nil }  // show the new page at once
                    r.perform(command, down: true)
                } else if let cc = cfg.buttons[def.name] ?? nil {
                    pressChannel[def.bit] = layer
                    sendCC(layer, cc, 127, "\(def.name) down")
                }
            } else if let command = reaperHeld.removeValue(forKey: def.bit) {
                reaper?.perform(command, down: false)
            } else if let cc = pressCC.removeValue(forKey: def.bit) {
                sendCC(pressChannel.removeValue(forKey: def.bit) ?? cfg.channel, cc, 0, "\(def.name) up (KK)")
            } else if let cc = cfg.buttons[def.name] ?? nil {
                sendCC(pressChannel.removeValue(forKey: def.bit) ?? cfg.channel, cc, 0, "\(def.name) up")
            }
        }
        let nowHeld = Set(buttonDefs.map(\.bit).filter { isSet(b, $0) })
        if nowHeld != held {
            held = nowHeld
            scheduleLights()
            refreshDisplaysSoon()
        }

        // Knob and Navigate touch: CCs in plain mode. In REAPER mode a knob touch shows the full name and
        // value, and tells REAPER the fader is touched (for touch automation).
        if let r = reaper {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) != isSet(b, knobTouchFirstBit + k) {
                let now = isSet(b, knobTouchFirstBit + k)
                if now { overlay = nil }  // touching a knob ends the track name display
                r.touch(k, now, shift: shiftHeld)
            }
        } else {
            if cfg.knobTouchCCs.count == 8 {
                for k in 0..<8 {
                    let bit = knobTouchFirstBit + k
                    let was = isSet(p, bit), now = isSet(b, bit)
                    if was != now { sendCC(cfg.channel, cfg.knobTouchCCs[k], now ? 127 : 0, "Knob \(k + 1) \(now ? "touch" : "untouch")") }
                }
            }
            if let cc = cfg.navigateTouchCC, isSet(p, navigateTouchBit) != isSet(b, navigateTouchBit) {
                let now = isSet(b, navigateTouchBit)
                sendCC(cfg.channel, cc, now ? 127 : 0, "Navigate \(now ? "touch" : "untouch")")
            }
        }

        let a = Int(p[6] & 0x0f), c = Int(b[6] & 0x0f)
        if a != c {
            var d = c - a
            if d > 8 { d -= 16 } else if d < -8 { d += 16 }
            if toReaper, let r = reaper, let target = cfg.reaper.navigateTurn {
                if verbose { log("Navigate turn \(d > 0 ? "+" : "")\(d)") }
                if target == "pages" { overlay = nil }
                r.navigate(target, steps: d)
            } else if let cc = cfg.navigateTurnCC {
                turn(channel: layer, cc: cc, steps: d, mode: cfg.navigateTurnMode, what: "Navigate turn")
            }
        }

        for k in 0..<8 {
            let o = 7 + 2 * k
            let a = Int(p[o]) | Int(p[o + 1]) << 8, c = Int(b[o]) | Int(b[o + 1]) << 8
            guard a != c else { continue }
            var d = c - a
            if d > 500 { d -= 1000 } else if d < -500 { d += 1000 }  // positions wrap at 0-999
            if let r = reaper, shiftHeld {  // mix view: the track's pan; track view: back to centre / 0 dB, monitoring
                switch r.target(k) {
                case .bankVolume?:
                    r.turn(k, raw: d, shift: true)
                    continue
                case .pan?:
                    if r.centerPan(), verbose { log("Shift + pan knob: pan centred") }
                    continue
                case .volume?:
                    if r.resetVolume(k), verbose { log("Shift + volume knob \(k + 1): 0 dB") }
                    continue
                case .recArm?:
                    r.turnMonitor(k, raw: d)
                    continue
                default:
                    break
                }
            }
            // Komplete Kontrol view: the knob's CC. Like Novation's Launchkey, the bridge keeps one set of 8 knob
            // values (absValues) for all pages, tracks and presets: KK's page count and parameter values aren't
            // available to it, so it doesn't follow pages.
            if toReaper, let r = reaper, r.view == .kk {
                let kk = cfg.reaper.kompleteKontrol
                knobAccum[k] += d
                let steps = knobAccum[k] / cfg.knobStepsPerCC
                guard steps != 0 else { continue }
                knobAccum[k] -= steps * cfg.knobStepsPerCC
                turn(channel: kk.channel, cc: kk.encoderCCs[k], steps: steps, mode: kk.encoderMode, what: "Knob \(k + 1) turn (KK)")
                continue
            }
            if toReaper, let r = reaper {
                r.turn(k, raw: d)
                continue
            }
            knobAccum[k] += d
            let steps = knobAccum[k] / cfg.knobStepsPerCC
            guard steps != 0 else { continue }
            knobAccum[k] -= steps * cfg.knobStepsPerCC
            turn(channel: layer, cc: cfg.knobCCs[k], steps: steps, mode: cfg.knobMode, what: "Knob \(k + 1) turn")
        }
        scheduleDisplays()
    }

    func turn(channel: Int, cc: Int, steps: Int, mode: TurnMode, what: String) {
        let s = max(-63, min(63, steps))
        let value: Int
        switch mode {
        case .absolute:
            let key = channel * 128 + cc
            let old = absValues[key] ?? 64
            let new = max(0, min(127, old + steps))
            guard new != old else { return }
            absValues[key] = new
            value = new
        case .relativeBinaryOffset: value = 64 + s
        case .relativeTwosComplement: value = s >= 0 ? s : 128 + s
        case .relativeSignedBit: value = s >= 0 ? s : 64 - s
        }
        sendCC(channel, cc, value, "\(what) \(steps > 0 ? "+" : "")\(steps)")
    }
}
