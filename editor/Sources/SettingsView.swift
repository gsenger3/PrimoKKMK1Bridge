//
//  SettingsView.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The Settings page: the bridge-wide options that aren't tied to one control (MIDI port and channels, the
//  keyboard merge, lights and displays, the REAPER connection and views).

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: EditorModel
    @State private var scriptStatus = ReaperScriptInstaller.Status()

    private var shiftOn: Binding<Bool> {
        Binding(get: { model.config.shiftChannel != nil }, set: { model.config.shiftChannel = $0 ? 2 : nil })
    }

    private var shiftChannel: Binding<Int> {
        Binding(get: { model.config.shiftChannel ?? 2 }, set: { model.config.shiftChannel = $0 })
    }

    /// keyboardSource: "auto", a MIDI source name, or null.
    private var keysChoice: Binding<String> {
        Binding(
            get: {
                switch model.config.keyboardSource {
                case nil: return "none"
                case "auto"?: return "auto"
                default: return "name"
                }
            },
            set: { c in
                switch c {
                case "none": model.config.keyboardSource = nil
                case "auto": model.config.keyboardSource = "auto"
                default: if model.config.keyboardSource == "auto" || model.config.keyboardSource == nil {
                    model.config.keyboardSource = "KOMPLETE KONTROL S61 Port 1"
                }
                }
            })
    }

    private var keysName: Binding<String> {
        Binding(get: { model.config.keyboardSource ?? "" }, set: { model.config.keyboardSource = $0 })
    }

    private var startView: Binding<String> { $model.config.reaper.view }

    var body: some View {
        Form {
            Section("MIDI Configuration") {
                TextField("Port name", text: $model.config.portName)
                IntField(title: "Channel", value: $model.config.channel, range: 1...16)
                Toggle("Shift Layer Enabled", isOn: shiftOn)
                if model.config.shiftChannel != nil {
                    IntField(title: "Shift Layer Channel", value: shiftChannel, range: 1...16)
                }
                Text("The name DAWs see for the bridge's MIDI input and output. Renaming it means picking it again in your DAW. With the Shift layer on, buttons and knobs send on its channel while Shift is held.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("MIDI Keys & Controls") {
                Picker("Merge Keys and Controls", selection: keysChoice) {
                    Text("Automatic (Port 1)").tag("auto")
                    Text("From MIDI Source by Name").tag("name")
                    Text("Disabled").tag("none")
                }
                if keysChoice.wrappedValue == "name" {
                    TextField("MIDI source name", text: keysName)
                }
                Text("Merged, one DAW input carries the keys, strips and the bridge's controls. Don't give a track both ports, or every note arrives twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Lights and Displays") {
                Toggle("Enabled", isOn: $model.config.lights)
                if model.config.lights {
                    IntField(title: "Active Brightness", value: $model.config.lightBrightness, range: 0...255)
                    IntField(title: "Idle Brightness", value: $model.config.lightIdleBrightness, range: 0...255)
                }
                Toggle("Enable Displays", isOn: $model.config.displays)
            }

            Section("REAPER Mode") {
                Toggle("Enabled", isOn: $model.config.reaper.enabled)
                // Everything else about REAPER and the Komplete Kontrol view only shows while REAPER mode is on.
                if model.config.reaper.enabled {
                    TextField("Address", text: $model.config.reaper.host)
                    IntField(title: "Local Listen Port", value: $model.config.reaper.sendPort, range: 1...65535)
                    IntField(title: "Device Port", value: $model.config.reaper.receivePort, range: 1...65535)
                    Text("These match REAPER's Preferences ▸ Control/OSC/web ▸ OSC device: Local listen port (default 8000) and Device port (default 9000).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.config.reaper.enabled {
                reaperViews
                lightGuideSettings
                kompleteKontrolView
            }

            Section {
                Button("Reset to Default Settings…") {
                    let a = NSAlert()
                    a.messageText = "Reset every assignment to its default?"
                    a.informativeText = "REAPER mode stays as it is. Nothing is written until you save."
                    a.addButton(withTitle: "Reset")
                    a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { model.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var reaperViews: some View {
        Section("REAPER Views") {
            Picker("Default View", selection: startView) {
                Text("Mix view").tag("mix")
                Text("Track view").tag("track")
                Text("Komplete Kontrol view").tag("komplete-kontrol")
            }
            Toggle("Follow REAPER Track Selection", isOn: $model.config.reaper.followSelectedTrack)
            Toggle("Select Active Keyboard Track in REAPER (Track View)", isOn: $model.config.reaper.mirrorSelection)
            LabeledContent("Track Name Display Duration") {
                HStack {
                    TextField("", value: $model.config.reaper.trackNameSeconds, format: .number.precision(.fractionLength(0...1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 48)
                    Stepper("", value: $model.config.reaper.trackNameSeconds, in: 0...30, step: 0.5).labelsHidden()
                    Text("seconds")
                }
            }
            TextField("REAPER Resource Folder", text: $model.config.reaper.resourcePath)
            Text("The resource folder is where REAPER keeps reaper-screensets.ini, for the screenset names on the displays.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lightGuideSettings: some View {
        Section("Reaper Lightguide") {
            Toggle("Enable Lightguide", isOn: $model.config.reaper.lightGuide)
            if model.config.reaper.lightGuide {
                LabeledContent("Brightness") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.config.reaper.lightGuideBrightness) },
                                              set: { model.config.reaper.lightGuideBrightness = Int($0.rounded()) }),
                               in: 5...100, step: 5)
                            .frame(width: 180)
                        Text("\(model.config.reaper.lightGuideBrightness)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            LabeledContent("REAPER Integration") {
                HStack(spacing: 8) {
                    Text(scriptStatusText).foregroundStyle(.secondary)
                    if scriptStatus.anyInstalled {
                        if !scriptStatus.installed {
                            Button(scriptStatus.scriptInstalled && !scriptStatus.scriptUpToDate ? "Update…" : "Repair…") { installScript() }
                        }
                        Button("Uninstall…") { uninstallScript() }
                    } else {
                        Button("Install…") { installScript() }
                            .disabled(!scriptStatus.resourceFolderFound)
                    }
                }
            }
            Text("Enables the keyboard lightguide integration within Reaper. When enabled, the device lightguide will display the currently selected track color. Installation will install a Reaper script to the current user's Reaper Scripts folder. The lightguide will be active upon restart of Reaper. ")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { refreshScriptStatus() }
        .onChange(of: model.config.reaper.resourcePath) { _, _ in refreshScriptStatus() }
    }

    private func refreshScriptStatus() {
        scriptStatus = ReaperScriptInstaller.status(resourcePath: model.config.reaper.resourcePath)
    }

    private var scriptStatusText: String {
        let s = scriptStatus
        if !s.resourceFolderFound { return "REAPER's resource folder not found" }
        if s.installed { return "Installed; REAPER starts it" }
        if s.scriptInstalled && !s.scriptUpToDate { return "An older version is installed" }
        if s.scriptInstalled { return "Installed, but REAPER doesn't start it" }
        if s.startsWithREAPER { return "REAPER starts it, but the script is missing" }
        return "Not installed"
    }

    private func installScript() {
        let resource = ReaperScriptInstaller.resourceURL(model.config.reaper.resourcePath)
        let confirm = NSAlert()
        confirm.messageText = "Install the track colour script in REAPER?"
        confirm.informativeText = """
            This copies PrimoKKMK1Bridge_TrackColor.lua to Scripts/\(ReaperScriptInstaller.folderName) in \(resource.path), \
            and adds a line to Scripts/__startup.lua so REAPER starts it (an existing __startup.lua is backed up first).
            """
        confirm.addButton(withTitle: "Install")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let result = NSAlert()
        do {
            let done = try ReaperScriptInstaller.install(resourcePath: model.config.reaper.resourcePath)
            result.messageText = "Installed the track colour script"
            result.informativeText = done.joined(separator: "\n") + """


                Two steps left in REAPER:
                1. Preferences ▸ Audio ▸ MIDI Outputs: enable Primo Komplete Kontrol MK1.
                2. Restart REAPER (or run the script once from the Action List).
                """
        } catch {
            result.alertStyle = .warning
            result.messageText = "Couldn't install the script"
            result.informativeText = "\(error)"
        }
        result.runModal()
        refreshScriptStatus()
    }

    private func uninstallScript() {
        let resource = ReaperScriptInstaller.resourceURL(model.config.reaper.resourcePath)
        let confirm = NSAlert()
        confirm.messageText = "Uninstall the track colour script from REAPER?"
        confirm.informativeText = """
            This removes PrimoKKMK1Bridge_TrackColor.lua from Scripts/\(ReaperScriptInstaller.folderName) in \(resource.path), \
            and the line that starts it from Scripts/__startup.lua (which is backed up first). Your other scripts stay.
            """
        confirm.addButton(withTitle: "Uninstall")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let result = NSAlert()
        do {
            let done = try ReaperScriptInstaller.uninstall(resourcePath: model.config.reaper.resourcePath)
            result.messageText = "Uninstalled the track colour script"
            result.informativeText = done.joined(separator: "\n") + """


                If REAPER is open, the script keeps running until you restart REAPER. You can also turn off \
                Primo Komplete Kontrol MK1 under Preferences ▸ Audio ▸ MIDI Outputs if nothing else uses it.
                """
        } catch {
            result.alertStyle = .warning
            result.messageText = "Couldn't uninstall the script"
            result.informativeText = "\(error)"
        }
        result.runModal()
        refreshScriptStatus()
    }

    private var kompleteKontrolView: some View {
        Section("Komplete Kontrol View") {
            IntField(title: "MIDI Channel", value: $model.config.reaper.kompleteKontrol.channel, range: 1...16)
            Picker("Knob Values", selection: $model.config.reaper.kompleteKontrol.encoderMode) {
                ForEach(turnModes, id: \.self) { Text(turnModeTitle($0)).tag($0) }
            }
        }
    }
}
