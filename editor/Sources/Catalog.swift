//
//  Catalog.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The editor's vocabulary: readable names for the keyboard's controls and REAPER's commands, and where each
//  control sits on the drawn panel.

import CoreGraphics
import Foundation

// MARK: - Controls

/// Something you can click on the drawn keyboard.
enum ControlID: Hashable {
    case button(String)  // a button, by its config name (buttonDefs)
    case knob(Int)       // knob 1-8 as 0-7
    case navigateKnob    // the big knob: turn, touch and press (the NavigateClick button)
    case pitchStrip, modStrip, keys
}

let buttonTitles: [String: String] = [
    "NavigateClick": "Navigate knob press", "PresetUp": "Preset ▲", "PresetDown": "Preset ▼",
    "Enter": "Enter", "Browse": "Browse", "Instance": "Instance", "Back": "Back",
    "OctaveDown": "Octave −", "OctaveUp": "Octave +",
    "Play": "Play", "Stop": "Stop", "Rec": "Rec", "Loop": "Loop", "Rewind": "Rewind ◀◀", "FastForward": "Fast forward ▶▶",
    "NavUp": "Navigate ▲", "NavDown": "Navigate ▼", "NavLeft": "Navigate ◀", "NavRight": "Navigate ▶",
    "Shift": "Shift", "Scale": "Scale", "Arp": "Arp", "PageLeft": "Page ◀", "PageRight": "Page ▶",
]

func buttonTitle(_ name: String) -> String { buttonTitles[name] ?? name }

func defaultCC(_ button: String) -> Int { buttonDefs.first { $0.name == button }?.cc ?? 0 }

/// A button on the drawn panel: its config name, the text printed on it, and its centre and width.
struct PanelButtonSpec {
    let name: String
    let cap: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    /// Drawn dark with a lit outline, like the Navigate arrows on the keyboard.
    var outlined = false
}

/// The drawn panel is laid out on a fixed canvas and scaled to fit the window.
let panelSize = CGSize(width: 1060, height: 410)
let panelTop: CGFloat = 250  // where the control panel ends and the keys begin

let panelButtons: [PanelButtonSpec] = [
    PanelButtonSpec(name: "Shift", cap: "SHIFT", x: 55, y: 30, width: 56),
    PanelButtonSpec(name: "Scale", cap: "SCALE", x: 120, y: 30, width: 56),
    PanelButtonSpec(name: "Arp", cap: "ARP", x: 185, y: 30, width: 56),
    PanelButtonSpec(name: "Loop", cap: "LOOP", x: 55, y: 85, width: 56),
    PanelButtonSpec(name: "Rewind", cap: "◀◀", x: 120, y: 85, width: 56),
    PanelButtonSpec(name: "FastForward", cap: "▶▶", x: 185, y: 85, width: 56),
    PanelButtonSpec(name: "Play", cap: "PLAY", x: 55, y: 140, width: 56),
    PanelButtonSpec(name: "Rec", cap: "REC", x: 120, y: 140, width: 56),
    PanelButtonSpec(name: "Stop", cap: "STOP", x: 185, y: 140, width: 56),
    PanelButtonSpec(name: "OctaveDown", cap: "OCT −", x: 75, y: 200, width: 60),
    PanelButtonSpec(name: "OctaveUp", cap: "OCT +", x: 165, y: 200, width: 60),
    // The page arrows sit left of knob 1, above the left display, drawn like the Navigate arrows, with a gap
    // of about 17 points before knob 1.
    PanelButtonSpec(name: "PageLeft", cap: "◀", x: displayCenter(0).x - 32, y: knobRowY, width: 28, outlined: true),
    PanelButtonSpec(name: "PageRight", cap: "▶", x: displayCenter(0).x + 6, y: knobRowY, width: 28, outlined: true),
    // The Navigate section, as on the keyboard: three columns, four rows, the big knob in the middle column
    // across the top two rows.
    //   BROWSE     (knob)   PRESET ▲
    //   INSTANCE   (knob)   PRESET ▼
    //   BACK         ▲      ENTER
    //   ◀            ▼      ▶
    PanelButtonSpec(name: "Browse", cap: "BROWSE", x: navColumns[0], y: navRows[0], width: 66),
    PanelButtonSpec(name: "Instance", cap: "INSTANCE", x: navColumns[0], y: navRows[1], width: 66),
    PanelButtonSpec(name: "Back", cap: "BACK", x: navColumns[0], y: navRows[2], width: 66),
    PanelButtonSpec(name: "NavLeft", cap: "◀", x: navColumns[0], y: navRows[3], width: 66, outlined: true),
    PanelButtonSpec(name: "NavUp", cap: "▲", x: navColumns[1], y: navRows[2], width: 66, outlined: true),
    PanelButtonSpec(name: "NavDown", cap: "▼", x: navColumns[1], y: navRows[3], width: 66, outlined: true),
    PanelButtonSpec(name: "PresetUp", cap: "PRESET ▲", x: navColumns[2], y: navRows[0], width: 66),
    PanelButtonSpec(name: "PresetDown", cap: "PRESET ▼", x: navColumns[2], y: navRows[1], width: 66),
    PanelButtonSpec(name: "Enter", cap: "ENTER", x: navColumns[2], y: navRows[2], width: 66),
    PanelButtonSpec(name: "NavRight", cap: "▶", x: navColumns[2], y: navRows[3], width: 66, outlined: true),
]

