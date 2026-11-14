//
//  ReaperSession.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The REAPER control surface: OSC handshake, project state as REAPER reports it, and the commands and
//  knob turns sent back.

import Darwin
import Foundation

final class ReaperSession {
    let cfg: ReaperConfig
    private let link: OSCLink
    private(set) var view: ReaperView
    private(set) var bank = [TrackStrip](repeating: TrackStrip(), count: bankSize)
    private(set) var track = TrackStrip()
    private(set) var sends = [SendStrip](repeating: SendStrip(), count: sendSlots)
    private(set) var sendPage = 0
    private(set) var playing = false, recording = false, repeating = false, metronome = false
    private(set) var fxNames = [String](repeating: "", count: fxSlots)  // the selected track's plugins
    private(set) var fxOpen = [Bool](repeating: false, count: fxSlots)  // whose floating windows are open
    private var lastShown: Int?                                          // the plugin Browse last opened
    var plugins: [Int] { fxNames.indices.filter { !fxNames[$0].isEmpty } }

    /// REAPER doesn't report the record mode over OSC, so this is the mode we last set (or saw an action report).
    private(set) var autoPunch = false
    private(set) var connected = false
    private var lastHandshake = Date.distantPast
    private var reaperPID: pid_t?               // the REAPER process on this Mac that's connected (see watch())
    /// When the bridge made its MIDI ports, this run (they're new each time it starts or restarts in place).
    var midiPortsMade: Date?
    private static var midiDevicesReset = false  // asked REAPER to reopen its MIDI devices: once per run
    private var watchTimer: DispatchSourceTimer?
    private var lastSent: [String: Date] = [:]           // address -> when a knob last set it
    private var toggleAccum = [Int](repeating: 0, count: 8)
    private var touchAddress = [String?](repeating: nil, count: 8)
    var onEvent: ((ReaperEvent) -> Void)?
    var onSend: ((String, [OSCArg]) -> Void)?
    var onReceive: ((String, [OSCArg]) -> Void)?

    // Komplete Kontrol view with NKS knob pages (NKS integration; the bridge says which, see Bridge+NKS.swift).
    private(set) var nks: NKSLayout?
    private(set) var instrumentName = ""  // the selected track's instrument plugin (/fxinst/name)
    private(set) var nksPage = 0
    /// The run of instrument parameters REAPER reports (/device/fxinstparam count and bank), as last asked for.
    private var instWindow: (count: Int, bank: Int)?
    /// What REAPER last sent for each position of that run (/fxinstparam/N/...).
    private var instParams: [Int: (name: String, value: Double?, text: String)] = [:]

    // Learn mode (NKSLearn.swift): the pages being taught, and REAPER's last-touched parameter, plugin and track.
    // REAPER sends each of those only when it changes, so the last of each is kept.
    private(set) var learning: NKSLearning?
    private var touchedParam = "", touchedFX = "", touchedTrack = ""
    private var lastTouchMessage = Date.distantPast
    private var touchPending = false, pendingNewControl = false

    init(cfg: ReaperConfig, nks: NKSLayout? = nil) throws {
        self.cfg = cfg
        self.nks = nks
        view = ReaperView.allCases.first { $0.configName == cfg.view } ?? .mix
        link = try OSCLink(host: cfg.host, sendPort: cfg.sendPort, receivePort: cfg.receivePort)
        link.onMessage = { [weak self] in self?.receive($0, $1) }
    }

    /// Slots of the selected track's sends that are routed somewhere (unused slots are left out).
    var routedSends: [Int] { sends.indices.filter { sends[$0].isRouted(slot: $0) } }
    var sendCount: Int { routedSends.count }
    /// Track view page 1: volume, pan, mute, solo, record arm and sends 1-3; each later page: 8 more sends.
    var sendPages: Int { sendCount <= 3 ? 1 : 1 + (sendCount - 3 + 7) / 8 }

    /// Send to REAPER. `quietly` leaves it out of the verbose log (the handshake repeated while waiting).
    func send(_ address: String, _ args: [OSCArg] = [.float(1)], quietly: Bool = false) {
        link.send(address, args)
        if !quietly { onSend?(address, args) }
    }

