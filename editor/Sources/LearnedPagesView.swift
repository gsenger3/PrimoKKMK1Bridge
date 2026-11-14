//
//  LearnedPagesView.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/14/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Settings ▸ Komplete Kontrol View: the instruments whose NKS pages the bridge was taught (learn mode), from
//  NKSPages.json (bridge/Sources/LearnedPages.swift), with Rename and Delete (issue #34). The file isn't part of the
//  config, so a change here is written at once, and the bridge picks it up within a couple of seconds.

import AppKit
import Combine
import SwiftUI

/// The learned pages rows: a row with how many, which opens (it starts closed, as a big library makes a long list) to
/// one row per instrument. The list follows the file: it's read again when it changes (the bridge writes it when you
/// finish learn mode), checked every 2 seconds while Settings is shown.
struct LearnedPagesRows: View {
    let url: URL?  // nil: the config isn't saved yet, and the file goes next to it
    @State private var open = false
    @State private var pages = LearnedPages()
    @State private var problem: String?
    @State private var modified: Date?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if keys.isEmpty {
                header
            } else {
                DisclosureGroup(isExpanded: $open) {
                    VStack(spacing: 0) {  // divided like the form's own rows
                        ForEach(keys, id: \.self) { key in
                            Divider()
                            row(key).padding(.vertical, 7)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    header
                }
            }
        }
        .onAppear { reload(force: true) }
        .onChange(of: url) { _, _ in reload(force: true) }
        .onReceive(timer) { _ in reload() }
    }

    private var header: some View {
        LabeledContent("Learned Pages") {
            Text(summary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    /// The instruments, by name.
    private var keys: [String] {
        guard problem == nil else { return [] }
        return pages.instruments.keys.sorted {
            let a = pages.instruments[$0]!.label, b = pages.instruments[$1]!.label
            return a == b ? $0 < $1 : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    private var summary: String {
        if url == nil { return "Save the config first; they're kept next to it" }
        if let problem { return "Can't read NKSPages.json: \(problem)" }
        switch pages.instruments.count {
        case 0: return "None yet: press Shift + Instance in the Komplete Kontrol view"
        case 1: return "1 instrument"
        case let n: return "\(n) instruments"
        }
    }

    private func row(_ key: String) -> some View {
        let i = pages.instruments[key]!
        let learned = (try? Date(i.learned, strategy: .iso8601)).map { $0.formatted(date: .abbreviated, time: .omitted) }
        let details = ["\(i.pages.count) page\(i.pages.count == 1 ? "" : "s")", learned].compactMap { $0 }.joined(separator: " · ")
        return LabeledContent {
            HStack(spacing: 8) {
                Text(details).foregroundStyle(.secondary)
                Button("Rename…") { rename(key, i.label) }
                Button("Delete…") { delete(key, i.label) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(i.label.isEmpty ? "Untitled" : i.label)
                Text(LearnedPages.pluginName(key)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Read the file if it changed since it was last read (or always, with `force`).
    private func reload(force: Bool = false) {
        guard let url else { pages = LearnedPages(); problem = nil; return }
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard force || date != modified else { return }
        modified = date
        do {
            pages = try LearnedPages(contentsOf: url)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func rename(_ key: String, _ label: String) {
        let a = NSAlert()
        a.messageText = "Rename “\(label)”"
        a.informativeText = "The name is only for this list. The bridge uses the instrument itself to find its pages."
        let field = NSTextField(string: label)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != label else { return }
        change { $0.instruments[key]?.label = name }
    }

    private func delete(_ key: String, _ label: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Delete the learned pages for “\(label)”?"
        a.informativeText = "The Komplete Kontrol view goes back to the instrument's NKS presets' pages, or to CCs if it has none. You can't undo this, but you can teach the pages again with Shift + Instance."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        change { $0.instruments[key] = nil }
    }

    /// Change the file as it is now (the bridge may have written it since the list was read), and write it at once.
    private func change(_ edit: (inout LearnedPages) -> Void) {
        guard let url else { return }
        do {
            var current = try LearnedPages(contentsOf: url)
            edit(&current)
            try current.save(to: url)
        } catch {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Couldn't change NKSPages.json"
            a.informativeText = "\(error.localizedDescription)\n\n\(url.path)"
            a.runModal()
        }
        reload(force: true)
    }
}
