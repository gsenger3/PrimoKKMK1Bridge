//
//  Config.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The JSON config: every key, its default, and validation.

import Foundation

// MARK: - Config

struct ConfigError: Error, CustomStringConvertible { let description: String }

enum TurnMode: String, Codable {
    case absolute
    case relativeBinaryOffset = "relative-binary-offset"
    case relativeTwosComplement = "relative-twos-complement"
    case relativeSignedBit = "relative-signed-bit"
}

/// The Komplete Kontrol view, in MIDI mode (kompleteKontrolView) and REAPER mode (reaper.kompleteKontrolView): the
/// knobs and navigation buttons send fixed MIDI CCs on the virtual port (an NKS-style assignment like the Novation
/// Launchkey MK4's) for Komplete Kontrol to pick up. Like the Launchkey, the bridge doesn't follow KK's pages or
/// presets: it keeps one set of 8 knob values. In REAPER mode, NKS integration can show and set KK's parameters
/// instead. The config's top-level kompleteKontrol; earlier configs had it as reaper.kompleteKontrol, which still loads.
/// (Configs with the earlier pageButtons, presetButtons or hostParameters keys still load; those are ignored.)
struct KKViewConfig: Codable {
    var channel = 1
    var encoderCCs = Array(21...28)
    var encoderMode = TurnMode.absolute
    var buttons: [String: Int?] = [
        "PresetUp": 37, "PresetDown": 36, "NavUp": 41, "NavDown": 40, "NavLeft": 42, "NavRight": 43,
        "PageLeft": 42, "PageRight": 43,  // the arrows next to the knobs page KK's NKS pages too, like Navigate ◀ / ▶
    ]
    /// NKS integration (REAPER mode only): for an instrument with NKS presets (.nksf), or whose pages were learned
    /// (learn-nks-pages), the knobs set the parameters on Komplete Kontrol's NKS pages through REAPER, and the displays
    /// show their names and values. The REAPER script reports which instrument KK hosts. Off: the knobs send encoderCCs
    /// for KK's MIDI template.
    var nksIntegration = false
    /// With NKS integration, an NKS preset file (.nksf) whose pages to use whatever KK hosts (for tests).
    var nksFile: String?
    /// The learned pages file. Unset: NKSPages.json next to the config file (a replay uses none unless it's set, and
    /// never writes it).
    var nksPagesFile: String?

    enum CodingKeys: String, CodingKey {
        case channel, encoderCCs, encoderMode, buttons, nksIntegration, nksFile, nksPagesFile
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? channel
        encoderCCs = try c.decodeIfPresent([Int].self, forKey: .encoderCCs) ?? encoderCCs
        encoderMode = try c.decodeIfPresent(TurnMode.self, forKey: .encoderMode) ?? encoderMode
        nksIntegration = try c.decodeIfPresent(Bool.self, forKey: .nksIntegration) ?? nksIntegration
        nksFile = try c.decodeIfPresent(String.self, forKey: .nksFile)
        nksPagesFile = try c.decodeIfPresent(String.self, forKey: .nksPagesFile)
        if let user = try c.decodeIfPresent([String: Int?].self, forKey: .buttons) {
            for (name, cc) in user {
                guard name != "Shift", buttonDefs.contains(where: { $0.name == name }) else {
                    throw ConfigError(description: "kompleteKontrol.buttons: unknown button \"\(name)\"")
                }
                buttons.updateValue(cc, forKey: name)
            }
        }
    }

    func validate() throws {
        guard (1...16).contains(channel) else {
            throw ConfigError(description: "kompleteKontrol.channel must be 1-16, got \(channel)")
        }
        guard encoderCCs.count == 8, encoderCCs.allSatisfy({ (0...127).contains($0) }) else {
            throw ConfigError(description: "kompleteKontrol.encoderCCs needs 8 CCs, each 0-127")
        }
        for (name, cc) in buttons {
            if let cc, !(0...127).contains(cc) {
                throw ConfigError(description: "kompleteKontrol.buttons.\(name) must be 0-127, got \(cc)")
            }
        }
    }
}

