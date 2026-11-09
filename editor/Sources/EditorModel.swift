//
//  EditorModel.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The editor's state: the config being edited, the file it came from, what's selected, validation, saving,
//  and whether the bridge is running (its virtual MIDI port exists).

import AppKit
import CoreMIDI
import Foundation
import UniformTypeIdentifiers

enum EditorPage: String, CaseIterable, Identifiable {
    case midi = "MIDI"
    case reaper = "REAPER"
    case kk = "Komplete Kontrol"
    case settings = "Settings"
    var id: Self { self }
}

/// What a button does in the Komplete Kontrol view besides sending its CC.
enum KKRole: String, CaseIterable, Identifiable {
    case none = "Just its CC"
    case previousPage = "Previous NKS page"
    case nextPage = "Next NKS page"
    case preset = "Loads a preset"
    var id: Self { self }
}

final class EditorModel: ObservableObject {
    @Published var config = Config() {
        // REAPER mode switched (or a file loaded): leave a page that's now hidden for the mode's first page.
        didSet { if !visiblePages.contains(page) { page = visiblePages[0] } }
    }
    @Published var page: EditorPage = .midi

    /// The pages of the current mode: MIDI without REAPER mode; REAPER and Komplete Kontrol with it.
    var visiblePages: [EditorPage] { config.reaper.enabled ? [.reaper, .kk, .settings] : [.midi, .settings] }
    @Published var selection: ControlID? = .button("Play")
    @Published var status = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var savedJSON = Data()

    /// The toolbar's bridge switch: starts, stops and watches the bridge.
    let bridge = BridgeControl()

    private var fileDate: Date?
    private var lastTouchCCs = Array(22...29)
    private var timer: Timer?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: state

    var json: Data { (try? Self.encoder.encode(config)) ?? Data() }
    var isDirty: Bool { json != savedJSON }
    var fileName: String { fileURL?.lastPathComponent ?? "Untitled" }
    var canSave: Bool { validationError == nil && (isDirty || fileURL == nil) }

    /// Why the config can't be saved, in the editor's words where the bridge's would be unclear.
    var validationError: String? {
        let pages = config.reaper.kompleteKontrol.pageButtons
        if pages.count == 2, pages.contains("") {
            return "Komplete Kontrol page: pick both a previous-page and a next-page button, or neither."
        }
        do {
            try config.validate()
            return nil
        } catch {
            return "\(error)"
        }
    }

    var warnings: [String] { config.duplicateWarnings() }

    // MARK: start, load, save

