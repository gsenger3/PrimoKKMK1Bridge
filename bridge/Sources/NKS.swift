//
//  NKS.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/13/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  Komplete Kontrol's knob pages for an instrument, read from one of its NKS preset files (.nksf). An .nksf is a
//  RIFF file ("NIKS") whose NICA chunk (controller assignments, MessagePack) lists the pages KK shows: 8 slots each,
//  with a name and the instrument parameter's ID. The Komplete Kontrol plugin offers instrument
//  parameter ID n to the host as its parameter "101+n <name>" (after NIKB00 and KK's own 100), so REAPER numbers
//  it 102 + n (checked with KK 3.5.5 and REAPER 7.61 on 2026-11-13). NKSLibrary finds the preset file for the
//  instrument KK hosts, in KK's browser database.

import Foundation
import SQLite3

/// REAPER's (1-based) number for the KK plugin parameter that is instrument parameter ID 0.
let kkInstrumentParamBase = 102

/// `autoname`: KK labels the knob with the instrument's own name for the parameter (as the host sees it), not `name`.
struct NKSSlot { let name: String; let id: Int; let autoname: Bool }

/// The value in one of an .nksf file's chunks ("NISI", "NICA" or "PLID": each a 4-byte version, then MessagePack);
/// nil if the file has no such chunk.
func nksChunk(_ id: String, in url: URL) throws -> Any? {
    let b = [UInt8](try Data(contentsOf: url))
    func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
          String(decoding: b[8..<12], as: UTF8.self) == "NIKS" else {
        throw ConfigError(description: "not an NKS preset file (.nksf)")
    }
    var i = 12
    while i + 8 <= b.count {
        let size = u32(i + 4), end = min(b.count, i + 8 + size)
        if String(decoding: b[i..<i + 4], as: UTF8.self) == id, end - i > 12 {
            var reader = MessagePack(bytes: Array(b[i + 12..<end]))
            return try reader.value()
        }
        i = end + (size & 1)
    }
    return nil
}

struct NKSLayout {
    let pages: [[NKSSlot?]]  // 8 slots per page; nil = an empty slot

    init(contentsOf url: URL) throws {
        // NICA: {"ni8": [page, ...]}, each page 8 slots of {"id", "name", "autoname", ...}.
        guard let root = try nksChunk("NICA", in: url) as? [String: Any], let ni8 = root["ni8"] as? [Any] else {
            throw ConfigError(description: "it has no NKS knob pages (NICA) in the expected form")
        }
        pages = ni8.map { page in
            let slots = ((page as? [Any]) ?? []).prefix(8).map { slot -> NKSSlot? in
                guard let s = slot as? [String: Any], let id = s["id"] as? Int else { return nil }
                return NKSSlot(name: s["name"] as? String ?? "", id: id, autoname: s["autoname"] as? Bool ?? false)
            }
            return slots + [NKSSlot?](repeating: nil, count: 8 - slots.count)
        }
    }
}

/// The NKS instruments Komplete Kontrol's browser knows, from its database, for finding the knob pages of the
/// instrument KK hosts. The REAPER script reports that instrument by its plugin ID ("VST3:<32 hex digits>"), and
/// each preset's PLID chunk names its plugin, so one preset per product is enough.
struct NKSLibrary {
    struct Product { let name: String; let file: URL; let vst2: [UInt8]?; let vst3: [UInt8]? }

    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Native Instruments/Komplete Kontrol/Browser Data/komplete.db3")

    let products: [Product]

    init(database: URL = NKSLibrary.database) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ConfigError(description: "can't open Komplete Kontrol's database \(database.path)")
        }
        // Two NKS instrument presets (.nksf, device type 1) per product (the first entry of its bank chain): older and
        // newer presets of a product can name its plugin differently (VST2 ID only, or VST3 class ID as well).
        let sql = """
            SELECT b.entry1, MIN(s.file_name), MAX(s.file_name) FROM k_sound_info s
            JOIN k_bank_chain b ON b.id = s.bank_chain_id
            WHERE s.file_ext = 'nksf' AND s.device_type_flags & 1 GROUP BY b.bcvendor, b.entry1
            """
        var query: OpaquePointer?
        defer { sqlite3_finalize(query) }
        guard sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK else {
            throw ConfigError(description: "Komplete Kontrol's database isn't as expected: \(String(cString: sqlite3_errmsg(db)))")
        }
        func bigEndian(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
        var out: [Product] = []
        while sqlite3_step(query) == SQLITE_ROW {
            guard let name = sqlite3_column_text(query, 0), let first = sqlite3_column_text(query, 1),
                  let last = sqlite3_column_text(query, 2) else { continue }
            let files = [first, last].map { URL(fileURLWithPath: String(cString: $0)) }
            var vst2: [UInt8]?, vst3: [UInt8]?
            for file in files {
                // PLID: {"VST.magic": the VST2 ID}, and in newer presets also {"VST3.uid": [4 × 32 bits]}.
                guard let plid = (try? nksChunk("PLID", in: file)) as? [String: Any] else { continue }
                vst2 = vst2 ?? (plid["VST.magic"] as? Int).flatMap { $0 > 0 ? bigEndian($0) : nil }
                let words = ((plid["VST3.uid"] as? [Any]) ?? []).compactMap { $0 as? Int }
                vst3 = vst3 ?? (words.count == 4 ? words.flatMap(bigEndian) : nil)
            }
            guard vst2 != nil || vst3 != nil else { continue }
            out.append(Product(name: String(cString: name), file: files[0], vst2: vst2, vst3: vst3))
        }
        products = out
    }

    /// The product whose presets are for the plugin `id` ("<format>:<hex ID>", as the REAPER script reports it).
    func product(forPlugin id: String) -> Product? {
        guard let hex = id.split(separator: ":").last, hex.count % 2 == 0 else { return nil }
        let digits = Array(hex)
        let bytes = stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...$0 + 1]), radix: 16) }
        guard bytes.count == digits.count / 2, bytes.count >= 4 else { return nil }
        if let p = products.first(where: { $0.vst3 == bytes }) { return p }
        // Most presets name only the VST2 ID, which a VST3 plugin's class ID usually carries: "VST" + ID + name by
        // Steinberg's convention ("VSTNiMX…"), or "ArtuAVIS" + ID + "Proc" for Arturia's ("ArtuAVISMnFVProc").
        return products.first { p in
            guard let v2 = p.vst2 else { return false }
            return (0...bytes.count - 4).contains { Array(bytes[$0..<$0 + 4]) == v2 }
        }
    }
}