/// The knobs' CCs on each knob page, in MIDI mode (knobPages) and REAPER mode's MIDI view (reaper.midiView.pages).
/// Only MIDI 1.0's undefined controllers (3, 9, 14-31, 85-90, 102-119) and its general-purpose ones (16-19, 80-83),
/// so nothing a synth already responds to (modulation, volume, pan, expression, sustain, data entry, channel
/// mode...), less the MIDI view's default button CCs (85-89, 119): 40 CCs, in pages of 8 (3 and 9 are left over).
/// The knobs send them on a channel of their own (3 by default), where nothing else the bridge sends meets them: the
/// buttons, knob touch, the Navigate knob, the Komplete Kontrol view, Shift and the Octave buttons all use channel 1.
let knobPageCCs: [[Int]] = [Array(14...21), Array(22...29), Array(102...109), Array(110...117),
                            [30, 31, 80, 81, 82, 83, 90, 118]]

/// REAPER mode's MIDI view (issue #5): like the Komplete Kontrol view, but the knobs and the buttons given a CC here
/// send generic MIDI CCs, for anything that learns CCs. The other buttons keep their REAPER commands. Off by default;
/// Instance reaches it in place of the Komplete Kontrol view (Shift + Play swaps the two). The knobs have `pages`
/// pages of CCs (knobPageCCs), which Page ◀ / ▶ go through.
struct MIDIViewConfig: Codable {

    var enabled = false
    var channel = 3
    var pages = 1  // 1 to knobPageCCs.count
    var knobMode = TurnMode.absolute
    var buttons: [String: Int?] = [  // Page ◀ / ▶ page the knobs instead
        "PresetUp": 119, "PresetDown": 85, "NavUp": 86, "NavDown": 87, "NavLeft": 88, "NavRight": 89,
    ]

    enum CodingKeys: String, CodingKey { case enabled, channel, pages, knobMode, buttons }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? channel
        pages = try c.decodeIfPresent(Int.self, forKey: .pages) ?? pages
        knobMode = try c.decodeIfPresent(TurnMode.self, forKey: .knobMode) ?? knobMode
        if let user = try c.decodeIfPresent([String: Int?].self, forKey: .buttons) {
            for (name, cc) in user where name != "PageLeft" && name != "PageRight" {  // those page the knobs
                guard name != "Shift", buttonDefs.contains(where: { $0.name == name }) else {
                    throw ConfigError(description: "reaper.midiView.buttons: unknown button \"\(name)\"")
                }
                buttons.updateValue(cc, forKey: name)
            }
        }
    }

    func validate() throws {
        guard (1...16).contains(channel) else { throw ConfigError(description: "reaper.midiView.channel must be 1-16, got \(channel)") }
        guard (1...knobPageCCs.count).contains(pages) else {
            throw ConfigError(description: "reaper.midiView.pages must be 1-\(knobPageCCs.count), got \(pages)")
        }
        for (name, cc) in buttons {
            if let cc, !(0...127).contains(cc) {
                throw ConfigError(description: "reaper.midiView.buttons.\(name) must be 0-127, got \(cc)")
            }
        }
    }
}

