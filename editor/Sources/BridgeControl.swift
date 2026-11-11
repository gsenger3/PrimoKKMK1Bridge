//
//  BridgeControl.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/9/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Starts, stops and watches the bridge for the editor's toolbar switch. The bridge counts as running while a
//  MIDI source with its port name exists, however it was started (from here, in Terminal, or at login).
//  Started from here it runs in the background, logs to ~/Library/Logs/PrimoKKMK1Bridge.log, and keeps
//  running after the editor quits.

import AppKit
import CoreMIDI
import Darwin
import Foundation

final class BridgeControl: ObservableObject {
    enum State { case stopped, starting, running, stopping }

    @Published private(set) var state: State = .stopped
    /// The port name of the config the bridge runs with (the saved one): how the bridge is recognised.
    var portName = Config().portName {
        didSet { if portName != oldValue { check() } }
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PrimoKKMK1Bridge.log")

    private var midiClient = MIDIClientRef()
    private var timer: Timer?
    private var deadline: Date?
    private var child: Process?

    var isRunning: Bool { state == .running }

    func startWatching() {
        guard timer == nil else { return }
        MIDIClientCreateWithBlock("Primo KK MK1 Control Editor" as CFString, &midiClient) { [weak self] _ in
            DispatchQueue.main.async { self?.check() }  // MIDI setup changed: a port came or went
        }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    // MARK: start and stop

    /// Run the bridge in the background with this config file.
    func start(config: URL) {
        guard state == .stopped else { return }
        guard let exe = Self.executable() else {
            report("Can't find the bridge program.",
                   "Build the editor with editor/build.sh, which puts the bridge inside the app.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)  // a fresh log for each start
            let log = try FileHandle(forWritingTo: Self.logURL)
            let p = Process()
            p.executableURL = exe
            p.arguments = ["--config", config.path]
            p.currentDirectoryURL = config.deletingLastPathComponent()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = log
            p.standardError = log
            p.terminationHandler = { [weak self] proc in
                let code = proc.terminationStatus
                DispatchQueue.main.async { self?.childExited(code) }
            }
            try p.run()
            child = p
            enter(.starting, timeout: 8)
        } catch {
            report("The bridge didn't start.", error.localizedDescription)
        }
    }

    /// Ask every running bridge to quit. SIGTERM, like Ctrl-C: it turns the lights off and blanks the displays first.
    func stop() {
        guard state == .running || state == .starting else { return }
        let pids = Self.runningPIDs()
        guard !pids.isEmpty else {
            report("Can't find the bridge's process.",
                   "Its MIDI port \(portName) is up, but no program called PrimoKKMK1Bridge is running for this user.")
            return
        }
        for pid in pids { kill(pid, SIGTERM) }
        enter(.stopping, timeout: 6)
    }

    private func enter(_ s: State, timeout: TimeInterval) {
        state = s
        deadline = Date().addingTimeInterval(timeout)
    }

    /// Follow the port: it appears once a started bridge is up, and goes away when a bridge quits.
    private func check() {
        let up = Self.portExists(portName)
        let late = deadline.map { Date() > $0 } ?? false
        switch state {
        case .stopped where up: state = .running
        case .running where !up: state = .stopped
        case .starting where up: state = .running; deadline = nil
        case .starting where late:
            state = .stopped
            deadline = nil
            report("The bridge didn't come up.", Self.logTail())
        case .stopping where !up: state = .stopped; deadline = nil
        case .stopping where late:
            state = .running
            deadline = nil
            report("The bridge didn't stop.", "It's still running. Stop it with Ctrl-C where it runs, or try again.")
        default: break
        }
    }

    /// A bridge started from here quit. Before it came up, that's a failed start: say why, from its log.
    private func childExited(_ code: Int32) {
        child = nil
        guard state == .starting else { return }
        state = .stopped
        deadline = nil
        report("The bridge stopped right away (exit code \(code)).", Self.logTail())
    }

    private func report(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Show Log")
        if a.runModal() == .alertSecondButtonReturn { Self.showLog() }
    }

    // MARK: finding things

    static func showLog() {
        if FileManager.default.fileExists(atPath: logURL.path) { NSWorkspace.shared.open(logURL) }
    }

    /// Reveal the REAPER script that sends track colours for the light guide (bundled in the app's Resources).
    static func showTrackColourScript() {
        if let url = Bundle.main.url(forResource: "PrimoKKMK1Bridge_TrackColor", withExtension: "lua") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let a = NSAlert()
            a.messageText = "The REAPER script isn't in this copy of the app."
            a.informativeText = "It's reaper/PrimoKKMK1Bridge_TrackColor.lua in the project. Build the app with editor/build.sh to include it."
            a.runModal()
        }
    }

    /// The last few lines of the log, for an error message.
    static func logTail(lines: Int = 4) -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "There's no log yet." }
        let tail = text.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return tail.isEmpty ? "The log is empty." : tail
    }

    /// The bridge program: inside this app (Contents/MacOS), else $PRIMOKKMK1_BRIDGE, else next to the app (build/).
    static func executable() -> URL? {
        var candidates: [URL] = []
        if let embedded = Bundle.main.url(forAuxiliaryExecutable: "PrimoKKMK1Bridge") { candidates.append(embedded) }
        if let env = ProcessInfo.processInfo.environment["PRIMOKKMK1_BRIDGE"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PrimoKKMK1Bridge"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func portExists(_ name: String) -> Bool {
        for i in 0..<MIDIGetNumberOfSources() {
            var cf: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(MIDIGetSource(i), kMIDIPropertyName, &cf)
            if (cf?.takeRetainedValue() as String?) == name { return true }
        }
        return false
    }

    /// This user's processes whose program is called PrimoKKMK1Bridge, wherever it lives.
    static func runningPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        return pids.prefix(min(Int(n), pids.count)).filter { pid in
            guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return (String(cString: path) as NSString).lastPathComponent == "PrimoKKMK1Bridge"
        }
    }
}
