//
//  main.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The entry point: the command line, replay mode, and startup (the USB device watcher, sleep/wake and
//  Ctrl-C handling), and the restart in place when the config file changes.
//
//  PrimoKKMK1Bridge — every control on a Komplete Kontrol S-series MK1, as MIDI on a virtual port, with an
//  optional link to REAPER over OSC (macOS).
//
//  The keyboard's own MIDI port keeps sending keys, pitch strip and mod strip. PrimoKKMK1Bridge switches the
//  keyboard into native (host) mode with HID output report a0 00 00 (the init that NI's software and
//  DrivenByMoss send), then turns the HID button, knob, touch and Navigate-knob reports into MIDI CCs
//  on a virtual source ("Primo Komplete Kontrol MK1" by default).
//
//  Button lights: in native mode the computer drives them (HID output report 0x80). PrimoKKMK1Bridge keeps
//  mapped buttons dimly lit, lights a button fully while it is held, and lets the DAW switch lights on
//  and off by sending the button's CC back to the virtual destination of the same name (value > 0 = lit).
//  Knob CCs sent back to that destination also update PrimoKKMK1Bridge's absolute knob values, so a knob picks
//  up from the DAW's value instead of jumping.
//
//  Displays: the nine 8-character displays (HID output report 0xE0; one left of knob 1, one above each
//  knob) show what the knobs control: CC numbers and values, or in REAPER mode track names and values.
//
//  REAPER mode ("reaper": {"enabled": true}) talks to a REAPER OSC control surface. Mix view: the knobs are
//  the volumes of 8 tracks at a time, and the page buttons scroll through the project's tracks. Track view
//  (Instance switches): the knobs are the selected track's volume, pan, mute, solo and sends, and turning the
//  Navigate knob picks the track (from mix view, it switches to track view). Transport buttons drive REAPER's
//  transport. With Shift held, buttons and knobs send MIDI CCs on the Shift channel as in plain mode, apart
//  from the Shift shortcuts in reaper.shiftButtons, the tracks' pans in mix view, and the volume/pan resets in
//  track view. Buttons with no REAPER command send their CCs.
//
//    bridge/build.sh   (stamps the version into build/Version.swift and compiles it in)
//    build/PrimoKKMK1Bridge [--config FILE] [--verbose]
//    build/PrimoKKMK1Bridge --print-default-config
//    build/PrimoKKMK1Bridge --replay device/tests/native_knobs_results/capture_mapping.log [--config ...]
//
//  The config: ~/Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/PrimoKKMK1Bridge.json, created with every
//  default the first time the bridge runs, unless --config names another file.
//    build/PrimoKKMK1Bridge --show-font
//    build/PrimoKKMK1Bridge --version
//
//  Native mode is not persistent: replugging returns the keyboard to MIDI mode. After PrimoKKMK1Bridge quits,
//  the keyboard stays in native mode (knobs silent on its own MIDI port) until it is replugged.
//  Protocol details: doc/NOTES.md.
//
//  Source files: main.swift (command line, startup), Hardware, Displays, OSC, ReaperModel, ReaperSession,
//  Config, MIDIPorts, and Bridge with its Bridge+Lights, Bridge+Displays and Bridge+Reaper extensions.

import CoreMIDI
import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Main

let usage = """
    usage: PrimoKKMK1Bridge [--config FILE] [--verbose] [--log-osc]
             (without --config: ~/Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/PrimoKKMK1Bridge.json,
              created with the defaults if it isn't there)
           PrimoKKMK1Bridge --print-default-config
           PrimoKKMK1Bridge --replay CAPTURE_LOG [--config FILE] [--log-osc]
           PrimoKKMK1Bridge --show-font
           PrimoKKMK1Bridge --version
    """

var args = Array(CommandLine.arguments.dropFirst())
func takeFlag(_ names: String...) -> Bool {
    guard let i = args.firstIndex(where: { names.contains($0) }) else { return false }
    args.remove(at: i)
    return true
}
func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if takeFlag("-h", "--help") { print(usage); exit(0) }
if takeFlag("--version") { print("PrimoKKMK1Bridge \(appVersionString)"); exit(0) }
let printDefault = takeFlag("--print-default-config")
let fontTest = takeFlag("--show-font")
let verboseFlag = takeFlag("-v", "--verbose")
let logOSC = takeFlag("--log-osc")
let configPath = takeValue("--config")
let replayPath = takeValue("--replay")
guard args.isEmpty else { fail("unknown argument(s): \(args.joined(separator: " "))\n\(usage)") }

if fontTest { showFont(); exit(0) }

if printDefault {
    print(String(decoding: try! Config.fileEncoder.encode(Config()), as: UTF8.self))
    exit(0)
}