struct ReaperConfig: Codable {
    var enabled = false
    var host = "127.0.0.1"
    var sendPort = 8000     // REAPER's "Local listen port"
    var receivePort = 9000  // REAPER's "Device port"
    var view = "mix"
    var followSelectedTrack = true
    var knobFullRange = 600
    var navigateTurn: String? = "tracks"
    var trackNameSeconds = 2.0  // after a track change, how long only its number and name show
    var mirrorSelection = true  // track and KK views: a track picked on the keyboard becomes REAPER's selected track
    var resourcePath = "~/Library/Application Support/REAPER"  // where REAPER keeps reaper-screensets.ini
    var lightGuide = true          // show the selected track's colour on the keys (sent by reaper/PrimoKKMK1Bridge_TrackColor.lua)
    var lightGuideBrightness = 50  // percent
    var kompleteKontrolView = true  // the Komplete Kontrol view (its settings: the top-level kompleteKontrol)
    var midiView = MIDIViewConfig()
    /// reaper.kompleteKontrol, from a config written before it moved to the top level (read, never written).
    private(set) var earlierKompleteKontrol: KKViewConfig?
    var buttons: [String: String?] = [
        "Play": "play", "Stop": "stop", "Rec": "record", "Loop": "repeat", "Rewind": "rewind", "FastForward": "forward",
        "NavUp": "action:1012", "NavDown": "action:1011",  // under the big knob: View: Zoom in / out horizontal
        "NavLeft": "action:40104", "NavRight": "action:40105",  // View: Move cursor left / right one pixel
        "PageLeft": "previous-page", "PageRight": "next-page", "Instance": "toggle-view", "Back": "undo",
        "Browse": "browse-fx", "NavigateClick": "panic", "Enter": "save-project",
        "PresetUp": "screenset:1", "PresetDown": "screenset:2",
        "Scale": "action:40400",  // Automation: Set track automation mode to trim/read
        "Arp": "action:40403",    // Automation: Set track automation mode to write
    ]
    /// Commands for buttons pressed while Shift is held; other Shift + button presses send their CC on the Shift channel.
    var shiftButtons: [String: String?] = [
        "Rec": "metronome", "Stop": "go-to-start", "Rewind": "previous-marker", "FastForward": "next-marker",
        "Loop": "record-mode", "Back": "redo", "Browse": "close-fx", "Enter": "render-project",
        "Instance": "learn-nks-pages",  // Komplete Kontrol view with NKS integration
        "Scale": "action:40401",  // Automation: Set track automation mode to read
        "Arp": "action:40402",    // Automation: Set track automation mode to touch
        "Play": "switch-kk-midi-view",  // which of the two Instance reaches; MIDI step input (midiaction:40481) is free
        "NavUp": "action:40111", "NavDown": "action:40112",  // View: Zoom in / out vertical
        "NavLeft": "action:40646", "NavRight": "action:40647",  // View: Move cursor left / right to grid division
    ]

    enum CodingKeys: String, CodingKey {
        case enabled, host, sendPort, receivePort, view, followSelectedTrack, knobFullRange, navigateTurn, buttons
        case shiftButtons, trackNameSeconds, mirrorSelection, resourcePath, kompleteKontrolView, midiView
        case lightGuide, lightGuideBrightness
        case kompleteKontrol  // read only, from earlier configs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(host, forKey: .host)
        try c.encode(sendPort, forKey: .sendPort)
        try c.encode(receivePort, forKey: .receivePort)
        try c.encode(view, forKey: .view)
        try c.encode(followSelectedTrack, forKey: .followSelectedTrack)
        try c.encode(knobFullRange, forKey: .knobFullRange)
        try c.encode(navigateTurn, forKey: .navigateTurn)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(shiftButtons, forKey: .shiftButtons)
        try c.encode(trackNameSeconds, forKey: .trackNameSeconds)
        try c.encode(mirrorSelection, forKey: .mirrorSelection)
        try c.encode(resourcePath, forKey: .resourcePath)
        try c.encode(kompleteKontrolView, forKey: .kompleteKontrolView)
        try c.encode(midiView, forKey: .midiView)
        try c.encode(lightGuide, forKey: .lightGuide)
        try c.encode(lightGuideBrightness, forKey: .lightGuideBrightness)
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? host
        sendPort = try c.decodeIfPresent(Int.self, forKey: .sendPort) ?? sendPort
        receivePort = try c.decodeIfPresent(Int.self, forKey: .receivePort) ?? receivePort
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? view
        followSelectedTrack = try c.decodeIfPresent(Bool.self, forKey: .followSelectedTrack) ?? followSelectedTrack
        knobFullRange = try c.decodeIfPresent(Int.self, forKey: .knobFullRange) ?? knobFullRange
        if c.contains(.navigateTurn) { navigateTurn = try c.decodeIfPresent(String.self, forKey: .navigateTurn) }
        trackNameSeconds = try c.decodeIfPresent(Double.self, forKey: .trackNameSeconds) ?? trackNameSeconds
        mirrorSelection = try c.decodeIfPresent(Bool.self, forKey: .mirrorSelection) ?? mirrorSelection
        resourcePath = try c.decodeIfPresent(String.self, forKey: .resourcePath) ?? resourcePath
        lightGuide = try c.decodeIfPresent(Bool.self, forKey: .lightGuide) ?? lightGuide
        lightGuideBrightness = try c.decodeIfPresent(Int.self, forKey: .lightGuideBrightness) ?? lightGuideBrightness
        kompleteKontrolView = try c.decodeIfPresent(Bool.self, forKey: .kompleteKontrolView) ?? kompleteKontrolView
        midiView = try c.decodeIfPresent(MIDIViewConfig.self, forKey: .midiView) ?? midiView
        earlierKompleteKontrol = try c.decodeIfPresent(KKViewConfig.self, forKey: .kompleteKontrol)
        func merge(_ key: CodingKeys, into map: inout [String: String?]) throws {
            guard let user = try c.decodeIfPresent([String: String?].self, forKey: key) else { return }
            for (name, command) in user {
                guard name != "Shift", buttonDefs.contains(where: { $0.name == name }) else {
                    throw ConfigError(description: "reaper.\(key.stringValue): unknown button \"\(name)\". Valid names: "
                        + buttonDefs.map(\.name).filter { $0 != "Shift" }.joined(separator: ", "))
                }
                map.updateValue(command, forKey: name)
            }
        }
        try merge(.buttons, into: &buttons)
        try merge(.shiftButtons, into: &shiftButtons)
    }

