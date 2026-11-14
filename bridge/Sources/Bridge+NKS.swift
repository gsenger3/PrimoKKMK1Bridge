//
//  Bridge+NKS.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/13/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  NKS integration (reaper.kompleteKontrol.nksIntegration): the Komplete Kontrol view's NKS knob pages, for the
//  instrument that the selected track's Komplete Kontrol plugin hosts. The REAPER script reports that instrument
//  (SysEx 03 / 04, and 05 for the fingerprint of its parameter names; see Bridge+LightGuide.swift). Its pages are
//  the ones learned for it (NKSLearn.swift), else those of one of its presets in KK's database.
//  reaper.kompleteKontrol.nksFile, if set, pins the pages instead. Without NKS integration, the view sends CCs.

import Foundation

extension Bridge {
    /// The Komplete Kontrol view's NKS pages now: none without NKS integration; else the pinned file's, or those
    /// learned for the instrument the REAPER script reports, or its .nksf presets'.
    var currentNKSLayout: NKSLayout? {
        guard cfg.reaper.kompleteKontrol.nksIntegration else { return nil }
        if let pinned = nksLayout { return pinned }
        if let key = kkInstrumentKey, let learned = learnedPages?.layout(key) { return learned }
        return kkInstrument.flatMap { nksProducts[$0] ?? nil }?.layout
    }

    /// The instrument KK hosts, as learned pages are filed: "<plugin ID>/<fingerprint>".
    var kkInstrumentKey: String? {
        guard let id = kkInstrument, let fp = kkFingerprint else { return nil }
        return "\(id)/\(fp)"
    }

    /// The REAPER script reported the plugin KK hosts on the selected track (nil: no KK instrument there). A plugin
    /// seen before has its pages at once; a new one is looked up in the background, with no pages until then.
    func kkInstrumentReported(_ id: String?) {
        guard id != kkInstrument else { return }
        kkInstrument = id
        kkFingerprint = nil  // the fingerprint follows (SysEx 05)
        guard cfg.reaper.kompleteKontrol.nksIntegration else { return }
        cancelLearning("the instrument changed")
        readLearnedPages()
        defer { reaper?.setNKS(currentNKSLayout) }
        guard let id, nksLayout == nil, nksLookupEnabled, nksProducts[id] == nil else { return }
        nksLookup.find(id) { [weak self] found, notes in
            guard let self else { return }
            for note in notes { self.log("Komplete Kontrol: \(note)") }
            self.nksProducts[id] = .some(found)  // remembered even when there are none
            self.log(found.map { "Komplete Kontrol hosts \($0.name): \($0.layout.pages.count) NKS knob pages" }
                ?? "Komplete Kontrol hosts \(id), which has no NKS presets (.nksf): the knobs send CCs")
            if self.kkInstrument == id { self.reaper?.setNKS(self.currentNKSLayout) }
        }
    }

    /// The REAPER script reported the fingerprint of the hosted instrument's parameter names: it tells Kontakt's
    /// instruments (one plugin ID) apart, so each has its own learned pages.
    func kkFingerprintReported(_ fp: String) {
        guard fp != kkFingerprint else { return }
        kkFingerprint = fp
        guard cfg.reaper.kompleteKontrol.nksIntegration else { return }
        if verbose, let key = kkInstrumentKey { log("Komplete Kontrol instrument: \(key)") }
        cancelLearning("the instrument changed")
        readLearnedPages()
        reaper?.setNKS(currentNKSLayout)
    }