    /// Ask REAPER for 8 tracks per page and all sends of the selected track, to follow the track last clicked,
    /// and to send everything again: REAPER only sends values that changed since it last sent them, so
    /// without this a bridge started after REAPER never hears about tracks, pans or sends that haven't moved.
    func handshake(quietly: Bool = false) {
        guard Date().timeIntervalSince(lastHandshake) > 2 else { return }
        lastHandshake = Date()
        send("/device/track/count", [.int(Int32(bankSize))], quietly: quietly)
        send("/device/send/count", [.int(Int32(sendSlots))], quietly: quietly)
        send("/device/fx/count", [.int(Int32(fxSlots))], quietly: quietly)
        send("/device/fx/follows/device", quietly: quietly)
        // The bridge doesn't use plugin parameters (the Komplete Kontrol view shows none, like Novation's
        // Launchkey), so ask REAPER for as few as it allows: it otherwise sends them on every track change.
        send("/device/fxparam/count", [.int(1)], quietly: quietly)
        if cfg.followSelectedTrack { send("/device/track/follows/last_touched", quietly: quietly) }
        instWindow = nil  // asked for again when the refresh sends /fxinst/name
        send("/action", [.int(refreshSurfacesAction)], quietly: quietly)
    }

    // MARK: REAPER quitting (issue #18)