    func validate() throws {
        for (v, what) in [(sendPort, "reaper.sendPort"), (receivePort, "reaper.receivePort")] {
            guard (1...65535).contains(v) else { throw ConfigError(description: "\(what) must be 1-65535, got \(v)") }
        }
        guard sendPort != receivePort else { throw ConfigError(description: "reaper.sendPort and reaper.receivePort must differ") }
        try midiView.validate()
        guard ReaperView.allCases.contains(where: { $0.configName == view }) else {
            throw ConfigError(description: "reaper.view must be \"mix\", \"track\", \"komplete-kontrol\" or \"midi\", got \"\(view)\"")
        }
        guard knobFullRange >= 10 else { throw ConfigError(description: "reaper.knobFullRange must be at least 10") }
        guard (1...100).contains(lightGuideBrightness) else {
            throw ConfigError(description: "reaper.lightGuideBrightness must be 1-100 (percent), got \(lightGuideBrightness)")
        }
        guard (0...30).contains(trackNameSeconds) else {
            throw ConfigError(description: "reaper.trackNameSeconds must be 0-30, got \(trackNameSeconds)")
        }
        if let n = navigateTurn, !navigateTurnTargets.contains(n) {
            throw ConfigError(description: "reaper.navigateTurn must be one of \(navigateTurnTargets.joined(separator: ", ")) or null, got \"\(n)\"")
        }
        for (key, map) in [("buttons", buttons), ("shiftButtons", shiftButtons)] {
            for (name, command) in map {
                if let command, ReaperCommand(command) == nil {
                    throw ConfigError(description: "reaper.\(key).\(name): unknown command \"\(command)\". Valid: \(ReaperCommand.validNames)")
                }
            }
        }
    }
}

struct Config: Codable {
    var portName = "Primo Komplete Kontrol MK1"
    var channel = 1
    var shiftChannel: Int? = 2
    var shiftLatch = false  // each press of Shift turns it on or off, instead of holding it (issue #21)
    var buttons: [String: Int?] = Dictionary(uniqueKeysWithValues: buttonDefs.map { ($0.name, Optional($0.cc)) })
    var knobChannel = 3  // the knobs' channel: the CCs of their page (knobPageCCs), apart from everything on channel
    var knobPages = 1    // knob pages, 1 to knobPageCCs.count: with more than one, Page ◀ / ▶ go through them
    var knobMode = TurnMode.absolute
    var knobStepsPerCC = 4
    var knobTouchCCs = Array(22...29)
    var navigateTurnCC: Int? = 30
    var navigateTurnMode = TurnMode.relativeBinaryOffset
    var navigateTouchCC: Int? = 31
    var lights = true
    var lightBrightness = 127
    var lightIdleBrightness = 6
    var displays = true
    var keyboardSource: String? = "auto"  // merged into the virtual port: "auto" (the keyboard's Port 1), a name, or null
    var kompleteKontrolView = false  // MIDI mode: Instance switches between it and the Komplete Kontrol view (issue #5)
    var kompleteKontrol = KKViewConfig()  // the Komplete Kontrol view's settings, for both modes
    var reaper = ReaperConfig()
    var verbose = false  // log every message the bridge sends, like --verbose (issue #7)

