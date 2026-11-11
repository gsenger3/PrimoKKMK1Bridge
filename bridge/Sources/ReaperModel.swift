//
//  ReaperModel.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  REAPER mode's vocabulary: button commands, REAPER action IDs, track and send strips, views, events and
//  knob targets.

import Foundation

// MARK: - REAPER commands and state

enum ReaperCommand: Equatable {
    case play, stop, record, repeatToggle, rewind, forward
    case previousTrack, nextTrack, previousPage, nextPage, toggleView, mute, solo, metronome
    case goToStart, previousMarker, nextMarker, recordMode, undo, redo, browseFX, closeFX, panic
    case saveProject, renderProject
    case screenset(Int)  // REAPER window set 1-10
    case action(Int)      // a main-section REAPER action, by command ID
    case midiAction(Int)  // a MIDI Editor action, by its own command ID (it acts on the open MIDI editor)

    static let named: [(String, ReaperCommand)] = [
        ("play", .play), ("stop", .stop), ("record", .record), ("repeat", .repeatToggle),
        ("rewind", .rewind), ("forward", .forward),
        ("previous-track", .previousTrack), ("next-track", .nextTrack),
        ("previous-page", .previousPage), ("next-page", .nextPage),
        ("toggle-view", .toggleView), ("mute", .mute), ("solo", .solo), ("metronome", .metronome),
        ("go-to-start", .goToStart), ("previous-marker", .previousMarker), ("next-marker", .nextMarker),
        ("record-mode", .recordMode), ("undo", .undo), ("redo", .redo),
        ("browse-fx", .browseFX), ("close-fx", .closeFX), ("panic", .panic),
        ("save-project", .saveProject), ("render-project", .renderProject),
    ]
    static var validNames: String {
        named.map(\.0).joined(separator: ", ")
            + ", screenset:<1-10>, action:<REAPER command ID>, midiaction:<MIDI Editor command ID>"
    }

    init?(_ s: String) {
        if s.hasPrefix("screenset:") {
            guard let n = Int(s.dropFirst(10)), (1...10).contains(n) else { return nil }
            self = .screenset(n)
            return
        }
        if s.hasPrefix("action:") {
            guard let id = Int(s.dropFirst(7)), id > 0, id <= Int(Int32.max) else { return nil }
            self = .action(id)
            return
        }
        if s.hasPrefix("midiaction:") {
            guard let id = Int(s.dropFirst(11)), id > 0, id <= Int(Int32.max) else { return nil }
            self = .midiAction(id)
            return
        }
        guard let c = Self.named.first(where: { $0.0 == s })?.1 else { return nil }
        self = c
    }
}

let navigateTurnTargets = ["tracks", "pages"]
let bankSize = 8      // tracks per mix-view page, one per knob
let sendSlots = 16    // sends REAPER reports for the selected track; track view pages through them
let fxSlots = 16      // plugins REAPER reports for the selected track (Browse steps through their windows)

/// "VST3: Komplete Kontrol (Native Instruments) (32 out)" -> "Komplete Kontrol"
func pluginName(_ s: String) -> String {
    var n = s
    let kinds: Set<String> = ["VST", "VSTi", "VST3", "VST3i", "AU", "AUi", "JS", "CLAP", "CLAPi", "LV2", "LV2i", "DX", "DXi"]
    if let r = n.range(of: ": "), kinds.contains(String(n[..<r.lowerBound])) { n = String(n[r.upperBound...]) }
    while n.hasSuffix(")"), let open = n.range(of: " (", options: .backwards) { n = String(n[..<open.lowerBound]) }
    return n.isEmpty ? s : n
}
let toggleTurn = 24   // raw knob units to turn mute or solo on (right) or off (left)
// REAPER action command IDs, checked against REAPER 7.61's action table.
let refreshSurfacesAction: Int32 = 41743  // "Control surface: refresh all surfaces"
let goToStartAction: Int32 = 40042        // "Transport: Go to start of project"
let previousMarkerAction: Int32 = 40172   // "Markers: Go to previous marker/project start"
let nextMarkerAction: Int32 = 40173       // "Markers: Go to next marker/project end"
let recordNormalAction: Int32 = 40252     // "Record: Set record mode to normal"
let recordAutoPunchAction: Int32 = 40076  // "Record: Set record mode to time selection auto-punch"
let undoAction: Int32 = 40029             // "Edit: Undo"
let redoAction: Int32 = 40030             // "Edit: Redo"
let unselectAllTracksAction: Int32 = 40297  // "Track: Unselect (clear selection of) all tracks"
let scrollToSelectedAction: Int32 = 40913   // "Track: Vertical scroll selected tracks into view"
let panicAction: Int32 = 40345  // "Send all-notes-off and all-sounds-off to all MIDI outputs/plug-ins"
let saveProjectAction: Int32 = 40026    // "File: Save project"
let renderProjectAction: Int32 = 40015  // "File: Render project to disk..." (opens the Render dialog)
let windowSet1Action: Int32 = 40454     // "Screenset: Load window set #01"; #02-#10 follow in order

struct TrackStrip {
    var name = "", number = ""
    var volume: Double?, volumeText = "", volumeDB: Double?
    var pan: Double?, panText = "", width: Double?
    var mute = false, solo = false
    var recArm = false
    var monitor = 0  // record monitoring: 0 off, 1 on, 2 auto (tape style)
    /// REAPER fills a page past the last track with stand-ins: "Track 5" at -inf dB (-150) and 0% width
    /// (pan2 0.5). A real unnamed track is also called "Track 5", but has a real volume and 100% width.
    var isPlaceholder: Bool {
        name == "Track \(number)" && (volumeDB ?? 0) <= -150 && abs((width ?? 1) - 0.5) < 0.001
    }
    var exists: Bool { (!number.isEmpty || !name.isEmpty) && !isPlaceholder }
    var label: String { name.isEmpty ? "Track \(number)" : name }
}

struct SendStrip {
    var name = "", volume: Double?, volumeText = ""
    /// REAPER reports every send slot; unused ones are called "Send N" (their slot number) at -inf dB.
    func isRouted(slot: Int) -> Bool { !name.isEmpty && !(name == "Send \(slot + 1)" && volumeText == "-inf dB") }
}

enum ReaperView: CaseIterable {
    case mix, track, kk  // kk: the Komplete Kontrol view
    /// The name in the config (reaper.view) and the logs.
    var configName: String {
        switch self {
        case .mix: return "mix"
        case .track: return "track"
        case .kk: return "komplete-kontrol"
        }
    }
}
enum ReaperEvent {  // trackData: a value of the selected track
    case connected, track, trackData, bank, values, transport, view, recordMode
    case pluginShown(Int), pluginsClosed, noPlugins  // Browse / Shift + Browse
    case panic, saved, render, screenset(Int)
}

/// What a knob controls in the current view and page.
enum KnobTarget: Equatable {
    case bankVolume(Int)  // mix view: volume of bank slot 0-7
    case volume, pan, mute, solo, recArm
    case send(Int)        // track view: send 0-15 of the selected track
}

/// What the displays show for one knob.
struct KnobInfo { let name: String; let short: String; let value: String; let bar: Double?; let isPan: Bool }