// The config file: --config FILE, else (when running, not replaying) the default one in
// ~/Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/, created with every default the first time.
// A replay without --config uses the defaults and touches no file.
let configFile: String? = configPath ?? (replayPath == nil ? Config.defaultURL.path : nil)
if configPath == nil, replayPath == nil {
    do {
        if try Config.createDefaultFileIfMissing() { print("created \(Config.defaultURL.path) with the default settings") }
    } catch {
        fail("cannot create \(Config.defaultURL.path): \(error.localizedDescription)")
    }
}

var cfg = Config()
if let path = configFile {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    do { cfg = try JSONDecoder().decode(Config.self, from: data) } catch { fail("\(path): \(error)") }
}
do { try cfg.validate() } catch { fail("config: \(error)") }
for w in cfg.duplicateWarnings() { print("warning: \(w)") }
// Verbose logging: --verbose, or "verbose": true in the config (the editor's Settings ▸ Logging). A config change
// restarts the bridge in place, so turning it on or off there applies as soon as it's saved.
let verbose = verboseFlag || cfg.verbose

func ranges(_ v: [Int]) -> String {
    guard let f = v.first, let l = v.last else { return "off" }
    return v == Array(f...l) && v.count > 1 ? "CC\(f)-\(l)" : v.map { "CC\($0)" }.joined(separator: ",")
}

// Replay a capture log from tools/kkmap through the mapping, without a keyboard or MIDI port. With REAPER
// mode on, the OSC link is live (point it at tools/fake_reaper.py), and display frames are printed.
if let path = replayPath {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let bridge = Bridge(cfg: cfg, midi: MIDIPorts(name: cfg.portName, dryRun: true), verbose: true)
    bridge.learnedPagesURL = cfg.reaper.kompleteKontrol.nksPagesFile.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    bridge.learnedPagesWritable = false
    bridge.nksLookupEnabled = false
    var stamp = "start"
    bridge.clock = { stamp }
    bridge.immediate = true
    bridge.logOSC = logOSC
    bridge.onDisplayFrame = { lines in for l in lines { print("             display |" + l + "|") } }
    func spin(_ seconds: Double) { _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false) }
    if cfg.reaper.enabled {
        bridge.startReaper(failOnError: true)
        spin(0.5)
    }
    var count = 0
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ")
        if f.count > 2, f[1] == "SYSEX" {  // what the REAPER script sends the MIDI destination (track colour, instrument)
            stamp = String(f[0])
            bridge.sysEx(f[2...].compactMap { UInt8($0, radix: 16) })
            if bridge.reaper != nil { spin(0.01) }
            continue
        }
        if f.count > 2, f[1] == "OSC", let r = bridge.reaper {  // as if REAPER sent it: `/address "text" 0.5 ...`
            stamp = String(f[0])
            let rest = line.split(separator: " ", maxSplits: 3).dropFirst(3).first.map(String.init) ?? ""
            let args = rest.matches(of: #/"([^"]*)"|(\S+)/#).map { m in
                m.output.1.map { OSCArg.string(String($0)) } ?? .float(Float(m.output.2 ?? "") ?? 0)
            }
            r.received(String(f[2]), args)  // no spin: REAPER sends a touch's messages together
            continue
        }
        guard f.count > 3, f[1] == "HID", f[2].hasPrefix("0x"), let id = UInt8(f[2].dropFirst(2), radix: 16) else { continue }
        stamp = String(f[0])
        bridge.handleReport(id, f[3...].compactMap { UInt8($0, radix: 16) })
        count += 1
        if bridge.reaper != nil { spin(0.01) }
    }
    if bridge.reaper != nil {
        stamp = "end"
        spin(0.5)
    }
    print("replayed \(count) HID reports from \(path)")
    exit(0)
}

let midi = MIDIPorts(name: cfg.portName, dryRun: false, keysSource: cfg.keyboardSource)
let bridge = Bridge(cfg: cfg, midi: midi, verbose: verbose)
bridge.logOSC = logOSC
// Learned NKS pages: reaper.kompleteKontrol.nksPagesFile, else NKSPages.json next to the config file.
bridge.learnedPagesURL = cfg.reaper.kompleteKontrol.nksPagesFile.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? URL(fileURLWithPath: configFile ?? Config.defaultURL.path).deletingLastPathComponent().appendingPathComponent("NKSPages.json")
midi.onControlChange = { bridge.feedback(channel: $0, cc: $1, value: $2) }
midi.onSysEx = { bridge.sysEx($0) }
let ctx = Unmanaged.passUnretained(bridge).toOpaque()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, mk1Models.keys.sorted().map {
    [kIOHIDVendorIDKey: niVendorID, kIOHIDProductIDKey: $0, kIOHIDPrimaryUsagePageKey: 0xff01] as CFDictionary
} as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue().attached(dev)
}, ctx)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
}, ctx)
IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, _, _, rid, report, len in
    guard result == kIOReturnSuccess else { return }
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue()
        .handleReport(UInt8(truncatingIfNeeded: rid), Array(UnsafeBufferPointer(start: report, count: len)))
}, ctx)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openStatus != kIOReturnSuccess { bridge.log("HID manager open returned 0x\(String(openStatus, radix: 16))") }

