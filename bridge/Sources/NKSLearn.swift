//
//  NKSLearn.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/13/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Learned NKS pages (issues #30-#33): for instruments whose pages the bridge can't read, such as Kontakt instruments
//  and NI's own synths, you teach them. In learn mode (Shift + Instance in the Komplete Kontrol view) you touch a knob,
//  then move a control in Komplete Kontrol's window, and REAPER's last-touched parameter ("107 Balance") goes on that
//  knob. The pages are kept in NKSPages.json (LearnedPages.swift), next to the config, under the instrument's key: the
//  plugin ID and the fingerprint of its parameter names, both from the REAPER script (SysEx 03 and 05).

import Foundation

extension NKSLayout {
    init(pages: [[NKSSlot?]]) { self.pages = pages }
}

extension LearnedPages {  // the file's format and place: LearnedPages.swift
    /// An instrument's pages as the Komplete Kontrol view uses them. The displays show REAPER's current names
    /// (autoname), as KK labels such slots.
    func layout(_ key: String) -> NKSLayout? {
        guard let i = instruments[key] else { return nil }
        return NKSLayout(pages: i.pages.map { page in
            (0..<8).map { k in page.indices.contains(k) ? page[k].map { NKSSlot(name: $0.name, id: $0.id, autoname: true) } : nil }
        })
    }
}

/// Learn mode's state: the pages being taught, the page shown, and the slot that the next control moved in KK's
/// window goes to (nil: none, after the page's last slot; Page ▶ goes on to the next page).
struct NKSLearning {
    static let emptyPage = [NKSSlot?](repeating: nil, count: 8)

    private(set) var pages: [[NKSSlot?]]
    private(set) var page = 0
    private(set) var slot: Int? = 0
    /// The slot was picked (a knob touched or turned, or learning or a page just started) since the last assignment.
    /// Moving the last-touched control again then counts as a new touch; otherwise it's the same touch going on.
    private(set) var picked = true

    /// Starting from the pages in use (learned, or the .nksf's), else one empty page.
    init(from layout: NKSLayout?) {
        pages = layout?.pages.isEmpty == false ? layout!.pages : [Self.emptyPage]
    }

    mutating func pick(_ k: Int) {
        slot = k
        picked = true
    }

    /// Put a parameter on the selected slot, and select the next; false if no slot is selected.
    mutating func assign(_ s: NKSSlot) -> Bool {
        guard let k = slot else { return false }
        pages[page][k] = s
        slot = k < 7 ? k + 1 : nil
        picked = false
        return true
    }

    mutating func clear(_ k: Int) { pages[page][k] = nil }

    /// Page ◀ / ▶: the selection to the previous or next slot, to skip one or go back to one, and across pages: ▶ on
    /// (or after) the last slot goes to the next page's first, adding an empty page after the last.
    mutating func move(forward: Bool) {
        if forward {
            if let k = slot, k < 7 {
                slot = k + 1
            } else {
                if page == pages.count - 1 { pages.append(Self.emptyPage) }
                page += 1
                slot = 0
            }
        } else if let k = slot {
            if k > 0 {
                slot = k - 1
            } else if page > 0 {
                page -= 1
                slot = 7
            }
        } else {
            slot = 7
        }
        picked = true
    }

    /// The pages to keep: without the empty pages at the end (none at all if every page is empty).
    var result: [[NKSSlot?]] {
        var p = pages
        while let last = p.last, last.allSatisfy({ $0 == nil }) { p.removeLast() }
        return p
    }
}

/// "page 1: Balance (6), Brightness (0), -, ...", for the log.
func describePages(_ pages: [[NKSSlot?]]) -> String {
    pages.enumerated().map { n, page in
        "page \(n + 1): " + page.map { $0.map { "\($0.name) (\($0.id))" } ?? "-" }.joined(separator: ", ")
    }.joined(separator: "; ")
}
