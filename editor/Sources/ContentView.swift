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
//  The editor window: the toolbar (page, bridge status, Save), the drawn panel with the inspector beside it
//  (or the Settings page), and the status bar with validation messages.

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
        .navigationTitle("PrimoKKMK1Bridge Editor")
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
                BridgeStatus()
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
            }
        }
    }

    /// What this page edits. (The REAPER and Komplete Kontrol pages only show while REAPER mode is on.)
    private var pageBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(pageDescription).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var pageDescription: String {
        switch model.page {
        case .midi:
            let base = "MIDI: the CC each control sends (channel \(model.config.channel); Shift layer on \(model.config.shiftChannel.map { "channel \($0)" } ?? "off"))."
            return model.config.reaper.enabled ? base + " In REAPER mode, buttons without a REAPER command still send these." : base
        case .reaper: return "REAPER: the command each button runs, alone and with Shift. Instance switches the views: Mix → Track → Komplete Kontrol."
        case .kk: return "Komplete Kontrol view: the CCs the knobs and chosen buttons send for Komplete Kontrol's NKS template. Other buttons keep their REAPER jobs."
        case .settings: return ""
        }
    }
}

/// Whether the bridge is running (its MIDI port exists).
struct BridgeStatus: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.bridgeRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(model.bridgeRunning ? "Bridge running" : "Bridge not running")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help(model.bridgeRunning
              ? "The bridge's MIDI port is up. Saving makes it restart with the new settings."
              : "No MIDI port named \(model.config.portName) yet. Start the bridge with --config pointing at this file.")
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