// Re-send the init after sleep: the keyboard may come back from USB suspend in MIDI mode.
var powerNotifyPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
bridge.rootPowerPort = IORegisterForSystemPower(ctx, &powerNotifyPort, { ctx, _, messageType, messageArgument in
    let b = Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue()
    switch messageType {
    case 0xE000_0270, 0xE000_0280:  // kIOMessageCanSystemSleep, kIOMessageSystemWillSleep
        IOAllowPowerChange(b.rootPowerPort, Int(bitPattern: messageArgument))
    case 0xE000_0300:  // kIOMessageSystemHasPoweredOn
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            b.lastInit = .distantPast
            b.sendInit(reason: "wake")
        }
    default:
        break
    }
}, &powerNotifier)
if bridge.rootPowerPort != 0, let port = powerNotifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        bridge.releaseHeld()
        bridge.sendLights(force: true, allOff: true)
        bridge.blankDisplays()
        bridge.sendLightGuide(off: true)
        print("\nPrimoKKMK1Bridge stopped. The keyboard stays in native mode (knobs send no MIDI) until you replug it.")
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

print("PrimoKKMK1Bridge \(appVersionString): Komplete Kontrol MK1 → virtual MIDI port \"\(cfg.portName)\"")
print("  buttons on ch\(cfg.channel)" + (cfg.shiftChannel.map { " (ch\($0) while Shift is \(cfg.shiftLatch ? "latched" : "held"))" } ?? "")
      + ", knobs \(ranges(cfg.knobCCs)) \(cfg.knobMode.rawValue), knob touch \(ranges(cfg.knobTouchCCs))")
print("  Navigate turn \(cfg.navigateTurnCC.map { "CC\($0) \(cfg.navigateTurnMode.rawValue)" } ?? "off")"
      + ", Navigate touch \(cfg.navigateTouchCC.map { "CC\($0)" } ?? "off")")
if cfg.lights {
    print("  lights: idle \(cfg.lightIdleBrightness), lit \(cfg.lightBrightness)"
          + (midi.feedbackAvailable ? "; the DAW can light a button by sending its CC to the \"\(cfg.portName)\" output" : ""))
} else {
    print("  lights: off")
}
print("  displays: \(cfg.displays ? "on" : "off")")
if verbose { print("  verbose logging: on" + (verboseFlag ? " (--verbose)" : " (verbose in the config)")) }
if cfg.keyboardSource != nil {
    midi.onKeysChanged = { names in
        bridge.log(names.isEmpty ? "keys: no keyboard MIDI port found to merge yet"
                                 : "keys: merging \(names.map { "\"\($0)\"" }.joined(separator: ", ")) into \"\(cfg.portName)\"")
    }
    midi.connectKeys(report: true)
} else {
    print("  keys: not merged (keyboardSource is null); they stay on the keyboard's own MIDI port")
}
if cfg.reaper.enabled {
    let r = cfg.reaper
    print("  REAPER: OSC to \(r.host):\(r.sendPort), listening on port \(r.receivePort); starts in \(r.view) view"
          + " (Instance: mix -> track -> komplete-kontrol). Hold Shift for the MIDI CC layer, and in mix view to"
          + " turn the tracks' pans.")
    bridge.startReaper()
}

// Restart with the new settings whenever the config file changes (the editor saves it, or a text editor does).
// A restart re-runs this program in place (same process, same terminal) with the same arguments.
var configWatcher: DispatchSourceTimer?
if let path = configFile {
    let loaded = FileManager.default.contents(atPath: path)
    var rejected: Data?
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler {
        guard let data = FileManager.default.contents(atPath: path), data != loaded, data != rejected else { return }
        do {
            try JSONDecoder().decode(Config.self, from: data).validate()
        } catch {
            rejected = data
            bridge.log("config: \(path) changed but can't be used (\(error)); keeping the current settings")
            return
        }
        bridge.log("config: \(path) changed; restarting with the new settings")
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        midi.close()
        fflush(stdout)
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) } + [nil]
        execv(exe, &argv)
        fail("could not restart (errno \(errno)); start PrimoKKMK1Bridge again by hand")
    }
    timer.resume()
    configWatcher = timer
    print("  config: \(path) (saved changes apply automatically)")
}
print("  waiting for the keyboard… (Ctrl-C to quit)")
CFRunLoopRun()