    /// reaper.kompleteKontrol.nksFile, read once (nil without it).
    func loadNKSLayout() -> NKSLayout? {
        guard let path = cfg.reaper.kompleteKontrol.nksFile else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let layout = try NKSLayout(contentsOf: url)
            log("Komplete Kontrol view: \(layout.pages.count) NKS knob pages from \(url.lastPathComponent)")
            return layout
        } catch {
            log("Komplete Kontrol view: can't use \(path): \(error)")
            return nil
        }
    }

    // MARK: learned pages

    /// Read the learned pages file if it changed since it was last read (it's edited by hand, or by the editor).
    /// A file that can't be read is logged once, and isn't written over until it reads again.
    func readLearnedPages() {
        guard let url = learnedPagesURL else { return }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard learnedPages == nil && !learnedPagesBroken || modified != learnedPagesModified else { return }
        learnedPagesModified = modified
        do {
            let pages = try LearnedPages(contentsOf: url)
            learnedPages = pages
            learnedPagesBroken = false
            if modified != nil { log("Komplete Kontrol: learned NKS pages for \(pages.instruments.count) instruments in \(url.lastPathComponent)") }
        } catch {
            learnedPages = nil
            learnedPagesBroken = true
            log("Komplete Kontrol: can't read learned NKS pages from \(url.path): \(error)")
        }
    }

    // MARK: learn mode

    /// learn-nks-pages (Shift + Instance): start teaching the instrument's NKS pages, or finish and save them.
    func toggleLearning() {
        guard let r = reaper else { return }
        if r.learning != nil {
            finishLearning()
            return
        }
        guard cfg.reaper.kompleteKontrol.nksIntegration else {
            showMessage("LEARN", "needs NKS integration", "turn it on in the editor's Settings", seconds: 2)
            return
        }
        guard r.view == .kk else { showMessage("LEARN", "only in the Komplete Kontrol view", seconds: 2); return }
        guard r.instrumentIsKK else { showMessage("LEARN", "no Komplete Kontrol on this track", seconds: 2); return }
        guard let key = kkInstrumentKey else {
            showMessage("LEARN", "waiting for the REAPER script", "to report the instrument", seconds: 2)
            return
        }
        readLearnedPages()
        guard !learnedPagesBroken else {
            showMessage("LEARN", "can't read NKSPages.json", "fix or remove it first", seconds: 2)
            return
        }
        learningKey = key
        r.startLearning(from: currentNKSLayout)
        log("Komplete Kontrol: learning NKS pages for \(key)")
    }

    /// Save what was taught under the instrument's key, and show it. With no pages left, the instrument's learned
    /// pages are forgotten. A replay keeps them in memory only, and logs them.
    private func finishLearning() {
        guard let r = reaper, let l = r.stopLearning(), let key = learningKey else { return }
        learningKey = nil
        let pages = l.result
        var all = learnedPages ?? LearnedPages()
        all.instruments[key] = pages.isEmpty ? nil : LearnedPages.Instrument(
            label: r.track.name, learned: ISO8601DateFormatter().string(from: Date()),
            pages: pages.map { $0.map { $0.map { LearnedPages.Slot(id: $0.id, name: $0.name) } } })
        if learnedPagesWritable, let url = learnedPagesURL {
            do {
                try all.save(to: url)
                learnedPagesModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            } catch {
                log("Komplete Kontrol: can't save learned NKS pages to \(url.path): \(error)")
                showMessage("LEARN", "can't save NKSPages.json", "\(error.localizedDescription)", seconds: 3)
                r.setNKS(currentNKSLayout)
                return
            }
        }
        learnedPages = all
        log(pages.isEmpty ? "Komplete Kontrol: forgot the learned NKS pages for \(key)"
            : "Komplete Kontrol: learned NKS pages for \(key): \(describePages(pages))")
        showMessage("LEARN", pages.isEmpty ? "pages forgotten" : "saved \(pages.count) page\(pages.count == 1 ? "" : "s")", seconds: 1.5)
        r.setNKS(currentNKSLayout)
    }

    /// Leave learn mode without saving, and say why.
    func cancelLearning(_ why: String) {
        guard let r = reaper, r.learning != nil else { return }
        _ = r.stopLearning()
        learningStopped(why)
    }

    /// Learn mode ended without saving (here, or in the session: another track or view): say why.
    func learningStopped(_ why: String) {
        learningKey = nil
        log("Komplete Kontrol: learning stopped, not saved: \(why)")
        showMessage("LEARN", "stopped, not saved:", why, seconds: 2)
    }
}
