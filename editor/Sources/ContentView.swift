//
//  ContentView.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The editor window: the toolbar (page, the bridge on/off switch, Save), the drawn panel with the inspector
//  beside it (or the Settings page), and the status bar with validation messages.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            if model.page == .settings {
                SettingsView()
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 12) {
                        pageBanner
                        PanelView()
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    InspectorView()
                        .frame(width: 360)
                }
            }
            Divider()
            StatusBar()
        }
        .navigationTitle("Primo KK MK1 Control Editor")
        .navigationSubtitle(model.fileName + (model.isDirty ? " — Edited" : ""))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $model.page) {
                    ForEach(model.visiblePages) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                BridgeToggle()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
            }
        }
    }

    /// What this page edits. In REAPER mode the MIDI page is the MIDI view's; the Komplete Kontrol and MIDI view pages
    /// show only while those views are on.
    private var pageBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(pageDescription).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var pageDescription: String {
        switch model.page {
        case .midi where model.editsMIDIView:
            return "MIDI view: the CCs the knobs and chosen buttons send (channel \(model.config.reaper.midiView.channel)), for anything that learns MIDI CCs. Other buttons keep their REAPER jobs."
        case .midi:
            return "MIDI: the CC each control sends (channel \(model.config.channel), the knobs on channel \(model.config.knobChannel); Shift layer on \(model.config.shiftChannel.map { "channel \($0)" } ?? "off"))."
                + (model.config.kompleteKontrolView ? " Instance switches to the Komplete Kontrol view." : "")
        case .reaper:
            let r = model.config.reaper
            let third = r.kompleteKontrolView && r.midiView.enabled ? " → Komplete Kontrol or MIDI (Shift + Play swaps them)"
                : r.kompleteKontrolView ? " → Komplete Kontrol" : r.midiView.enabled ? " → MIDI" : ""
            return "REAPER: the command each button runs, alone and with Shift. Instance switches the views: Mix → Track\(third)."
        case .kk:
            return "Komplete Kontrol view: the CCs the knobs and chosen buttons send for Komplete Kontrol's NKS template. Other buttons keep their "
                + (model.config.reaper.enabled ? "REAPER jobs." : "MIDI CCs; Instance switches back.")
        case .settings: return ""
        }
    }
}

/// The bridge switch: shows whether the bridge is running (its MIDI port is up) and starts or stops it.
struct BridgeToggle: View {
    @EnvironmentObject var model: EditorModel
    @EnvironmentObject var bridge: BridgeControl

    private var label: String {
        switch bridge.state {
        case .running: return "Bridge running"
        case .stopped: return "Bridge stopped"
        case .starting: return "Starting bridge…"
        case .stopping: return "Stopping bridge…"
        }
    }

    private var color: Color {
        switch bridge.state {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .stopped: return Color.secondary.opacity(0.5)
        }
    }

    private var help: String {
        switch bridge.state {
        case .running, .stopping:
            return "Turn off to stop the bridge, wherever it was started. Saving while it runs makes it restart with the new settings."
        case .stopped, .starting:
            return model.fileURL == nil
                ? "Save the config first: the bridge runs from a config file."
                : "Turn on to run the bridge in the background with \(model.fileName). It keeps running after you quit the editor; its log is in ~/Library/Logs/PrimoKKMK1Bridge.log."
        }
    }

    var body: some View {
        let on = bridge.state == .running || bridge.state == .starting
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Toggle("Bridge", isOn: Binding(get: { on }, set: { $0 ? model.startBridge() : bridge.stop() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(bridge.state == .starting || bridge.state == .stopping || (!on && model.fileURL == nil))
        }
        .padding(.horizontal, 12)  // room between the light / switch and the edges of the toolbar bubble
        .help(help)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            if let e = model.validationError {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                Text(e).foregroundStyle(.red).lineLimit(2)
            } else if let w = model.warnings.first {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.warnings.count > 1 ? "\(w) (and \(model.warnings.count - 1) more)" : w)
                    .lineLimit(1)
                    .help(model.warnings.joined(separator: "\n"))
            } else {
                Text(model.status).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(model.fileURL?.path ?? "Not saved yet")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