    enum CodingKeys: String, CodingKey {
        case portName, channel, shiftChannel, shiftLatch, buttons, knobChannel, knobPages, knobMode, knobStepsPerCC, knobTouchCCs
        case navigateTurnCC, navigateTurnMode, navigateTouchCC, lights, lightBrightness, lightIdleBrightness
        case displays, reaper, keyboardSource, verbose, kompleteKontrolView, kompleteKontrol
    }

    init() {}

    /// Every key is optional; missing keys keep their defaults, and an explicit null disables an optional control.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func nullable(_ k: CodingKeys, _ current: Int?) throws -> Int? {
            if c.contains(k) { return try c.decodeIfPresent(Int.self, forKey: k) }
            return current
        }
        portName = try c.decodeIfPresent(String.self, forKey: .portName) ?? portName
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? channel
        shiftChannel = try nullable(.shiftChannel, shiftChannel)
        shiftLatch = try c.decodeIfPresent(Bool.self, forKey: .shiftLatch) ?? shiftLatch
        // (Earlier configs' knobCCs, the knobs' CCs on channel 1, is left alone: the knob pages' CCs replace it.)
        knobChannel = try c.decodeIfPresent(Int.self, forKey: .knobChannel) ?? knobChannel
        knobPages = try c.decodeIfPresent(Int.self, forKey: .knobPages) ?? knobPages
        knobMode = try c.decodeIfPresent(TurnMode.self, forKey: .knobMode) ?? knobMode
        knobStepsPerCC = try c.decodeIfPresent(Int.self, forKey: .knobStepsPerCC) ?? knobStepsPerCC
        knobTouchCCs = try c.decodeIfPresent([Int].self, forKey: .knobTouchCCs) ?? knobTouchCCs
        navigateTurnCC = try nullable(.navigateTurnCC, navigateTurnCC)
        navigateTurnMode = try c.decodeIfPresent(TurnMode.self, forKey: .navigateTurnMode) ?? navigateTurnMode
        navigateTouchCC = try nullable(.navigateTouchCC, navigateTouchCC)
        lights = try c.decodeIfPresent(Bool.self, forKey: .lights) ?? lights
        lightBrightness = try c.decodeIfPresent(Int.self, forKey: .lightBrightness) ?? lightBrightness
        lightIdleBrightness = try c.decodeIfPresent(Int.self, forKey: .lightIdleBrightness) ?? lightIdleBrightness
        displays = try c.decodeIfPresent(Bool.self, forKey: .displays) ?? displays
        if c.contains(.keyboardSource) { keyboardSource = try c.decodeIfPresent(String.self, forKey: .keyboardSource) }
        reaper = try c.decodeIfPresent(ReaperConfig.self, forKey: .reaper) ?? reaper
        kompleteKontrolView = try c.decodeIfPresent(Bool.self, forKey: .kompleteKontrolView) ?? kompleteKontrolView
        kompleteKontrol = try c.decodeIfPresent(KKViewConfig.self, forKey: .kompleteKontrol)
            ?? reaper.earlierKompleteKontrol ?? kompleteKontrol
        verbose = try c.decodeIfPresent(Bool.self, forKey: .verbose) ?? verbose
        if let user = try c.decodeIfPresent([String: Int?].self, forKey: .buttons) {
            for (name, cc) in user {
                guard buttons[name] != nil else {
                    throw ConfigError(description: "unknown button \"\(name)\". Valid names: "
                        + buttonDefs.map(\.name).joined(separator: ", "))
                }
                buttons.updateValue(cc, forKey: name)
            }
        }
    }

    /// Every key, and null for an optional control that's off (shiftChannel, navigateTurnCC, navigateTouchCC,
    /// keyboardSource): reading the file back treats a missing key as "the default", so a synthesized encoder, which
    /// leaves nil out, turned those back on at the next load.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(portName, forKey: .portName)
        try c.encode(channel, forKey: .channel)
        try c.encode(shiftChannel, forKey: .shiftChannel)
        try c.encode(shiftLatch, forKey: .shiftLatch)
        try c.encode(buttons, forKey: .buttons)
        try c.encode(knobChannel, forKey: .knobChannel)
        try c.encode(knobPages, forKey: .knobPages)
        try c.encode(knobMode, forKey: .knobMode)
        try c.encode(knobStepsPerCC, forKey: .knobStepsPerCC)
        try c.encode(knobTouchCCs, forKey: .knobTouchCCs)
        try c.encode(navigateTurnCC, forKey: .navigateTurnCC)
        try c.encode(navigateTurnMode, forKey: .navigateTurnMode)
        try c.encode(navigateTouchCC, forKey: .navigateTouchCC)
        try c.encode(lights, forKey: .lights)
        try c.encode(lightBrightness, forKey: .lightBrightness)
        try c.encode(lightIdleBrightness, forKey: .lightIdleBrightness)
        try c.encode(displays, forKey: .displays)
        try c.encode(keyboardSource, forKey: .keyboardSource)
        try c.encode(kompleteKontrolView, forKey: .kompleteKontrolView)
        try c.encode(kompleteKontrol, forKey: .kompleteKontrol)
        try c.encode(reaper, forKey: .reaper)
        try c.encode(verbose, forKey: .verbose)
    }

    func validate() throws {
        func ch(_ v: Int, _ what: String) throws {
            guard (1...16).contains(v) else { throw ConfigError(description: "\(what) must be 1-16, got \(v)") }
        }
        func cc(_ v: Int, _ what: String) throws {
            guard (0...127).contains(v) else { throw ConfigError(description: "\(what) must be 0-127, got \(v)") }
        }
        try ch(channel, "channel")
        if let s = shiftChannel { try ch(s, "shiftChannel") }
        try ch(knobChannel, "knobChannel")
        guard (1...knobPageCCs.count).contains(knobPages) else {
            throw ConfigError(description: "knobPages must be 1-\(knobPageCCs.count), got \(knobPages)")
        }
        guard knobTouchCCs.isEmpty || knobTouchCCs.count == 8 else {
            throw ConfigError(description: "knobTouchCCs needs 8 entries, or [] to turn knob touch off")
        }
        guard knobStepsPerCC >= 1 else { throw ConfigError(description: "knobStepsPerCC must be at least 1") }
        for (name, v) in buttons { if let v { try cc(v, "buttons.\(name)") } }
        for v in knobTouchCCs { try cc(v, "knobTouchCCs") }
        if let v = navigateTurnCC { try cc(v, "navigateTurnCC") }
        if let v = navigateTouchCC { try cc(v, "navigateTouchCC") }
        for (v, what) in [(lightBrightness, "lightBrightness"), (lightIdleBrightness, "lightIdleBrightness")] {
            guard (0...255).contains(v) else { throw ConfigError(description: "\(what) must be 0-255, got \(v)") }
        }
        try kompleteKontrol.validate()
        try reaper.validate()
    }

    func duplicateWarnings() -> [String] {
        var seen: [Int: String] = [:], warnings: [String] = []
        func add(_ v: Int?, _ what: String) {
            guard let v else { return }
            if let other = seen[v] { warnings.append("CC\(v) is used by both \(other) and \(what)") } else { seen[v] = what }
        }
        for d in buttonDefs { add(buttons[d.name] ?? nil, d.name) }
        if knobChannel == channel {  // the knobs' pages share channel 1 with the buttons and knob touch
            for p in 0..<knobPages { for (i, v) in knobPageCCs[p].enumerated() { add(v, "knob \(i + 1) (page \(p + 1))") } }
        }
        for (i, v) in knobTouchCCs.enumerated() { add(v, "knob \(i + 1) touch") }
        add(navigateTurnCC, "Navigate turn")
        add(navigateTouchCC, "Navigate touch")
        return warnings
    }
}

// MARK: - Config file

extension Config {
    /// Where the bridge and the editor keep the config, unless told otherwise (--config, or the editor's Open):
    /// ~/Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/PrimoKKMK1Bridge.json
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PrimoStudios/PrimoKKMK1Bridge/PrimoKKMK1Bridge.json")
    }

    /// How config files are written: every key, sorted, readable.
    static let fileEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Create the default config file, with every default, if it isn't there yet. True when it was created.
    @discardableResult
    static func createDefaultFileIfMissing() throws -> Bool {
        let url = defaultURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileEncoder.encode(Config()).write(to: url, options: .atomic)
        return true
    }
}