/// As on the keyboard: the knobs in a row, each display right below its knob, and display 0 below the page
/// arrows, left of knob 1.
let knobRowY: CGFloat = 66
let displayRowY: CGFloat = 142
let knobDiameter: CGFloat = 40
func displayCenter(_ i: Int) -> CGPoint { CGPoint(x: 280 + 60 * CGFloat(i), y: displayRowY) }
func knobCenter(_ k: Int) -> CGPoint { CGPoint(x: displayCenter(k + 1).x, y: knobRowY) }

/// The Navigate section's grid: column and row centres.
let navColumns: [CGFloat] = [836, 924, 1012]
let navRows: [CGFloat] = [30, 88, 146, 204]
/// The big knob sits in the middle column, across the first two rows.
let navigateKnobCenter = CGPoint(x: navColumns[1], y: (navRows[0] + navRows[1]) / 2)
let navigateKnobDiameter: CGFloat = 60

// MARK: - REAPER commands

struct CommandInfo: Identifiable {
    let name: String   // as in the config
    let title: String  // for menus
    let short: String  // for the panel
    var id: String { name }
}

struct CommandSection: Identifiable {
    let title: String
    let items: [CommandInfo]
    var id: String { title }
}

let commandSections: [CommandSection] = [
    CommandSection(title: "Transport", items: [
        CommandInfo(name: "play", title: "Play", short: "Play"),
        CommandInfo(name: "stop", title: "Stop", short: "Stop"),
        CommandInfo(name: "record", title: "Record", short: "Record"),
        CommandInfo(name: "repeat", title: "Repeat on / off", short: "Repeat"),
        CommandInfo(name: "rewind", title: "Rewind", short: "Rewind"),
        CommandInfo(name: "forward", title: "Fast forward", short: "Forward"),
        CommandInfo(name: "go-to-start", title: "Go to the start of the project", short: "To start"),
        CommandInfo(name: "previous-marker", title: "Previous marker", short: "◀ Marker"),
        CommandInfo(name: "next-marker", title: "Next marker", short: "Marker ▶"),
        CommandInfo(name: "metronome", title: "Metronome on / off", short: "Metronome"),
        CommandInfo(name: "record-mode", title: "Record mode: normal ↔ auto-punch", short: "Rec mode"),
    ]),
    CommandSection(title: "Tracks and views", items: [
        CommandInfo(name: "next-track", title: "Next track", short: "Next track"),
        CommandInfo(name: "previous-track", title: "Previous track", short: "Prev track"),
        CommandInfo(name: "next-page", title: "Next bank / knob page", short: "Page ▶"),
        CommandInfo(name: "previous-page", title: "Previous bank / knob page", short: "◀ Page"),
        CommandInfo(name: "toggle-view", title: "Next view (Mix → Track → Komplete Kontrol)", short: "View"),
        CommandInfo(name: "learn-nks-pages", title: "Learn NKS pages (Komplete Kontrol view)", short: "Learn NKS"),
        CommandInfo(name: "mute", title: "Mute the selected track", short: "Mute"),
        CommandInfo(name: "solo", title: "Solo the selected track", short: "Solo"),
    ]),
    CommandSection(title: "Project and editing", items: [
        CommandInfo(name: "undo", title: "Undo", short: "Undo"),
        CommandInfo(name: "redo", title: "Redo", short: "Redo"),
        CommandInfo(name: "save-project", title: "Save the project", short: "Save"),
        CommandInfo(name: "render-project", title: "Open the Render dialog", short: "Render"),
    ]),
    CommandSection(title: "Plugins and MIDI", items: [
        CommandInfo(name: "browse-fx", title: "Open the selected track's plugins one by one", short: "Plugins"),
        CommandInfo(name: "close-fx", title: "Close the selected track's plugin windows", short: "Close FX"),
        CommandInfo(name: "panic", title: "MIDI panic: all notes off", short: "Panic"),
    ]),
    // REAPER actions by command ID that the REAPER-mode defaults use, with names (IDs checked in REAPER 7.61).
    // MIDI Editor actions have their own IDs and go out as midiaction:<ID>.
    CommandSection(title: "REAPER actions", items: [
        CommandInfo(name: "action:1012", title: "View: Zoom in horizontal", short: "Zoom in"),
        CommandInfo(name: "action:1011", title: "View: Zoom out horizontal", short: "Zoom out"),
        CommandInfo(name: "action:40111", title: "View: Zoom in vertical", short: "Zoom in ↕"),
        CommandInfo(name: "action:40112", title: "View: Zoom out vertical", short: "Zoom out ↕"),
        CommandInfo(name: "action:40104", title: "View: Move cursor left one pixel", short: "◀ Cursor"),
        CommandInfo(name: "action:40105", title: "View: Move cursor right one pixel", short: "Cursor ▶"),
        CommandInfo(name: "action:40646", title: "View: Move cursor left to grid division", short: "◀ Grid"),
        CommandInfo(name: "action:40647", title: "View: Move cursor right to grid division", short: "Grid ▶"),
        CommandInfo(name: "action:40403", title: "Automation: track mode write", short: "Auto write"),
        CommandInfo(name: "action:40400", title: "Automation: track mode trim/read", short: "Auto trim"),
        CommandInfo(name: "action:40401", title: "Automation: track mode read", short: "Auto read"),
        CommandInfo(name: "action:40402", title: "Automation: track mode touch", short: "Auto touch"),
        CommandInfo(name: "action:40716", title: "View: Show / hide MIDI editor windows", short: "MIDI editor"),
        CommandInfo(name: "midiaction:40481", title: "MIDI Editor: MIDI inputs as step input", short: "Step input"),
    ]),
]