/// Finds instruments' NKS pages off the main queue: reading KK's database and preset files can take seconds when the
/// disk they're on is asleep. The library is read on first use; results (and notes for the log) come back on main.
final class NKSLookup {
    private let queue = DispatchQueue(label: "PrimoKKMK1Bridge.NKS")
    private var library: NKSLibrary?  // touched only on `queue`
    private var libraryFailed = false

    func find(_ id: String, done: @escaping (_ found: (name: String, layout: NKSLayout)?, _ notes: [String]) -> Void) {
        queue.async {
            var notes: [String] = []
            if self.library == nil && !self.libraryFailed {
                do {
                    let l = try NKSLibrary()
                    self.library = l
                    notes.append("\(l.products.count) NKS instruments in its browser database")
                } catch {
                    self.libraryFailed = true
                    notes.append("\(error)")
                }
            }
            var found: (name: String, layout: NKSLayout)?
            if let p = self.library?.product(forPlugin: id) {
                do {
                    found = (p.name, try NKSLayout(contentsOf: p.file))
                } catch {
                    notes.append("can't read \(p.name)'s NKS knob pages from \(p.file.path): \(error)")
                }
            }
            DispatchQueue.main.async { done(found, notes) }
        }
    }
}

/// Just enough MessagePack to read NICA: nil, booleans, integers, floats, strings, arrays and maps (binary skipped).
private struct MessagePack {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, i + n <= bytes.count else { throw ConfigError(description: "its NKS knob pages (NICA) are cut short") }
        defer { i += n }
        return bytes[i..<i + n]
    }

    mutating func uint(_ n: Int) throws -> Int { try take(n).reduce(0) { $0 << 8 | Int($1) } }

    mutating func value() throws -> Any? {
        let t = Int(try take(1).first!)
        switch t {
        case 0x00...0x7f: return t
        case 0x80...0x8f: return try map(t & 0x0f)
        case 0x90...0x9f: return try array(t & 0x0f)
        case 0xa0...0xbf: return try string(t & 0x1f)
        case 0xe0...0xff: return t - 0x100
        case 0xc0: return nil
        case 0xc2: return false
        case 0xc3: return true
        case 0xc4, 0xc5, 0xc6: _ = try take(try uint(1 << (t - 0xc4))); return nil  // binary: not needed
        case 0xca: return Double(Float(bitPattern: UInt32(try uint(4))))
        case 0xcb: return Double(bitPattern: UInt64(try uint(8)))
        case 0xcc...0xcf: return try uint(1 << (t - 0xcc))
        case 0xd0...0xd3:  // signed: sign-extend from 8 << (t - 0xd0) bits
            let bits = 8 << (t - 0xd0), v = try uint(bits / 8)
            return bits < 64 && v >= 1 << (bits - 1) ? v - (1 << bits) : v
        case 0xd9, 0xda, 0xdb: return try string(try uint(1 << (t - 0xd9)))
        case 0xdc, 0xdd: return try array(try uint(t == 0xdc ? 2 : 4))
        case 0xde, 0xdf: return try map(try uint(t == 0xde ? 2 : 4))
        default: throw ConfigError(description: "its NKS knob pages (NICA) use MessagePack type \(t), which isn't supported")
        }
    }

    mutating func string(_ n: Int) throws -> String { String(decoding: try take(n), as: UTF8.self) }

    mutating func array(_ n: Int) throws -> [Any] { try (0..<n).map { _ in try value() as Any } }

    mutating func map(_ n: Int) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for _ in 0..<n {
            let key = try value()
            out["\(key ?? "")"] = try value()
        }
        return out
    }
}
