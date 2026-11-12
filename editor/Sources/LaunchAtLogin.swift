//
//  LaunchAtLogin.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/12/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Starts the bridge at login (issue #2): a user LaunchAgent, ~/Library/LaunchAgents/com.primostudios.PrimoKKMK1Bridge.plist,
//  for the copy of the bridge inside this app. It's the same LaunchAgent the user guide describes setting up by hand.
//  launchd loads it at the next login; it starts the bridge then, and again if it crashes, but not after a normal quit
//  (the editor's switch), so the switch can still turn the bridge off.

import Foundation

enum LaunchAtLogin {
    static let label = "com.primostudios.PrimoKKMK1Bridge"
    /// The LaunchAgents folder (a test can point it elsewhere).
    static var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    static var plistURL: URL { directory.appendingPathComponent(label + ".plist") }
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PrimoKKMK1Bridge.log")

    struct Status {
        var enabled = false   // the LaunchAgent is there: the bridge starts at login
        var program: String?  // the bridge it starts
    }

    static func status() -> Status {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return Status()
        }
        return Status(enabled: true, program: (plist["ProgramArguments"] as? [String])?.first)
    }

    struct LoginError: Error, CustomStringConvertible { let description: String }

    /// The bridge inside this app, if it can start at login from where the app is.
    static func bridgeForLogin(_ bridge: URL?) throws -> URL {
        guard let bridge else {
            throw LoginError(description: "The bridge isn't inside this copy of the app. Build the app with editor/build.sh.")
        }
        // A downloaded app that hasn't been moved yet runs from a temporary copy that's gone after the next restart.
        if bridge.path.contains("/AppTranslocation/") {
            throw LoginError(description: "macOS is running this app from a temporary copy. Move PrimoKKMK1Editor.app to your Applications folder, open it from there, and try again.")
        }
        return bridge
    }

    /// Write the LaunchAgent for `bridge`. launchd loads it at the next login; nothing starts now.
    static func enable(bridge: URL) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [bridge.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],  // again after a crash, not after a normal quit
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    /// Remove the LaunchAgent, so the bridge doesn't start at the next login. If launchd has it loaded (from this
    /// login) and its bridge isn't running, unload it too. A bridge it started that's still running is left alone:
    /// it keeps going until it's turned off or you log out. Returns whether that's the case.
    @discardableResult
    static func disable() throws -> Bool {
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
        guard let job = launchctl(["print", "gui/\(getuid())/\(label)"]), job.status == 0 else { return false }
        if job.output.contains("state = running") { return true }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        return false
    }

    /// Run launchctl; nil if it couldn't be run.
    private static func launchctl(_ args: [String]) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
