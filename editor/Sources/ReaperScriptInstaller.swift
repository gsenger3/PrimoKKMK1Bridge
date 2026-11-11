//
//  ReaperScriptInstaller.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/11/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Installs the REAPER script that sends track colours for the light guide (bundled in the app's Resources) into
//  REAPER's resource folder: Scripts/Primo Studios/PrimoKKMK1Bridge_TrackColor.lua, started from Scripts/__startup.lua,
//  which REAPER runs every time it starts. The startup line is added once, after a backup of the existing
//  __startup.lua. Uninstalling removes the script and that line again (after another backup).

import Foundation

enum ReaperScriptInstaller {
    static let scriptName = "PrimoKKMK1Bridge_TrackColor.lua"
    static let folderName = "Primo Studios"

    struct Status {
        var resourceFolderFound = false
        var scriptInstalled = false
        var scriptUpToDate = false
        var startsWithREAPER = false
        var installed: Bool { scriptInstalled && scriptUpToDate && startsWithREAPER }
        /// Any part of it is in REAPER: then the settings offer Uninstall.
        var anyInstalled: Bool { scriptInstalled || startsWithREAPER }
    }

    /// REAPER's resource folder, from reaper.resourcePath (default ~/Library/Application Support/REAPER).
    static func resourceURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func scriptURL(_ resource: URL) -> URL {
        resource.appendingPathComponent("Scripts").appendingPathComponent(folderName).appendingPathComponent(scriptName)
    }

    static func startupURL(_ resource: URL) -> URL {
        resource.appendingPathComponent("Scripts").appendingPathComponent("__startup.lua")
    }

    /// The script inside the app (editor/build.sh copies it to Contents/Resources).
    static var bundledScript: URL? { Bundle.main.url(forResource: "PrimoKKMK1Bridge_TrackColor", withExtension: "lua") }

    /// The lines added to __startup.lua.
    static let startupBlock = """

        -- PrimoKKMK1Bridge: show the selected track's colour on the Komplete Kontrol keyboard's light guide.
        -- Added by Primo KK MK1 Control Editor (Settings ▸ Track colour on the keys).
        dofile(reaper.GetResourcePath() .. "/Scripts/\(folderName)/\(scriptName)")

        """

    static func status(resourcePath: String) -> Status {
        let fm = FileManager.default
        let resource = resourceURL(resourcePath)
        var s = Status()
        var isDir: ObjCBool = false
        s.resourceFolderFound = fm.fileExists(atPath: resource.path, isDirectory: &isDir) && isDir.boolValue
        let installed = scriptURL(resource)
        s.scriptInstalled = fm.fileExists(atPath: installed.path)
        if s.scriptInstalled, let bundled = bundledScript {
            s.scriptUpToDate = fm.contentsEqual(atPath: installed.path, andPath: bundled.path)
        }
        let startup = (try? String(contentsOf: startupURL(resource), encoding: .utf8)) ?? ""
        s.startsWithREAPER = startup.contains(scriptName)
        return s
    }

    struct InstallError: Error, CustomStringConvertible { let description: String }

    /// Copy (or update) the script and make REAPER start it. Returns what was done, for the user.
    static func install(resourcePath: String) throws -> [String] {
        let fm = FileManager.default
        let resource = resourceURL(resourcePath)
        guard status(resourcePath: resourcePath).resourceFolderFound else {
            throw InstallError(description: "There's no REAPER resource folder at \(resource.path). Open REAPER once, or set REAPER's resource folder on the Settings page.")
        }
        guard let bundled = bundledScript else {
            throw InstallError(description: "The script isn't in this copy of the app. Build the app with editor/build.sh to include it.")
        }
        var done: [String] = []

        let script = scriptURL(resource)
        try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = fm.fileExists(atPath: script.path)
        if existed { try fm.removeItem(at: script) }
        try fm.copyItem(at: bundled, to: script)
        done.append("\(existed ? "Updated" : "Copied") the script to \(script.path).")

        let startup = startupURL(resource)
        let current = (try? String(contentsOf: startup, encoding: .utf8)) ?? ""
        if current.contains(scriptName) {
            done.append("REAPER already starts it from \(startup.lastPathComponent).")
        } else {
            if fm.fileExists(atPath: startup.path) {
                done.append("Backed up your \(startup.lastPathComponent) as \(try backUp(startup)).")
            }
            try (current + startupBlock).write(to: startup, atomically: true, encoding: .utf8)
            done.append("\(current.isEmpty ? "Created" : "Added a line to") \(startup.path), so REAPER starts the script.")
        }
        return done
    }

    /// Back up __startup.lua (before changing it) next to it, with the time in the name (and a number, if there's
    /// already a backup from that second).
    private static func backUp(_ startup: URL) throws -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = startup.deletingLastPathComponent()
        var backup = folder.appendingPathComponent("__startup.lua.backup-\(stamp)")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = folder.appendingPathComponent("__startup.lua.backup-\(stamp)-\(n)")
            n += 1
        }
        try FileManager.default.copyItem(at: startup, to: backup)
        return backup.lastPathComponent
    }

    /// Remove the script and the line that starts it. Returns what was done, for the user.
    static func uninstall(resourcePath: String) throws -> [String] {
        let fm = FileManager.default
        let resource = resourceURL(resourcePath)
        var done: [String] = []

        let script = scriptURL(resource)
        if fm.fileExists(atPath: script.path) {
            try fm.removeItem(at: script)
            done.append("Removed \(script.path).")
            let folder = script.deletingLastPathComponent()  // Primo Studios: only if nothing else is in it
            if let rest = try? fm.contentsOfDirectory(atPath: folder.path), rest.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: folder)
            }
        }

        let startup = startupURL(resource)
        if let current = try? String(contentsOf: startup, encoding: .utf8), current.contains(scriptName) {
            let backup = try backUp(startup)
            done.append("Backed up your \(startup.lastPathComponent) as \(backup).")
            // The lines Install added, exactly; otherwise (edited since, or added by hand) every line that names the
            // script, and Install's comment lines.
            var updated = current.replacingOccurrences(of: startupBlock, with: "")
            if updated.contains(scriptName) {
                let comments = Set(startupBlock.components(separatedBy: "\n").filter { $0.hasPrefix("--") })
                updated = updated.components(separatedBy: "\n").filter { line in
                    !line.contains(scriptName) && !comments.contains(line.trimmingCharacters(in: .whitespaces))
                }.joined(separator: "\n")
            }
            if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try fm.removeItem(at: startup)  // nothing but the script's line was in it
                done.append("Removed \(startup.path): starting the script was all it did.")
            } else {
                try updated.write(to: startup, atomically: true, encoding: .utf8)
                done.append("Removed the line that starts the script from \(startup.path).")
            }
        }
        if done.isEmpty { done.append("The script wasn't installed; nothing to remove.") }
        return done
    }
}