    func start() {
        guard timer == nil else { return }
        if let url = Self.initialURL() {
            load(url)
        } else {
            savedJSON = json
            status = "No config file yet: open the bridge's (File ▸ Open Config…) or save these defaults as a new one."
        }
        bridge.startWatching()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// The file opened last, else the bridge's own config next to this app (build/ → bridge/PrimoKKMK1Bridge.json).
    static func initialURL() -> URL? {
        if let p = UserDefaults.standard.string(forKey: "configPath"), FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("bridge/PrimoKKMK1Bridge.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let c = try JSONDecoder().decode(Config.self, from: data)
            config = c
            savedJSON = json
            bridge.portName = c.portName
            if !c.knobTouchCCs.isEmpty { lastTouchCCs = c.knobTouchCCs }
            fileURL = url
            fileDate = Self.modificationDate(url)
            UserDefaults.standard.set(url.path, forKey: "configPath")
            status = "Opened \(url.path)"
            return true
        } catch {
            alert("Can't open \(url.lastPathComponent)", "\(error)")
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let url = fileURL else { return saveAs() }
        if let e = validationError {
            alert("Can't save yet", e)
            return false
        }
        do {
            let data = json
            try data.write(to: url, options: .atomic)
            savedJSON = data
            bridge.portName = config.portName
            fileDate = Self.modificationDate(url)
            status = bridge.isRunning
                ? "Saved. The bridge restarts with the new settings within a second or two."
                : "Saved. Turn the bridge on (toolbar) to run with these settings."
            return true
        } catch {
            alert("Can't save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "PrimoKKMK1Bridge.json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        fileURL = url
        UserDefaults.standard.set(url.path, forKey: "configPath")
        savedJSON = Data()  // a new file: always written
        return save()
    }

    func openWithPanel() {
        guard !isDirty || confirmDiscard(before: "opening another file") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose the bridge's config file (the one you pass with --config)."
        if let url = fileURL { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func revert() {
        guard let url = fileURL else {
            config = Config()
            return
        }
        if load(url) { status = "Reverted to the saved file." }
    }

    func resetToDefaults() {
        var defaults = Config()
        defaults.reaper.enabled = config.reaper.enabled  // one assignment, so the page doesn't jump to MIDI
        config = defaults
        status = "Every assignment is back to its default (REAPER mode left as it was). Save to apply."
    }

    /// Save / Don't Save / Cancel. True when it's fine to go on.
    func confirmDiscard(before action: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Save the changes to \(fileName) before \(action)?"
        a.informativeText = "Your changes are lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func tick() {
        guard let url = fileURL, let d = Self.modificationDate(url), d != fileDate else { return }
        fileDate = d
        if isDirty {
            status = "\(url.lastPathComponent) changed on disk. Saving replaces those changes with yours."
        } else if load(url) {
            status = "Reloaded \(url.lastPathComponent): it changed on disk."
        }
    }

    // MARK: the bridge

    /// Start the bridge with the saved config file (the bridge reads the file, not the editor's unsaved changes).
    func startBridge() {
        guard let url = fileURL else {
            status = "Save the config first: the bridge runs from a config file."
            return
        }
        bridge.start(config: url)
        status = isDirty ? "Starting the bridge with the saved settings. Save to apply your unsaved changes."
                         : "Starting the bridge with \(url.lastPathComponent)…"
    }

    // MARK: assignments

    /// Plain MIDI CC of a button (null = silent). Assigning through updateValue keeps an explicit null.
    func midiCC(_ button: String) -> Int? { config.buttons[button] ?? nil }
    func setMidiCC(_ button: String, _ cc: Int?) { config.buttons.updateValue(cc, forKey: button) }

    func command(_ button: String, shift: Bool) -> String? {
        (shift ? config.reaper.shiftButtons[button] : config.reaper.buttons[button]) ?? nil
    }

    func setCommand(_ button: String, shift: Bool, _ command: String?) {
        if shift {
            config.reaper.shiftButtons.updateValue(command, forKey: button)
        } else {
            config.reaper.buttons.updateValue(command, forKey: button)
        }
    }

    func kkCC(_ button: String) -> Int? { config.reaper.kompleteKontrol.buttons[button] ?? nil }

    func setKKCC(_ button: String, _ cc: Int?) {
        config.reaper.kompleteKontrol.buttons.updateValue(cc, forKey: button)
        if cc == nil { setKKRole(button, .none) }
    }

    private var kkPagePair: (prev: String?, next: String?) {
        let p = config.reaper.kompleteKontrol.pageButtons
        guard p.count == 2 else { return (nil, nil) }
        return (p[0].isEmpty ? nil : p[0], p[1].isEmpty ? nil : p[1])
    }

    func kkRole(_ button: String) -> KKRole {
        let pair = kkPagePair
        if pair.prev == button { return .previousPage }
        if pair.next == button { return .nextPage }
        if config.reaper.kompleteKontrol.presetButtons.contains(button) { return .preset }
        return .none
    }

    /// Page buttons are a pair (previous, next) or none; "" marks the half not picked yet, which validation flags.
    func setKKRole(_ button: String, _ role: KKRole) {
        var kk = config.reaper.kompleteKontrol
        var (prev, next) = kkPagePair
        if prev == button { prev = nil }
        if next == button { next = nil }
        kk.presetButtons.removeAll { $0 == button }
        switch role {
        case .previousPage: prev = button
        case .nextPage: next = button
        case .preset: kk.presetButtons.append(button)
        case .none: break
        }
        kk.pageButtons = prev == nil && next == nil ? [] : [prev ?? "", next ?? ""]
        config.reaper.kompleteKontrol = kk
    }

    var knobTouchOn: Bool {
        get { !config.knobTouchCCs.isEmpty }
        set {
            if !newValue, !config.knobTouchCCs.isEmpty { lastTouchCCs = config.knobTouchCCs }
            config.knobTouchCCs = newValue ? lastTouchCCs : []
        }
    }

    // MARK: what the drawn panel shows

    func isAssigned(_ id: ControlID) -> Bool {
        switch (page, id) {
        case (.midi, .button(let b)): return midiCC(b) != nil
        case (.reaper, .button(let b)): return b == "Shift" || command(b, shift: false) != nil || command(b, shift: true) != nil
        case (.kk, .button(let b)): return kkCC(b) != nil
        default: return true
        }
    }

    func panelLines(_ id: ControlID) -> [String] {
        let cc: (Int?) -> String = { $0.map { "CC \($0)" } ?? "—" }
        switch (page, id) {
        case (.midi, .button(let b)):
            return [cc(midiCC(b))]
        case (.midi, .navigateKnob):
            return ["turn " + cc(config.navigateTurnCC), "push " + cc(midiCC("NavigateClick"))]
        case (.reaper, .button(let b)):
            if b == "Shift" { return ["Shift layer"] }
            let main = command(b, shift: false).map(commandShort) ?? cc(midiCC(b))
            return [main, command(b, shift: true).map { "⇧ " + commandShort($0) } ?? ""]
        case (.reaper, .navigateKnob), (.kk, .navigateKnob):
            let turn = config.reaper.navigateTurn.map { $0 == "tracks" ? "Tracks" : "Pages" } ?? cc(config.navigateTurnCC)
            let press = page == .kk ? kkCC("NavigateClick").map { "CC \($0)" } : nil
            return [turn, "push " + (press ?? command("NavigateClick", shift: false).map(commandShort) ?? cc(midiCC("NavigateClick")))]
        case (.kk, .button(let b)):
            guard let v = kkCC(b) else { return ["—"] }
            switch kkRole(b) {
            case .previousPage: return ["CC \(v)", "◀ page"]
            case .nextPage: return ["CC \(v)", "page ▶"]
            case .preset: return ["CC \(v)", "preset"]
            case .none: return ["CC \(v)"]
            }
        default:
            return []
        }
    }

    /// The two text rows of display 0-8. As on the keyboard, the display under a knob says what the knob does:
    /// its CC (and touch CC) on the MIDI and Komplete Kontrol pages, its track in REAPER's mix view.
    func displayText(_ i: Int) -> (String, String) {
        switch page {
        case .midi:
            if i == 0 { return ("MIDI", "CH \(config.channel)") }
            let k = i - 1
            let second = knobTouchOn ? "TOUCH \(config.knobTouchCCs[k])" : (config.knobMode == .absolute ? "ABS" : "REL")
            return ("CC \(config.knobCCs[k])", second)
        case .reaper:
            if i == 0 { return ("MIX", "1-8") }
            return ("TRACK \(i)", "VOLUME")
        case .kk:
            let kk = config.reaper.kompleteKontrol
            if i == 0 { return ("KOMPLETE", "PAGE 1") }
            return ("CC \(kk.encoderCCs[i - 1])", kk.encoderMode == .absolute ? "ABS" : "REL")
        case .settings:
            return ("", "")
        }
    }

    /// The value bar on top of display 1-8: the middle (64) for CCs, 0 dB for a REAPER volume.
    func displayBar(_ i: Int) -> Double? {
        guard i > 0 else { return nil }
        return page == .reaper ? 0.716 : 64.0 / 127
    }
}
