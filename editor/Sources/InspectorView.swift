//
//  InspectorView.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The inspector beside the panel: what the selected control does on the current page (MIDI, REAPER or
//  Komplete Kontrol), with the fields to change it, plus the reusable CC, number and command fields.

import SwiftUI

// MARK: - Fields

/// A CC number that can also be off (null in the config).
struct CCField: View {
    let title: String
    @Binding var value: Int?
    let fallback: Int
    var offText = "Off"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                if let v = value {
                    TextField("", value: Binding(get: { v }, set: { value = min(max($0, 0), 127) }), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Stepper("", value: Binding(get: { v }, set: { value = $0 }), in: 0...127).labelsHidden()
                } else {
                    Text(offText).foregroundStyle(.secondary)
                }
                Toggle("", isOn: Binding(get: { value != nil }, set: { value = $0 ? (value ?? fallback) : nil }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
    }
}

/// A whole number with a range.
struct IntField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("", value: $value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// A REAPER command for a button: none (the button sends its CC), a named command, a screenset, or a REAPER or
/// MIDI Editor action by ID.
struct CommandPicker: View {
    let title: String
    @Binding var command: String?
    let noneTitle: String

    private var kind: Binding<String> {
        Binding(
            get: {
                guard let c = command else { return "" }
                if commandsByName[c] != nil { return c }  // a named command, or an action listed by name
                if c.hasPrefix("screenset:") { return "screenset" }
                if c.hasPrefix("action:") { return "action" }
                if c.hasPrefix("midiaction:") { return "midiaction" }
                return c
            },
            set: { k in
                switch k {
                case "": command = nil
                case "screenset": command = "screenset:1"
                case "action": command = "action:\(defaultActionID)"
                case "midiaction": command = "midiaction:\(defaultMIDIActionID)"
                default: command = k
                }
            })
    }

    var body: some View {
        Picker(title, selection: kind) {
            Text(noneTitle).tag("")
            ForEach(commandSections) { section in
                Section(section.title) {
                    ForEach(section.items) { Text($0.title).tag($0.name) }
                }
            }
            Section("REAPER") {
                Text("Load a screenset…").tag("screenset")
                Text("Run a REAPER action by ID…").tag("action")
                Text("Run a MIDI Editor action by ID…").tag("midiaction")
            }
        }
        if let c = command, c.hasPrefix("screenset:") {
            let n = Int(c.dropFirst(10)) ?? 1
            LabeledContent("Screenset") {
                Stepper("\(n)", value: Binding(get: { n }, set: { command = "screenset:\($0)" }), in: 1...10)
            }
        }
        if let c = command, kind.wrappedValue == "action" {
            let id = Int(c.dropFirst(7)) ?? defaultActionID
            LabeledContent("Action ID") {
                TextField("", value: Binding(get: { id }, set: { command = "action:\(max(1, $0))" }), format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Text("In REAPER's Action List, right-click an action and choose Copy selected action command ID.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let c = command, kind.wrappedValue == "midiaction" {
            let id = Int(c.dropFirst(11)) ?? defaultMIDIActionID
            LabeledContent("MIDI Editor action ID") {
                TextField("", value: Binding(get: { id }, set: { command = "midiaction:\(max(1, $0))" }), format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Text("From the MIDI Editor section of REAPER's Action List. It acts on the open MIDI editor.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        Form {
            if let sel = model.selection {
                Section { header(sel) }
                switch (model.page, sel) {
                case (_, .pitchStrip):
                    note("The keyboard sends pitch bend from this strip by itself, on its own MIDI port and merged into \(model.config.portName). Not assignable.")
                case (_, .modStrip):
                    note("The keyboard sends CC1 (modulation) from this strip by itself, on its own MIDI port and merged into \(model.config.portName). Not assignable.")
                case (_, .keys):
                    note("The keys send notes on channel 1 by themselves. With Keyboard source set to Automatic (Settings), they're also merged into \(model.config.portName), so one DAW input gets keys and controls.")
                case (.midi, .button(let b)): midiButton(b)
                case (.midi, .knob(let k)): midiKnob(k)
                case (.midi, .navigateKnob): midiNavigate()
                case (.reaper, .button(let b)): reaperButton(b)
                case (.reaper, .knob(let k)): reaperKnob(k)
                case (.reaper, .navigateKnob): reaperNavigate()
                case (.kk, .button(let b)): kkButton(b)
                case (.kk, .knob(let k)): kkKnob(k)
                case (.kk, .navigateKnob): kkNavigate()
                default: EmptyView()
                }
            } else {
                note("Click a button, knob or strip on the keyboard to see what it does on this page and change it.")
            }
        }
        .formStyle(.grouped)
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ sel: ControlID) -> some View {
        let (title, kind): (String, String) = {
            switch sel {
            case .button(let b): return (buttonTitle(b), lightSlot[b] == nil ? "Button, no light" : "Button with light")
            case .knob(let k): return ("Knob \(k + 1)", "Endless knob with touch")
            case .navigateKnob: return ("Navigate knob", "Turn, touch and press")
            case .pitchStrip: return ("Pitch strip", "Touch strip")
            case .modStrip: return ("Mod strip", "Touch strip")
            case .keys: return ("Keys", "61 keys")
            }
        }()
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text("\(kind) · \(model.page.rawValue) page").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: bindings

    private func midiCC(_ b: String) -> Binding<Int?> {
        Binding(get: { model.midiCC(b) }, set: { model.setMidiCC(b, $0) })
    }

    private func command(_ b: String, shift: Bool) -> Binding<String?> {
        Binding(get: { model.command(b, shift: shift) }, set: { model.setCommand(b, shift: shift, $0) })
    }

    private func kkCC(_ b: String) -> Binding<Int?> {
        Binding(get: { model.kkCC(b) }, set: { model.setKKCC(b, $0) })
    }

    private var shiftText: String {
        model.config.shiftChannel.map { "channel \($0)" } ?? "(the Shift layer is off)"
    }

    // MARK: MIDI page

    @ViewBuilder private func midiButton(_ b: String) -> some View {
        Section("MIDI") {
            CCField(title: "CC on channel \(model.config.channel)", value: midiCC(b), fallback: defaultCC(b))
            if b == "Shift" {
                note("Holding Shift moves the other buttons, knob turns and the Navigate knob turn to \(shiftText). Shift itself always sends on channel \(model.config.channel).")
            } else {
                note("Sends 127 when pressed and 0 when released. With Shift held: the same CC on \(shiftText).")
            }
            if b.hasPrefix("Octave") { note("Also transposes the keys on the keyboard itself.") }
            if lightSlot[b] != nil {
                note("Its light glows dimly while it has a CC and lights fully while held; a DAW can light it by sending the CC back to the \(model.config.portName) output.")
            }
        }
    }

    @ViewBuilder private func midiKnob(_ k: Int) -> some View {
        Section("Knob \(k + 1)") {
            IntField(title: "Turn CC", value: $model.config.knobCCs[k], range: 0...127)
            if model.knobTouchOn {
                IntField(title: "Touch CC", value: $model.config.knobTouchCCs[k], range: 0...127)
            }
            note("With Shift held, the turn goes out on \(shiftText), with its own value.")
        }
        Section("All eight knobs") {
            Picker("Turn values", selection: $model.config.knobMode) {
                ForEach(turnModes, id: \.self) { Text(turnModeTitle($0)).tag($0) }
            }
            IntField(title: "Knob units per step", value: $model.config.knobStepsPerCC, range: 1...50)
            Toggle("Send touch CCs", isOn: $model.knobTouchOn)
            note("Absolute starts at 64 and works with plain MIDI learn; relative modes suit endless knobs if your DAW is told which format to expect. More units per step: finer and slower.")
        }
    }

    @ViewBuilder private func midiNavigate() -> some View {
        Section("Turn") {
            CCField(title: "CC", value: $model.config.navigateTurnCC, fallback: 30)
            Picker("Values", selection: $model.config.navigateTurnMode) {
                ForEach(turnModes, id: \.self) { Text(turnModeTitle($0)).tag($0) }
            }
        }
        Section("Touch") {
            CCField(title: "CC", value: $model.config.navigateTouchCC, fallback: 31)
        }
        Section("Press") {
            CCField(title: "CC", value: midiCC("NavigateClick"), fallback: 90)
        }
    }

    // MARK: REAPER page

    /// The Shift layer's channel; with the layer off, Shift + a button sends on the base channel.
    private var shiftChannel: Int { model.config.shiftChannel ?? model.config.channel }

    /// When a button's CC goes out in REAPER mode: when its press, or its Shift + press, has no REAPER command.
    private func ccWhen(_ b: String) -> String? {
        let ch = model.config.channel, sh = shiftChannel
        switch (model.command(b, shift: false) == nil, model.command(b, shift: true) == nil) {
        case (true, true):
            return sh == ch ? "Sent on channel \(ch) when pressed, with or without Shift."
                            : "Sent on channel \(ch) when pressed, and on channel \(sh) with Shift held."
        case (true, false): return "Sent on channel \(ch) when pressed without Shift."
        case (false, true): return "Sent on channel \(sh) when pressed with Shift held."
        case (false, false): return nil
        }
    }

    /// The button's MIDI CC, editable here while it's sent in REAPER mode (the MIDI page is hidden then).
    @ViewBuilder private func reaperCCSection(_ b: String) -> some View {
        if let when = ccWhen(b) {
            Section("MIDI CC") {
                CCField(title: "CC", value: midiCC(b), fallback: defaultCC(b))
                note(when + " 127 when pressed, 0 when released.")
            }
        }
    }

    @ViewBuilder private func reaperButton(_ b: String) -> some View {
        if b == "Shift" {
            Section("REAPER") {
                note("Shift isn't a REAPER command: holding it selects the Shift + press commands, and sends the CC of a button with no Shift + press command on channel \(shiftChannel).")
            }
            Section("MIDI CC") {
                CCField(title: "CC", value: midiCC(b), fallback: defaultCC(b))
                note("Shift itself sends this on channel \(model.config.channel) when pressed and released, in REAPER mode too.")
            }
        } else {
            let cc = model.midiCC(b).map { "CC \($0)" } ?? "nothing (its CC is off)"
            Section("Press") {
                CommandPicker(title: "Command", command: command(b, shift: false), noneTitle: "Send its MIDI CC (\(cc))")
            }
            Section("Shift + press") {
                CommandPicker(title: "Command", command: command(b, shift: true),
                              noneTitle: "Send its MIDI CC on channel \(shiftChannel)")
            }
            reaperCCSection(b)
            if let v = model.kkCC(b) {
                Section("In the Komplete Kontrol view") {
                    note("This button sends CC \(v) there instead. See the Komplete Kontrol page.")
                }
            }
        }
    }

    @ViewBuilder private func reaperKnob(_ k: Int) -> some View {
        Section("What it controls") {
            LabeledContent("Mix view", value: "Volume of track \(k + 1) of the bank")
            LabeledContent("Mix view + Shift", value: "Pan of track \(k + 1) of the bank")
            LabeledContent("Track view", value: "\(trackViewTargets[k]) (page 1)")
            LabeledContent("Komplete Kontrol view", value: "CC \(model.config.reaper.kompleteKontrol.encoderCCs[k])")
            note("Track view pages 2 and on: sends 4–11, 12–16. Track view, Shift + turn: the volume goes to 0 dB, the pan to centre, record arm sets monitoring; other knobs send their MIDI CC on \(shiftText).")
        }
        Section("All knobs in REAPER mode") {
            IntField(title: "Units for a full fader", value: $model.config.reaper.knobFullRange, range: 10...5000, step: 50)
            note("Raw knob units for a fader's whole range: lower is faster.")
        }
    }

    @ViewBuilder private func reaperNavigate() -> some View {
        Section("Turn") {
            Picker("Turn", selection: $model.config.reaper.navigateTurn) {
                Text(navigateTurnTitle("tracks", cc: nil)).tag(Optional("tracks"))
                Text(navigateTurnTitle("pages", cc: nil)).tag(Optional("pages"))
                Text(navigateTurnTitle(nil, cc: model.config.navigateTurnCC)).tag(String?.none)
            }
            CCField(title: "CC", value: $model.config.navigateTurnCC, fallback: 30)
            switch model.config.reaper.navigateTurn {
            case nil:
                note("Turning sends this CC on channel \(model.config.channel), and on channel \(shiftChannel) with Shift held.")
            case "tracks":
                note("Picking a track from Mix view also switches to Track view. With Shift held, turning sends this CC on channel \(shiftChannel) instead.")
            default:
                note("With Shift held, turning sends this CC on channel \(shiftChannel) instead.")
            }
        }
        Section("Press") {
            CommandPicker(title: "Command", command: command("NavigateClick", shift: false),
                          noneTitle: "Send its MIDI CC (\(model.midiCC("NavigateClick").map { "CC \($0)" } ?? "off"))")
        }
        Section("Shift + press") {
            CommandPicker(title: "Command", command: command("NavigateClick", shift: true),
                          noneTitle: "Send its MIDI CC on channel \(shiftChannel)")
        }
        reaperCCSection("NavigateClick")
    }

    // MARK: Komplete Kontrol page

    @ViewBuilder private func kkButton(_ b: String) -> some View {
        if b == "Shift" {
            Section("Komplete Kontrol view") { note("Shift keeps its job in this view and can't send a CC here.") }
        } else {
            Section("Komplete Kontrol view") {
                CCField(title: "CC on channel \(model.config.reaper.kompleteKontrol.channel)", value: kkCC(b), fallback: 44,
                        offText: "Off")
                if model.kkCC(b) == nil {
                    let job = model.command(b, shift: false).map(commandTitle) ?? "sending its MIDI CC"
                    note("Off here: in this view the button keeps its REAPER job (\(job)).")
                } else {
                    note("Sends 127 when pressed and 0 when released. Komplete Kontrol's NKS template decides what it does, such as the next page or preset.")
                }
            }
        }
    }

    @ViewBuilder private func kkKnob(_ k: Int) -> some View {
        Section("Knob \(k + 1)") {
            IntField(title: "CC", value: $model.config.reaper.kompleteKontrol.encoderCCs[k], range: 0...127)
            note("Its display on the keyboard reads ENCODER \(k + 1), with a bar of the value it last sent.")
        }
        kkKnobSettings
    }

    @ViewBuilder private var kkKnobSettings: some View {
        Section("All knobs in this view") {
            IntField(title: "MIDI channel", value: $model.config.reaper.kompleteKontrol.channel, range: 1...16)
            Picker("Turn values", selection: $model.config.reaper.kompleteKontrol.encoderMode) {
                ForEach(turnModes, id: \.self) { Text(turnModeTitle($0)).tag($0) }
            }
            note("Komplete Kontrol's NKS template reads absolute values; relative values left its parameters stuck near 50%. Like Novation's Launchkey, the bridge keeps one set of 8 knob values for every page, track and preset; Komplete Kontrol's parameter names and values aren't available to it.")
        }
    }

    @ViewBuilder private func kkNavigate() -> some View {
        Section("Turn") {
            note("\(navigateTurnTitle(model.config.reaper.navigateTurn, cc: model.config.navigateTurnCC)), as in the other REAPER views (change it on the REAPER page).")
        }
        kkButton("NavigateClick")
    }
}
