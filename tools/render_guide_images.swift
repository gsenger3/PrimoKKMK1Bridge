//
//  render_guide_images.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/11/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Draws the keyboard pictures for doc/GUIDE.md with the editor's own panel drawing (PanelView) and the default
//  settings, at twice the size, so they always match the editor and the defaults. Run tools/render_guide_images.sh.

import AppKit
import SwiftUI

@main
struct RenderGuideImages {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)  // draws offscreen; no window appears
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = EditorModel()

        func render(_ page: EditorPage, reaperMode: Bool, name: String) {
            var config = Config()  // every default
            config.reaper.enabled = reaperMode
            model.config = config
            model.page = page
            model.selection = nil
            let size = CGSize(width: panelSize.width * 2, height: panelSize.height * 2)
            let host = NSHostingView(rootView: PanelView().environmentObject(model).frame(width: size.width, height: size.height))
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = out.appendingPathComponent(name + ".png")
            try! rep.representation(using: .png, properties: [:])!.write(to: file)
            print("wrote \(file.path)")
        }

        render(.midi, reaperMode: false, name: "keyboard-midi")
        render(.reaper, reaperMode: true, name: "keyboard-reaper")
        render(.kk, reaperMode: true, name: "keyboard-komplete-kontrol")
    }
}
