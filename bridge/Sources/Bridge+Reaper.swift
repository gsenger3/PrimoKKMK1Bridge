//
//  Bridge+Reaper.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  REAPER mode in the bridge: starting the OSC session, reacting to REAPER's events, the Komplete Kontrol
//  view's per-page knob memory, and screenset names.

import Foundation

extension Bridge {
    func startReaper() {
        guard cfg.reaper.enabled else { return }
        do {
            let s = try ReaperSession(cfg: cfg.reaper)
            s.onSend = { [weak self] address, args in
                guard let self, self.verbose else { return }
                self.log("→ REAPER \(address) " + args.map(\.description).joined(separator: " "))
            }
            s.onEvent = { [weak self] in self?.reaperEvent($0) }
            if logOSC {
                // Everything REAPER sends, except the clock and meters that stream during playback.
                let noisy = ["/time", "/beat", "/samples", "/frames", "/vu", "/lastmarker", "/lastregion"]
                s.onReceive = { [weak self] address, args in
                    guard !noisy.contains(where: { address.hasPrefix($0) || address.hasSuffix($0) }) else { return }
                    self?.log("← REAPER \(address) " + args.map(\.description).joined(separator: " "))
                }
            }
            reaper = s
            s.handshake()
        } catch {
            fail("\(error)")
        }
    }

    /// A window set's name from REAPER's reaper-screensets.ini ([sset0] is window set 1), read on each use so
    /// renames show up; nil if it has none or the file can't be read.
    func screensetName(_ n: Int) -> String? {
        let path = (cfg.reaper.resourcePath as NSString).expandingTildeInPath + "/reaper-screensets.ini"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if section == "sset\(n - 1)", line.hasPrefix("name=") {
                let name = String(line.dropFirst(5))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    func reaperEvent(_ e: ReaperEvent) {
        guard let r = reaper else { return }
        switch e {
        case .connected:
            log("REAPER connected (OSC on port \(cfg.reaper.receivePort))")
        case .track:
            if verbose && r.track.number != loggedTrack {
                loggedTrack = r.track.number
                log("REAPER selected track \(r.track.number) \"\(r.track.name)\"")
            }
            // Moving a fader makes REAPER select that track (the device follows the last touched track);
            // don't cover the displays with its name while you're adjusting.
            let adjusting = (0..<8).contains { k in prev.map { isSet($0, knobTouchFirstBit + k) } ?? false }
            if !adjusting { showTrackOverlay() }
        case .view:
            if verbose { log("REAPER \(r.view.configName) view") }
            overlay = nil  // show the new knob layout at once
        case .trackData:
            trackDataArrived()
        case .pluginShown(let n):
            let list = r.plugins, name = pluginName(r.fxNames[n])
            if verbose { log("REAPER plugin window: \(n + 1) \"\(r.fxNames[n])\"") }
            showMessage("FX \((list.firstIndex(of: n) ?? 0) + 1)/\(list.count)", name)
        case .pluginsClosed:
            showMessage("FX", "windows closed")
        case .panic:
            showMessage("PANIC", "all notes off", seconds: 1)
        case .saved:
            showMessage("SAVE", "project saved", seconds: 1)
        case .render:
            showMessage("RENDER", "render dialog", seconds: 1)
        case .screenset(let n):
            showMessage("SCREEN", "set \(n)", extra: screensetName(n) ?? "", seconds: 1.5)
        case .noPlugins:
            showMessage("FX", "no plugins on this track")
        case .recordMode:
            if verbose { log("REAPER record mode: \(r.autoPunch ? "time selection auto-punch" : "normal")") }
            showMessage("REC MODE", r.autoPunch ? "Auto punch" : "Normal", r.autoPunch ? "time sel." : "")
        case .bank, .values, .transport:
            break
        }
        scheduleLights()
        scheduleDisplays()
    }
}