    /// Notice REAPER quitting, and find it again. OSC has no goodbye, and an idle REAPER sends nothing, so with REAPER
    /// on this Mac the bridge watches its process once a second: when the REAPER it connected to is gone (quit or
    /// crashed), the session forgets the project and waits again. While waiting, it repeats the handshake every
    /// 3 seconds, so a REAPER started later answers at once. Not for replays, which stay as recorded.
    func watch() {
        guard watchTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.checkREAPER() }
        t.resume()
        watchTimer = t
    }

    /// REAPER is on this Mac, so its process can be watched.
    var reaperIsLocal: Bool {
        let h = cfg.host.lowercased()
        return h == "localhost" || h.hasPrefix("127.") || h == "::1"
    }

    private func checkREAPER() {
        guard connected else {
            handshake(quietly: true)  // at most every 3 seconds (its own 2-second guard, on this 1-second timer)
            return
        }
        guard reaperIsLocal else { return }
        let running = Self.reaperPIDs()
        if let pid = reaperPID {
            if !running.contains(pid) { lost() }
        } else {
            reaperPID = running.first  // the REAPER that answered; none (an OSC stand-in) means nothing to watch
            if let pid = reaperPID { reopenMIDIIfStale(pid) }
        }
    }

    /// REAPER opens its MIDI devices when it starts, or when they're reset, and doesn't notice a device that goes away
    /// and comes back. A REAPER started before the bridge made its MIDI ports therefore still sends to the old ports
    /// (or has none): the REAPER script's messages (track colour, instrument) would go nowhere. So once per run, ask
    /// such a REAPER to reset its MIDI devices, which reopens all of them (seen with REAPER 7.61, 2026-11-13).
    private func reopenMIDIIfStale(_ pid: pid_t) {
        guard !Self.midiDevicesReset, let made = midiPortsMade, let started = Self.startTime(pid), started < made else { return }
        Self.midiDevicesReset = true
        send("/action", [.int(resetMIDIDevicesAction)])
        onEvent?(.midiDevicesReset)
    }

    /// When a process started.
    static func startTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    /// REAPER quit: forget its project, and wait for it again.
    private func lost() {
        connected = false
        reaperPID = nil
        lastHandshake = .distantPast
        bank = [TrackStrip](repeating: TrackStrip(), count: bankSize)
        track = TrackStrip()
        sends = [SendStrip](repeating: SendStrip(), count: sendSlots)
        sendPage = 0
        playing = false; recording = false; repeating = false; metronome = false
        fxNames = [String](repeating: "", count: fxSlots)
        fxOpen = [Bool](repeating: false, count: fxSlots)
        lastShown = nil
        lastSent = [:]
        instrumentName = ""
        nksPage = 0
        instWindow = nil
        instParams = [:]
        learning = nil
        touchedParam = ""; touchedFX = ""; touchedTrack = ""
        onEvent?(.disconnected)
    }

    /// REAPER.app's program (a test can watch a stand-in instead).
    static var processName = "REAPER"

    /// This user's REAPER processes.
    static func reaperPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return pids.prefix(min(Int(n), pids.count)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  (String(cString: path) as NSString).lastPathComponent == processName else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == getuid()
        }
    }

    func isActive(_ c: ReaperCommand) -> Bool {
        switch c {
        case .play: return playing
        case .record: return recording
        case .repeatToggle: return repeating
        case .metronome: return metronome
        case .recordMode: return autoPunch
        case .browseFX, .closeFX: return fxOpen.contains(true)
        case .toggleView: return view == .track
        case .mute: return track.mute
        case .solo: return track.solo
        case .learnNKSPages: return learning != nil
        default: return false
        }
    }

    func perform(_ c: ReaperCommand, down: Bool) {
        switch c {
        case .rewind: send("/rewind", [.float(down ? 1 : 0)]); return
        case .forward: send("/forward", [.float(down ? 1 : 0)]); return
        default: break
        }
        guard down else { return }
        switch c {
        case .play: send("/play")
        case .stop: send("/stop")
        case .record: send("/record")
        case .repeatToggle: send("/repeat")
        case .previousTrack, .nextTrack:
            // Keep the current values: REAPER only sends the ones that differ on the new track.
            lastSent = [:]
            send(c == .nextTrack ? "/device/track/+" : "/device/track/-")
            if view != .mix && cfg.mirrorSelection {
                // Track and Komplete Kontrol views: make it REAPER's selected track too (only it), and scroll it into
                // view. REAPER handles these in order, so /track/select applies to the track just moved to.
                send("/action", [.int(unselectAllTracksAction)])
                send("/track/select", [.float(1)])
                send("/action", [.int(scrollToSelectedAction)])
            }
        case .previousPage, .nextPage:
            let up = c == .nextPage
            if view == .mix {
                lastSent = [:]
                send(up ? "/device/track/bank/+" : "/device/track/bank/-")
            } else {
                let p = max(0, min(sendPages - 1, sendPage + (up ? 1 : -1)))
                if p != sendPage { sendPage = p; onEvent?(.values) }
            }
        case .toggleView:  // Instance: mix -> track -> Komplete Kontrol -> mix
            switch view {
            case .mix: show(.track)
            case .track: show(.kk)
            case .kk: show(.mix)
            }
        case .mute: send("/track/mute/toggle")
        case .metronome: send("/click")  // toggles
        case .goToStart: send("/action", [.int(goToStartAction)])
        case .previousMarker: send("/action", [.int(previousMarkerAction)])
        case .nextMarker: send("/action", [.int(nextMarkerAction)])
        case .undo: send("/action", [.int(undoAction)])
        case .redo: send("/action", [.int(redoAction)])
        case .browseFX: browsePlugins()
        case .panic:
            send("/action", [.int(panicAction)])
            onEvent?(.panic)
        case .saveProject:
            send("/action", [.int(saveProjectAction)])
            onEvent?(.saved)
        case .renderProject:
            send("/action", [.int(renderProjectAction)])
            onEvent?(.render)
        case .screenset(let n):
            send("/action", [.int(windowSet1Action + Int32(n - 1))])
            onEvent?(.screenset(n))
        case .closeFX:
            for n in plugins { send("/fx/\(n + 1)/openui", [.float(0)]); fxOpen[n] = false }
            lastShown = nil
            onEvent?(.pluginsClosed)
        case .recordMode:  // set, not toggle, so a mode changed in REAPER's window is fixed by one more press
            autoPunch.toggle()
            send("/action", [.int(autoPunch ? recordAutoPunchAction : recordNormalAction)])
            onEvent?(.recordMode)
        case .solo: send("/track/solo/toggle")
        case .action(let id): send("/action", [.int(Int32(id))])
        // MIDI Editor actions have their own command IDs, which overlap the main section's (40481 there saves
        // window set #08), so they go out as /midiaction, which REAPER runs in the open MIDI editor.
        case .midiAction(let id): send("/midiaction", [.int(Int32(id))])
        case .learnNKSPages: onEvent?(.learn)  // the bridge knows the instrument and keeps the pages
        case .rewind, .forward: break
        }
    }

    /// Browse: open the selected track's first plugin window, then on each press close it and open the next
    /// (back to the first after the last). "It" is the one Browse opened if still open, else the first open one.
    private func browsePlugins() {
        let list = plugins
        guard !list.isEmpty else { onEvent?(.noPlugins); return }
        let current = lastShown.flatMap { fxOpen[$0] ? $0 : nil } ?? list.first { fxOpen[$0] }
        var next = list[0]
        if let c = current {
            send("/fx/\(c + 1)/openui", [.float(0)])
            fxOpen[c] = false
            next = list.first { $0 > c } ?? list[0]
        }
        send("/fx/\(next + 1)/openui", [.float(1)])
        fxOpen[next] = true
        lastShown = next
        onEvent?(.pluginShown(next))
    }

    /// Switch to a view, at its first page.
    private func show(_ v: ReaperView) {
        guard v != view else { return }
        stopLearning(because: "the view changed")
        view = v
        sendPage = 0
        updateInstrumentWindow()
        onEvent?(.view)
    }

    // MARK: Komplete Kontrol view with NKS knob pages

    /// Another instrument (or none): its NKS pages, from the first.
    func setNKS(_ layout: NKSLayout?) {
        nks = layout
        nksPage = 0
        updateInstrumentWindow()
        if view == .kk { onEvent?(.values) }
    }

    /// The selected track's instrument is Komplete Kontrol.
    var instrumentIsKK: Bool { instrumentName.hasPrefix("Komplete Kontrol") }

    /// The Komplete Kontrol view shows the NKS pages: there's a layout, and the selected track's instrument is KK.
    var nksActive: Bool { nks != nil && view == .kk && instrumentIsKK }

    private func nksSlot(_ k: Int) -> NKSSlot? {
        guard nksActive, let pages = nks?.pages, pages.indices.contains(nksPage) else { return nil }
        return pages[nksPage][k]
    }

    /// Where REAPER's parameter `number` (1-based) is in the reported run, if it's in it.
    private func instPosition(_ number: Int) -> Int? {
        guard let w = instWindow else { return nil }
        let pos = number - (w.bank - 1) * w.count
        return (1...w.count).contains(pos) ? pos : nil
    }

    /// REAPER reports the instrument's parameters as a run of `count`, the `bank`th such run. Ask for the shortest
    /// run that holds every parameter on the current page (Twoism's page 1, numbers 115-133, is count 19, bank 7).
    private func updateInstrumentWindow() {
        guard nksActive, let pages = nks?.pages, pages.indices.contains(nksPage) else { return }
        let numbers = pages[nksPage].compactMap { $0.map { kkInstrumentParamBase + $0.id } }
        guard let lo = numbers.min(), let hi = numbers.max() else { return }
        var count = hi - lo + 1
        while (hi + count - 1) / count * count - count + 1 > lo { count += 1 }  // the run holding hi must start at or before lo
        let bank = (hi + count - 1) / count
        guard instWindow?.count != count || instWindow?.bank != bank else { return }
        instWindow = (count, bank)
        send("/device/fxinstparam/count", [.int(Int32(count))])
        send("/device/fxinstparam/bank/select", [.int(Int32(bank))])
    }

    /// The Komplete Kontrol view's page arrows: KK's NKS MIDI template pages back on CC 42 and on with CC 43, so the
    /// layout's page follows (it stops at the first and last page, as KK does).
    func kkButtonSent(cc: Int) {
        guard nksActive, let count = nks?.pages.count, cc == 42 || cc == 43 else { return }
        let p = max(0, min(count - 1, nksPage + (cc == 43 ? 1 : -1)))
        guard p != nksPage else { return }
        nksPage = p
        updateInstrumentWindow()
        onEvent?(.values)
    }

    /// What a knob's display shows in the Komplete Kontrol view with NKS pages; nil for an empty slot. The value and
    /// its text are REAPER's, once it has reported that parameter (its name starts with its number). An autoname
    /// slot is labelled as KK labels it: with the parameter's name as REAPER reports it ("101 Osc1 Coarse").
    func nksInfo(_ k: Int) -> KnobInfo? {
        guard let slot = nksSlot(k) else { return nil }
        let number = kkInstrumentParamBase + slot.id, prefix = "\(number - 1) "
        let p = instPosition(number).flatMap { instParams[$0] }.flatMap { $0.name.hasPrefix(prefix) ? $0 : nil }
        let name = slot.autoname ? p.map { String($0.name.dropFirst(prefix.count)) } ?? slot.name : slot.name
        return KnobInfo(name: name, short: name, value: p?.text ?? "", bar: p?.value, isPan: false)
    }

    /// A knob turned by `d` raw units in the Komplete Kontrol view with NKS pages: set its KK parameter.
    func turnNKS(_ k: Int, raw d: Int) {
        guard let slot = nksSlot(k), let pos = instPosition(kkInstrumentParamBase + slot.id),
              let v = instParams[pos]?.value else { return }
        let n = max(0, min(1, v + Double(d) / Double(cfg.knobFullRange)))
        guard n != v else { return }
        instParams[pos]?.value = n
        setValue("/fxinstparam/\(pos)/value", n)
        onEvent?(.values)
    }

    // MARK: Learn mode (NKSLearn.swift)

    /// Teach the instrument's pages, starting from `layout` (the pages in use), at page 1, knob 1.
    func startLearning(from layout: NKSLayout?) {
        learning = NKSLearning(from: layout)
        onEvent?(.values)
    }

    /// Leave learn mode; what was taught, if it was on.
    func stopLearning() -> NKSLearning? {
        defer { learning = nil; onEvent?(.values) }
        return learning
    }

    /// Leave learn mode without saving, for the bridge to say why.
    private func stopLearning(because why: String) {
        guard learning != nil else { return }
        learning = nil
        onEvent?(.learnStopped(why))
    }

    /// Learn mode: Page ◀ / ▶ move the selection back or on a slot, across pages (NKSLearning.move).
    func learnMove(forward: Bool) {
        learning?.move(forward: forward)
        onEvent?(.learnChanged)
    }

    /// Learn mode: a knob turned picks its slot for the next control moved in KK's window; with Shift, empties it.
    func learnTurned(_ k: Int, shift: Bool) {
        if shift { learning?.clear(k) } else { learning?.pick(k) }
        onEvent?(.learnChanged)
    }

    /// A last-touched message. In learn mode, the start of a touch (another parameter, plugin or track, or the first
    /// message after a pause) puts the parameter on the selected slot, once REAPER's other messages about it have
    /// arrived: a touch's value comes before its name.
    private func lastTouched(newControl: Bool) {
        let now = Date()
        let starts = newControl || now.timeIntervalSince(lastTouchMessage) > 0.5
        lastTouchMessage = now
        guard learning != nil, starts else { return }
        pendingNewControl = pendingNewControl || newControl
        guard !touchPending else { return }
        touchPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let newControl = self.pendingNewControl
            self.touchPending = false
            self.pendingNewControl = false
            self.learnTouched(newControl: newControl)
        }
    }

    /// A control moved in learn mode: REAPER's last-touched parameter ("107 Balance": instrument parameter ID 6) goes
    /// on the selected slot, if it's the selected track's Komplete Kontrol's. The same parameter moved again counts
    /// only after a slot was picked (otherwise it's a pause in the same move).
    private func learnTouched(newControl: Bool) {
        guard var l = learning, newControl || l.picked else { return }
        guard touchedTrack == track.number else { onEvent?(.learnRefused("that was another track's plugin")); return }
        guard touchedFX.hasPrefix("Komplete Kontrol") else {
            onEvent?(.learnRefused("move a control in Komplete Kontrol's window"))
            return
        }
        let parts = touchedParam.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let n = Int(parts[0]), n > 100 else {  // NIKB00, and KK's own 1-100 (Scale, Arp, ...)
            onEvent?(.learnRefused("\(touchedParam) is Komplete Kontrol's own"))
            return
        }
        guard let k = l.slot else { onEvent?(.learnRefused("touch a knob first")); return }
        let slot = NKSSlot(name: String(parts[1]), id: n - 101, autoname: true)
        let page = l.page
        _ = l.assign(slot)
        learning = l
        onEvent?(.learnAssigned("page \(page + 1), knob \(k + 1): \(slot.name) (\(slot.id))"))
        onEvent?(.learnChanged)
    }

    /// The Navigate knob turned. Picking a track with it in mix view goes to track view (issue #17), so the knobs
    /// and displays show the track picked. The view switches first, so the track is also made REAPER's selected
    /// track (mirrorSelection). The Komplete Kontrol view stays put, so you can move between instrument tracks and
    /// keep their plugins on the knobs; the track picked there is selected in REAPER too.
    func navigate(_ target: String, steps: Int) {
        if target != "pages" && view == .mix { show(.track) }
        let up = steps > 0
        let cmd: ReaperCommand = target == "pages" ? (up ? .nextPage : .previousPage) : (up ? .nextTrack : .previousTrack)
        for _ in 0..<min(abs(steps), 8) { perform(cmd, down: true) }
    }

    func target(_ k: Int) -> KnobTarget? {
        switch view {
        case .kk:
            return nil  // the knobs send MIDI CCs (Bridge.handleUI)
        case .mix:
            return bank[k].exists ? .bankVolume(k) : nil
        case .track:
            guard track.exists else { return nil }
            let s: Int
            if sendPage == 0 {
                switch k {
                case 0: return .volume
                case 1: return .pan
                case 2: return .mute
                case 3: return .solo
                case 4: return .recArm
                default: s = k - 5
                }
            } else {
                s = 3 + (sendPage - 1) * 8 + k
            }
            let routed = routedSends
            return s < routed.count ? .send(routed[s]) : nil
        }
    }

    /// What Shift + turn changes, where that's a value of its own: in mix view, the track's pan (issue #16).
    /// Elsewhere nil: track view's Shift + turn resets (Bridge.handleUI), and other knobs send their CC.
    func shiftTarget(_ k: Int) -> KnobTarget? {
        if case .bankVolume(let i)? = target(k) { return .bankPan(i) }
        return nil
    }

    /// REAPER reports a centred pan as "C".
    private func panValue(_ text: String) -> String { ["c", "center"].contains(text.lowercased()) ? "CENTER" : text }

    func info(_ t: KnobTarget) -> KnobInfo {
        switch t {
        case .bankVolume(let i):
            let s = bank[i]
            return KnobInfo(name: s.label, short: s.label, value: s.volumeText, bar: s.volume, isPan: false)
        case .bankPan(let i):
            let s = bank[i]
            return KnobInfo(name: s.label, short: s.label, value: panValue(s.panText), bar: s.pan, isPan: true)
        case .volume: return KnobInfo(name: "Volume", short: "Volume", value: track.volumeText, bar: track.volume, isPan: false)
        case .pan:
            return KnobInfo(name: "Pan", short: "Pan", value: panValue(track.panText), bar: track.pan, isPan: true)
        case .mute: return KnobInfo(name: "Mute", short: "Mute", value: track.mute ? "ON" : "off", bar: track.mute ? 1 : 0, isPan: false)
        case .solo: return KnobInfo(name: "Solo", short: "Solo", value: track.solo ? "ON" : "off", bar: track.solo ? 1 : 0, isPan: false)
        case .recArm:  // the monitoring state rides along: "ON MON", "off AUTO"
            let mon = [1: " MON", 2: " AUTO"][track.monitor] ?? ""
            return KnobInfo(name: "Record arm", short: "Rec Arm", value: (track.recArm ? "ON" : "off") + mon,
                            bar: track.recArm ? 1 : 0, isPan: false)
        case .send(let n):
            let s = sends[n]
            return KnobInfo(name: s.name, short: s.name, value: s.volumeText, bar: s.volume, isPan: false)
        }
    }

    /// A knob turned by `d` raw units (positive = clockwise); with `shift`, what Shift + turn changes.
    func turn(_ k: Int, raw d: Int, shift: Bool = false) {
        guard let t = shift ? shiftTarget(k) : target(k) else { return }
        let delta = Double(d) / Double(cfg.knobFullRange)
        func moved(_ v: Double?) -> Double? {
            guard let v else { return nil }
            let n = max(0, min(1, v + delta))
            return n == v ? nil : n
        }
        switch t {
        case .bankVolume(let i):
            guard let n = moved(bank[i].volume) else { return }
            bank[i].volume = n
            setValue("/track/\(i + 1)/volume", n)
        case .bankPan(let i):
            guard let n = moved(bank[i].pan) else { return }
            bank[i].pan = n
            setValue("/track/\(i + 1)/pan", n)
        case .volume:
            guard let n = moved(track.volume) else { return }
            track.volume = n
            setValue("/track/volume", n)
        case .pan:
            guard let n = moved(track.pan) else { return }
            track.pan = n
            setValue("/track/pan", n)
        case .send(let s):
            guard let n = moved(sends[s].volume) else { return }
            sends[s].volume = n
            setValue("/track/send/\(s + 1)/volume", n)
        case .mute, .solo, .recArm:
            guard let want = toggleTurned(k, d) else { return }
            switch t {
            case .mute:
                guard want != track.mute else { return }
                track.mute = want
                send("/track/mute", [.float(want ? 1 : 0)])
            case .solo:
                guard want != track.solo else { return }
                track.solo = want
                send("/track/solo", [.float(want ? 1 : 0)])
            default:
                guard want != track.recArm else { return }
                track.recArm = want
                send("/track/recarm", [.float(want ? 1 : 0)])
            }
        }
        onEvent?(.values)
    }

    /// On/off knobs (mute, solo, record arm, monitoring): turning a little right means on, left means off.
    /// Returns the wanted state once the knob has turned far enough, nil before that.
    private func toggleTurned(_ k: Int, _ d: Int) -> Bool? {
        toggleAccum[k] += d
        guard abs(toggleAccum[k]) >= toggleTurn else { return nil }
        defer { toggleAccum[k] = 0 }
        return toggleAccum[k] > 0
    }

    /// Shift + the record-arm knob in track view: record monitoring on (right) or off (left).
    func turnMonitor(_ k: Int, raw d: Int) {
        guard target(k) == .recArm, let want = toggleTurned(k, d), want != (track.monitor != 0) else { return }
        track.monitor = want ? 1 : 0
        send("/track/monitor", [.float(want ? 1 : 0)])
        onEvent?(.values)
    }

    /// What the record-arm display shows while Shift is held: the monitoring state that Shift + turn changes.
    var monitorInfo: KnobInfo {
        KnobInfo(name: "Record monitoring", short: "Monitor", value: ["off", "ON", "AUTO"][min(max(track.monitor, 0), 2)],
                 bar: track.monitor != 0 ? 1 : 0, isPan: false)
    }

    /// Shift + the pan knob in track view: pan straight to the centre, which is hard to hit by turning.
    @discardableResult
    func centerPan() -> Bool {
        guard let p = track.pan, abs(p - 0.5) > 0.0001 else { return false }
        track.pan = 0.5
        setValue("/track/pan", 0.5)
        onEvent?(.values)
        return true
    }

    /// Shift + the volume knob in track view: volume straight to 0 dB. Sent in dB, since the 0-1 fader position
    /// of 0 dB depends on REAPER's fader settings. (In mix view, Shift + turn is the track's pan.)
    @discardableResult
    func resetVolume(_ k: Int) -> Bool {
        guard target(k) == .volume, abs(track.volumeDB ?? 1) > 0.01 else { return false }
        track.volumeDB = 0
        let path = "/track/volume"
        lastSent[path] = nil  // take REAPER's new fader position
        send(path + "/db", [.float(0)])
        onEvent?(.values)
        return true
    }

    /// Where to tell REAPER a knob's value is touched, if it has a touch state.
    private func touchPath(_ k: Int, shift: Bool) -> String? {
        switch (shift ? shiftTarget(k) : nil) ?? target(k) {
        case .bankVolume(let i)?: return "/track/\(i + 1)/volume/touch"
        case .bankPan(let i)?: return "/track/\(i + 1)/pan/touch"
        case .volume?: return "/track/volume/touch"
        case .pan?: return "/track/pan/touch"
        default: return nil
        }
    }

    /// Knob touch: tells REAPER the fader (or, with Shift in mix view, the pan) is being touched, for automation
    /// in touch mode.
    func touch(_ k: Int, _ on: Bool, shift: Bool = false) {
        if on, learning != nil {  // learn mode: the knob's slot gets the next control moved in KK's window
            learning?.pick(k)
            onEvent?(.learnChanged)
        }
        if on {
            toggleAccum[k] = 0
            touchAddress[k] = touchPath(k, shift: shift)
            if let a = touchAddress[k] { send(a, [.float(1)]) }
        } else if let a = touchAddress[k] {
            send(a, [.float(0)])  // released where it was touched, even if the view changed meanwhile
            touchAddress[k] = nil
        }
    }

    /// Shift pressed or released while a knob is touched: move the touch to what the knob now changes.
    func retouch(_ k: Int, shift: Bool) {
        let a = touchPath(k, shift: shift)
        guard a != touchAddress[k] else { return }
        if let old = touchAddress[k] { send(old, [.float(0)]) }
        touchAddress[k] = a
        if let a { send(a, [.float(1)]) }
    }

    private func setValue(_ address: String, _ v: Double) {
        lastSent[address] = Date()
        send(address, [.float(Float(v))])
    }

    /// Echoes of what a knob just sent are ignored, so a value doesn't jump back while turning.
    private func recentlySent(_ address: String) -> Bool {
        lastSent[address].map { Date().timeIntervalSince($0) < 0.3 } ?? false
    }

    /// Apply one track message (the address after /track or /track/N); false if it isn't one we use.
    private func update(_ s: inout TrackStrip, _ rest: String, _ address: String, _ args: [OSCArg]) -> Bool {
        let text = args.first?.text ?? "", number = args.first?.number
        switch rest {
        case "name": s.name = text
        case "number/str": s.number = text
        case "volume": guard let v = number, !recentlySent(address) else { return false }; s.volume = v
        case "volume/str": s.volumeText = text
        case "pan": guard let v = number, !recentlySent(address) else { return false }; s.pan = v
        case "pan/str": s.panText = text
        case "volume/db": s.volumeDB = number
        case "pan2": s.width = number
        case "mute": s.mute = (number ?? 0) > 0.5
        case "solo": s.solo = (number ?? 0) > 0.5
        case "recarm": s.recArm = (number ?? 0) > 0.5
        case "monitor": s.monitor = Int((number ?? 0).rounded())
        default: return false
        }
        return true
    }

    /// A message as if REAPER had sent it (replays' OSC lines).
    func received(_ address: String, _ args: [OSCArg]) { receive(address, args) }

    private func receive(_ address: String, _ args: [OSCArg]) {
        onReceive?(address, args)
        if !connected {
            connected = true
            handshake()  // REAPER may have started after us; skipped if we just sent it
            onEvent?(.connected)
        }
        let p = address.split(separator: "/").map(String.init)
        guard let head = p.first else { return }
        switch head {
        case "track" where p.count >= 2:
            if let n = Int(p[1]) {  // /track/N/...: a track of the current bank
                guard n >= 1 else { return }
                guard n <= bankSize else { handshake(); return }  // REAPER's page is bigger than ours: it restarted
                var s = bank[n - 1]
                guard update(&s, p.dropFirst(2).joined(separator: "/"), address, args) else { return }
                let moved = s.number != bank[n - 1].number || s.name != bank[n - 1].name
                bank[n - 1] = s
                onEvent?(moved ? .bank : .values)
            } else if p[1] == "send" {  // /track/send/N/...: a send of the selected track
                guard p.count >= 4, let n = Int(p[2]), (1...sendSlots).contains(n) else { return }
                var s = sends[n - 1]
                switch p.dropFirst(3).joined(separator: "/") {
                case "name": s.name = args.first?.text ?? ""
                case "volume": guard let v = args.first?.number, !recentlySent(address) else { return }; s.volume = v
                case "volume/str": s.volumeText = args.first?.text ?? ""
                default: return
                }
                sends[n - 1] = s
                sendPage = min(sendPage, sendPages - 1)
                onEvent?(.trackData)
            } else {  // /track/...: the selected track
                var s = track
                guard update(&s, p.dropFirst().joined(separator: "/"), address, args) else { return }
                // Another track was selected. REAPER sends the new name just before the new number, so either
                // one counts, so the displays never show the new name over the old track's values.
                let changed = s.number != track.number || s.name != track.name
                track = s
                if changed && view == .track { sendPage = 0 }
                if changed { lastShown = nil }
                if changed && nksPage != 0 { nksPage = 0; updateInstrumentWindow() }
                if changed { stopLearning(because: "the track changed") }
                onEvent?(changed ? .track : .trackData)
            }
        case "play" where p.count == 1: playing = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "record" where p.count == 1: recording = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "repeat" where p.count == 1: repeating = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "click" where p.count == 1: metronome = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "fx" where p.count >= 3 && p[1] == "last_touched":  // the plugin last touched, and its track
            switch p.dropFirst(2).joined(separator: "/") {
            case "name": touchedFX = args.first?.text ?? ""
            case "track/number/str": touchedTrack = args.first?.text ?? ""
            default: return
            }
            lastTouched(newControl: true)
        case "fxparam" where p.count >= 3 && p[1] == "last_touched":  // the parameter last touched
            switch p.dropFirst(2).joined(separator: "/") {
            case "name": touchedParam = args.first?.text ?? ""; lastTouched(newControl: true)
            case "value": lastTouched(newControl: false)
            default: return
            }
        case "fx" where p.count == 3:  // /fx/N/name, /fx/N/openui: the selected track's plugins
            guard let n = Int(p[1]), (1...fxSlots).contains(n) else { return }
            switch p[2] {
            case "name": fxNames[n - 1] = args.first?.text ?? ""
            case "openui": fxOpen[n - 1] = (args.first?.number ?? 0) > 0.5
            default: return
            }
            onEvent?(.values)
        case "fxinst" where p.count == 2 && p[1] == "name":  // the selected track's instrument plugin
            instrumentName = args.first?.text ?? ""
            if !instrumentIsKK { stopLearning(because: "Komplete Kontrol isn't on this track") }
            updateInstrumentWindow()
            if nks != nil && view == .kk { onEvent?(.values) }
        case "fxinstparam" where p.count >= 3:  // a parameter of the instrument run asked for (updateInstrumentWindow)
            guard let pos = Int(p[1]) else { return }
            var ip = instParams[pos] ?? (name: "", value: nil, text: "")
            switch p.dropFirst(2).joined(separator: "/") {
            case "name": ip.name = args.first?.text ?? ""
            case "value": guard let v = args.first?.number, !recentlySent(address) else { return }; ip.value = v
            case "value/str": ip.text = args.first?.text ?? ""
            default: return
            }
            instParams[pos] = ip
            if nksActive { onEvent?(.values) }
        case "action" where p.count == 2 && (args.first?.number ?? 0) > 0.5:  // action state, if REAPER reports it
            if p[1] == String(recordAutoPunchAction) { autoPunch = true; onEvent?(.transport) }
            if p[1] == String(recordNormalAction) { autoPunch = false; onEvent?(.transport) }
        default: break
        }
    }
}
