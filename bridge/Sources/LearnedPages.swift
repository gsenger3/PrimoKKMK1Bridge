//
//  LearnedPages.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/14/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  NKSPages.json, the learned NKS pages (NKSLearn.swift): its format and where it is. The bridge writes it when you
//  finish learn mode; the editor lists it, and renames and deletes entries (issue #34). Both compile this file.

import Foundation

/// NKSPages.json: learned pages by instrument key ("<plugin ID>/<fingerprint>"). A slot's `id` is the instrument
/// parameter ID, as in NICA (REAPER's parameter number - 102); `name` is REAPER's name for it when it was learned.
struct LearnedPages: Codable {
    struct Slot: Codable { var id: Int; var name: String }
    struct Instrument: Codable {
        var label: String    // the track's name when the pages were learned (the editor can rename it)
        var learned: String  // when, ISO 8601
        var pages: [[Slot?]]
    }

    var version = 1
    var instruments: [String: Instrument] = [:]

    init() {}

    /// The file's pages; none if there's no file yet.
    init(contentsOf url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        self = try JSONDecoder().decode(LearnedPages.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: url, options: .atomic)
    }

    /// Where the file is: reaper.kompleteKontrol.nksPagesFile, else NKSPages.json next to the config file.
    static func url(configFile: URL, setting: String?) -> URL {
        setting.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? configFile.deletingLastPathComponent().appendingPathComponent("NKSPages.json")
    }

    /// The plugin part of an instrument's key, readable: "VST3:5653544E…/1A2B3C4D" -> "VSTNiK8kontakt 8", the ID's
    /// bytes when they're all printable, else the ID as it is.
    static func pluginName(_ key: String) -> String {
        let id = key.split(separator: "/").first.map(String.init) ?? key
        guard let hex = id.split(separator: ":").last, hex.count % 2 == 0 else { return id }
        let digits = Array(hex)
        let bytes = stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        guard bytes.count == digits.count / 2, !bytes.isEmpty, bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return id }
        return String(decoding: bytes, as: UTF8.self)
    }
}
