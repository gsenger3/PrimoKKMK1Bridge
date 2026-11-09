//
//  EditorApp.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The editor app's entry point: its window, the File menu (Open, Save, Save As, Revert), the Bridge menu
//  (Start, Stop, Show Log), and the prompt to save changes before quitting.

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?

    /// Closing the window quits, unless there are unsaved changes: then the app stays open with them.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(model?.isDirty ?? false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isDirty else { return .terminateNow }
        return model.confirmDiscard(before: "quitting") ? .terminateNow : .terminateCancel
    }
}

@main
struct PrimoKKMK1EditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("Primo KK MK1 Control Editor", id: "editor") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.bridge)
                .frame(minWidth: 1180, minHeight: 620)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1440, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Config…") { model.openWithPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
                Button("Save As…") { model.saveAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Revert to Saved") { model.revert() }
                    .disabled(!model.isDirty)
            }
            CommandMenu("Bridge") {
                Button("Start Bridge") { model.startBridge() }
                Button("Stop Bridge") { model.bridge.stop() }
                Divider()
                Button("Show Bridge Log") { BridgeControl.showLog() }
            }
        }
    }
}
