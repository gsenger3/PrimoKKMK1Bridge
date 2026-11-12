//
//  Bridge+Displays.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  What the displays show: CC values, REAPER's tracks and values, track-change overlays and short notices.

import Foundation
import IOKit.hid

/// A message across the displays for a moment after a change; drawn from the current state, so names
/// that arrive later still show up.
struct TrackOverlay {
    let since: Date    // when another track was selected
    var lastData: Date // when REAPER last sent a value of the selected track
    let hold: Double   // reaper.trackNameSeconds
    /// Shown for `hold` seconds after the last track change, and in any case until REAPER has gone quiet about
    /// the new track for 0.25 s (but no longer than 1.5 s for that, in case values keep streaming).
    var until: Date {
        max(since.addingTimeInterval(hold),
            min(lastData.addingTimeInterval(0.25), since.addingTimeInterval(max(hold, 1.5))))
    }
}

extension Bridge {
    // MARK: displays

    /// A notice across the displays: label on the left, then `top` across the rest, or with `extra`, `top` on
    /// the second display only and `extra` from the third on.
    func showMessage(_ label: String, _ top: String, _ bottom: String = "", extra: String = "", seconds: Double = 1.5) {
        message = (label, top, bottom, extra, Date().addingTimeInterval(seconds))
        scheduleDisplays()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.02) { [weak self] in self?.scheduleDisplays() }
    }

    /// After a track change: just the track's number and name, until REAPER has sent the new track's values.
    func showTrackOverlay() {
        let now = Date()
        overlay = TrackOverlay(since: now, lastData: now, hold: cfg.reaper.trackNameSeconds)
        overlayChanged()
    }

    func trackDataArrived() {
        guard var o = overlay, o.until > Date() else { return }
        o.lastData = Date()
        overlay = o
        overlayChanged()
    }

    private func overlayChanged() {
        scheduleDisplays()
        guard let o = overlay else { return }
        let wait = max(0, o.until.timeIntervalSinceNow) + 0.02
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.scheduleDisplays() }
    }

    /// Redraw at most every 40 ms; only rows that changed are sent.
    func scheduleDisplays() {
        guard cfg.displays, device != nil || immediate else { return }
        if immediate {
            renderDisplays()
            flushDisplays()
            return
        }
        guard !displayFlushPending else { return }
        displayFlushPending = true
        let wait = max(0, 0.04 - Date().timeIntervalSince(lastDisplayFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [self] in
            displayFlushPending = false
            lastDisplayFlush = Date()
            renderDisplays()
            flushDisplays()
        }
    }

    func flushDisplays(force: Bool = false) {
        guard cfg.displays else { return }
        var changed = false
        for row in 0..<3 {
            var rep = displays.report(row: row)
            guard force || rep != displaySent[row] else { continue }
            changed = true
            displaySent[row] = rep
            guard let dev = device else { continue }
            let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportDisplay), &rep, rep.count)
            if st != kIOReturnSuccess, !displayFailed {
                displayFailed = true
                log("display report failed: 0x\(String(st, radix: 16))")
            }
        }
        if changed { onDisplayFrame?(displays.ascii()) }
    }

    /// The keyboard blanks its displays by itself on some button presses (Preset up/down, seen 2026-11-08), and
    /// the row diffing would never resend text that hasn't changed, so resend everything just after any button
    /// press or release.
    func refreshDisplaysSoon() {
        guard cfg.displays, device != nil, !forcedRefreshPending else { return }
        forcedRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            forcedRefreshPending = false
            renderDisplays()
            flushDisplays(force: true)
        }
    }

    func blankDisplays() {
        guard cfg.displays, device != nil else { return }
        displays.clear()
        flushDisplays(force: true)
    }

    func renderDisplays() {
        displays.clear()
        let touched = Set((0..<8).filter { k in prev.map { isSet($0, knobTouchFirstBit + k) } ?? false })
        if let r = reaper {
            renderReaper(r, touched)
        } else if cfg.reaper.enabled, reaperError != nil {
            renderReaperError()
        } else {
            renderMIDI(touched)
        }
    }

    /// REAPER mode without an OSC link (startReaper tries again every 3 seconds): say why.
    func renderReaperError() {
        displays.write(row: 0, cell: 0, "REAPER")
        displays.write(row: 1, cell: 0, "ERROR")
        displays.write(row: 0, cell: 1, reaperErrorShort, span: 8)
        displays.write(row: 1, cell: 1, "trying again every 3 seconds", span: 8)
    }

    /// Touched knobs get a framed value bar; everything else stays where it is.
    func renderMIDI(_ touched: Set<Int>) {
        let shiftHeld = prev.map { isSet($0, shiftBit) } ?? false
        let ch = (shiftHeld ? cfg.shiftChannel : nil) ?? cfg.channel
        displays.write(row: 0, cell: 0, "MIDI")
        displays.write(row: 1, cell: 0, "CH \(ch)")
        for k in 0..<8 {
            let cc = cfg.knobCCs[k]
            displays.write(row: 0, cell: k + 1, "CC \(cc)")
            if cfg.knobMode == .absolute {
                let v = absValues[ch * 128 + cc] ?? 64
                displays.write(row: 1, cell: k + 1, "\(v)")
                displays.setBar(cell: k + 1, Double(v) / 127, framed: touched.contains(k))
            } else {
                displays.write(row: 1, cell: k + 1, "REL")
                displays.setBar(cell: k + 1, nil, framed: touched.contains(k))
            }
        }
    }

    func renderReaper(_ r: ReaperSession, _ touched: Set<Int>) {
        let targets = (0..<8).map { r.target($0) }
        let shiftHeld = prev.map { isSet($0, shiftBit) } ?? false
        // While Shift is held, a knob shows what Shift + turn changes: the pan in mix view, monitoring on record arm.
        func info(_ k: Int, _ t: KnobTarget) -> KnobInfo {
            guard shiftHeld else { return r.info(t) }
            if t == .recArm { return r.monitorInfo }
            return r.shiftTarget(k).map { r.info($0) } ?? r.info(t)
        }
        for k in 0..<8 {
            guard let t = targets[k] else { displays.setBar(cell: k + 1, nil, framed: false); continue }
            let i = info(k, t)
            let framed = touched.contains(k)
            if i.isPan { displays.setPanBar(cell: k + 1, i.bar, framed: framed) } else { displays.setBar(cell: k + 1, i.bar, framed: framed) }
        }
        guard r.connected else {
            displays.write(row: 0, cell: 0, "REAPER")
            displays.write(row: 0, cell: 1, "waiting for OSC from REAPER", span: 8)
            displays.write(row: 1, cell: 1, "on port \(cfg.reaper.receivePort)", span: 8)
            return
        }
        if let m = message, m.until > Date() {
            for k in 0..<8 { displays.setBar(cell: k + 1, nil, framed: false) }
            displays.write(row: 0, cell: 0, m.label)
            if m.extra.isEmpty {
                displays.write(row: 0, cell: 1, m.top, span: 8)
            } else {
                displays.write(row: 0, cell: 1, m.top)
                displays.write(row: 0, cell: 2, m.extra, span: 7)
            }
            displays.write(row: 1, cell: 1, m.bottom, span: 8)
            return
        }
        message = nil
        if let o = overlay, o.until > Date() {
            for k in 0..<8 { displays.setBar(cell: k + 1, nil, framed: false) }
            displays.write(row: 0, cell: 0, r.track.number.isEmpty ? "" : "TRK \(r.track.number)")
            displays.write(row: 0, cell: 1, r.track.exists ? r.track.label : "no track selected", span: 8)
            return
        }
        overlay = nil
        switch r.view {
        case .kk:
            // Like Novation's Launchkey: Komplete Kontrol's parameter names and values aren't available, so each
            // display shows its knob's number, and a bar of the value the knob last sent (absolute values).
            let kk = cfg.reaper.kompleteKontrol
            // The left display: the selected track (whose plugin the knobs are on), and KONTROL for the view.
            displays.write(row: 0, cell: 0, abbreviate(r.track.exists ? r.track.label : "NO TRACK", cellWidth))
            displays.write(row: 1, cell: 0, "KONTROL")
            for k in 0..<8 {
                displays.write(row: 0, cell: k + 1, "ENCODER")
                displays.write(row: 1, cell: k + 1, "\(k + 1)")
                let v = kk.encoderMode == .absolute ? absValues[kk.channel * 128 + kk.encoderCCs[k]] ?? 64 : nil
                displays.setBar(cell: k + 1, v.map { Double($0) / 127 }, framed: touched.contains(k))
            }
            return
        case .mix:
            let numbers = r.bank.filter(\.exists).map(\.number)
            displays.write(row: 0, cell: 0, shiftHeld ? "PAN" : "MIX")
            displays.write(row: 1, cell: 0, numbers.isEmpty ? "NO TRKS" : "\(numbers.first!)-\(numbers.last!)")
        case .track:
            displays.write(row: 0, cell: 0, abbreviate(r.track.exists ? r.track.label : "NO TRACK", cellWidth))
            displays.write(row: 1, cell: 0, r.sendPage == 0 ? "TRK \(r.track.number)" : "PAGE \(r.sendPage + 1)/\(r.sendPages)")
        }
        for k in 0..<8 {
            guard let t = targets[k] else { continue }
            let i = info(k, t)
            displays.write(row: 0, cell: k + 1, abbreviate(i.short, cellWidth))
            displays.write(row: 1, cell: k + 1, fitValue(i.value, cellWidth))
        }
    }
}