let commandsByName: [String: CommandInfo] = Dictionary(
    uniqueKeysWithValues: commandSections.flatMap(\.items).map { ($0.name, $0) })

/// The default REAPER action ID offered when you pick "Run a REAPER action" (Transport: Play/stop).
let defaultActionID = 40044
/// The default MIDI Editor action ID offered when you pick "Run a MIDI Editor action" (step input on / off).
let defaultMIDIActionID = 40481

func commandTitle(_ command: String?) -> String {
    guard let c = command else { return "None" }
    if let info = commandsByName[c] { return info.title }
    if c.hasPrefix("screenset:") { return "Load screenset \(c.dropFirst(10))" }
    if c.hasPrefix("action:") { return "Run REAPER action \(c.dropFirst(7))" }
    if c.hasPrefix("midiaction:") { return "Run MIDI Editor action \(c.dropFirst(11))" }
    return c
}

func commandShort(_ command: String?) -> String {
    guard let c = command else { return "—" }
    if let info = commandsByName[c] { return info.short }
    if c.hasPrefix("screenset:") { return "Screen \(c.dropFirst(10))" }
    if c.hasPrefix("action:") { return "Act \(c.dropFirst(7))" }
    if c.hasPrefix("midiaction:") { return "MIDI \(c.dropFirst(11))" }
    return c
}

/// What the Navigate knob's turn does in REAPER mode (reaper.navigateTurn).
func navigateTurnTitle(_ target: String?, cc: Int?) -> String {
    switch target {
    case "tracks": return "Scroll through tracks"
    case "pages": return "Page through banks / knob pages"
    default: return cc.map { "Send its MIDI CC (CC \($0))" } ?? "Nothing (its CC is off)"
    }
}

/// Track view, knob page 1.
let trackViewTargets = ["Volume", "Pan", "Mute", "Solo", "Record arm", "Send 1", "Send 2", "Send 3"]

func turnModeTitle(_ m: TurnMode) -> String {
    switch m {
    case .absolute: return "Absolute (0–127)"
    case .relativeBinaryOffset: return "Relative, binary offset (64 ± n)"
    case .relativeTwosComplement: return "Relative, two's complement"
    case .relativeSignedBit: return "Relative, signed bit"
    }
}

let turnModes: [TurnMode] = [.absolute, .relativeBinaryOffset, .relativeTwosComplement, .relativeSignedBit]
