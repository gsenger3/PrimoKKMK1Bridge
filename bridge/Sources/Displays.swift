//
//  Displays.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The nine 8-character displays above the knobs (HID output report 0xE0): 16-segment font, layout, reports.

import Foundation

// MARK: - Displays (output report 0xE0)

let displayPayload = 248  // bytes after the report ID
let displayCells = 9      // nine displays of 8 characters: one left of knob 1, then one above each knob
let cellWidth = 8
let rowWidth = displayCells * cellWidth

/// 16-segment glyphs. Low byte: the outer ring clockwise from the top-left (a1 a2 b c d2 d1 e f); high
/// byte: the inner segments in reading order (h i j g1 g2 k l m). See device/NOTES.md.
let segmentBits: [String: UInt16] = [
    "a1": 1 << 0, "a2": 1 << 1, "b": 1 << 2, "c": 1 << 3, "d2": 1 << 4, "d1": 1 << 5, "e": 1 << 6, "f": 1 << 7,
    "h": 1 << 8, "i": 1 << 9, "j": 1 << 10, "g1": 1 << 11, "g2": 1 << 12, "k": 1 << 13, "l": 1 << 14, "m": 1 << 15,
    "a": 3, "d": 3 << 4, "g": 3 << 11,
]
let glyphSpecs: [(Character, String)] = [
    ("A", "a b c e f g"), ("B", "a b c d g2 i l"), ("C", "a d e f"), ("D", "a b c d i l"), ("E", "a d e f g1"),
    ("F", "a e f g1"), ("G", "a c d e f g2"), ("H", "b c e f g"), ("I", "a d i l"), ("J", "b c d e"),
    ("K", "e f g1 j m"), ("L", "d e f"), ("M", "b c e f h j"), ("N", "b c e f h m"), ("O", "a b c d e f"),
    ("P", "a b e f g"), ("Q", "a b c d e f m"), ("R", "a b e f g m"), ("S", "a c d f g"), ("T", "a i l"),
    ("U", "b c d e f"), ("V", "e f j k"), ("W", "b c e f k m"), ("X", "h j k m"), ("Y", "h j l"), ("Z", "a d j k"),
    ("0", "a b c d e f j k"), ("1", "b c"), ("2", "a b d e g"), ("3", "a b c d g2"), ("4", "b c f g"),
    ("5", "a c d f g"), ("6", "a c d e f g"), ("7", "a b c"), ("8", "a b c d e f g"), ("9", "a b c d f g"),
    ("-", "g"), ("+", "g i l"), ("/", "j k"), ("\\", "h m"), ("*", "g h i j k l m"), ("_", "d"), ("=", "d g"),
    ("<", "j m"), (">", "h k"), ("(", "j m"), (")", "h k"), ("[", "a d e f"), ("]", "a b c d"), ("'", "i"),
    ("\"", "b i"), ("|", "i l"), ("%", "a1 c d2 f g i j k l"), ("?", "a b g2 l"), ("!", "b c"),
    ("$", "a c d f g i l"), ("^", "k m"),
]
let glyphs: [Character: UInt16] = Dictionary(uniqueKeysWithValues: glyphSpecs.map { ch, spec in
    (ch, spec.split(separator: " ").reduce(UInt16(0)) { $0 | segmentBits[String($1)]! })
})

struct DisplayCell { var char: Character = " "; var glyph: UInt16 = 0; var dot = false }

/// Text as display cells: letters are shown in capitals, and "." or "," lights the dot of the cell before it.
func displayCells(_ s: String) -> [DisplayCell] {
    var out: [DisplayCell] = []
    for ch in s.folding(options: .diacriticInsensitive, locale: nil).uppercased() {
        if ch == "." || ch == "," {
            if let last = out.last, !last.dot { out[out.count - 1].dot = true } else { out.append(DisplayCell(char: " ", glyph: 0, dot: true)) }
        } else {
            let g = glyphs[ch] ?? 0
            out.append(DisplayCell(char: g == 0 ? " " : ch, glyph: g, dot: false))
        }
    }
    return out
}

/// Shorten a name to fit `width` cells: drop vowels word by word (longest first), then trim the longest
/// word, keeping at least two letters of each; drop the spaces only if that still doesn't fit.
func abbreviate(_ s: String, _ width: Int) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard displayCells(t).count > width else { return t }
    var words = t.split(whereSeparator: { " _-".contains($0) }).map(String.init)
    func fits(_ w: [String], _ sep: String) -> Bool { displayCells(w.joined(separator: sep)).count <= width }
    for i in words.indices.sorted(by: { words[$0].count > words[$1].count }) where !fits(words, " ") {
        let w = words[i]
        words[i] = String(w.prefix(1)) + w.dropFirst().filter { !"aeiouAEIOU".contains($0) }
    }
    while !fits(words, " "), let i = words.indices.max(by: { words[$0].count < words[$1].count }), words[i].count > 2 {
        words[i].removeLast()
    }
    return fits(words, " ") ? words.joined(separator: " ") : words.joined()
}

/// Shorten a value ("-12.0 dB") by dropping spaces when it doesn't fit.
func fitValue(_ s: String, _ width: Int) -> String {
    let t = s.trimmingCharacters(in: .whitespaces)
    return displayCells(t).count > width ? t.replacingOccurrences(of: " ", with: "") : t
}

final class Displays {
    private(set) var cells = [[DisplayCell]](repeating: [DisplayCell](repeating: DisplayCell(), count: rowWidth), count: 2)
    private(set) var bars = [[UInt8]](repeating: [UInt8](repeating: 0, count: 9), count: displayCells)

    func clear() {
        cells = [[DisplayCell]](repeating: [DisplayCell](repeating: DisplayCell(), count: rowWidth), count: 2)
        bars = [[UInt8]](repeating: [UInt8](repeating: 0, count: 9), count: displayCells)
    }

    /// Write text on row 0 (top) or 1 starting at a display; it runs on into the next `span - 1` displays,
    /// moving a word that would straddle two displays onto the next one when it fits there.
    func write(row: Int, cell: Int, _ s: String, span: Int = 1) {
        let start = cell * cellWidth, limit = min(rowWidth, start + span * cellWidth)
        var x = start
        for (n, word) in s.split(separator: " ", omittingEmptySubsequences: true).enumerated() {
            let w = displayCells(String(word))
            if n > 0 && x % cellWidth != 0 { x += 1 }  // the space between words, unless a new display starts here
            let used = x % cellWidth
            if span > 1, used != 0, used + w.count > cellWidth, w.count <= cellWidth { x += cellWidth - used }
            for var c in w {
                guard x < limit else { return }
                if x % cellWidth == cellWidth - 1 { c.dot = false }  // the last character of a display has no dot
                cells[row][x] = c
                x += 1
            }
        }
    }

    /// The value bar under a display: 9 segments with 4 steps each, optionally framed.
    func setBar(cell: Int, _ value: Double?, framed: Bool) {
        var seg = [UInt8](repeating: 0, count: 9)
        if let value {
            let v = Int((max(0, min(1, value)) * 36).rounded())
            let full = v / 4
            for i in 0..<min(full, 9) { seg[i] = 3 }
            if full < 9 { seg[full] = [0, 2, 1, 3][v % 4] }  // in the protocol, 2 draws one step and 1 draws two
        }
        if framed { for i in 0..<9 { seg[i] += 68 } }
        bars[cell] = seg
    }

    /// A pan bar: the middle segment, filled out to the left or right (0 = hard left, 0.5 = centre, 1 = hard right).
    func setPanBar(cell: Int, _ value: Double?, framed: Bool) {
        var seg = [UInt8](repeating: 0, count: 9)
        if let value {
            let v = max(0, min(1, value))
            let n = Int((abs(v - 0.5) * 8).rounded())
            seg[4] = 3
            if v < 0.5 { for i in (4 - n)..<4 { seg[i] = 3 } } else { for i in 5..<(5 + n) { seg[i] = 3 } }
        }
        if framed { for i in 0..<9 { seg[i] += 68 } }
        bars[cell] = seg
    }

    /// The output report for row 0 (bars and dots) or rows 1-2 (text), report ID first.
    func report(row: Int) -> [UInt8] {
        var r: [UInt8] = [reportDisplay, 0x00, 0x00, UInt8(row), 0x00, UInt8(rowWidth), 0x00, 0x01, 0x00]
        if row == 0 {
            for x in 0..<rowWidth {
                let cell = x / cellWidth, i = x % cellWidth
                r.append(bars[cell][i])
                if i == cellWidth - 1 {
                    r.append(bars[cell][8])
                } else {
                    let top = cells[0][x].dot, bottom = cells[1][x].dot
                    r.append(top ? (bottom ? 255 : 253) : (bottom ? 254 : 0))
                }
            }
        } else {
            for c in cells[row - 1] { r.append(UInt8(c.glyph & 0xff)); r.append(UInt8(c.glyph >> 8)) }
        }
        return r + [UInt8](repeating: 0, count: 1 + displayPayload - r.count)
    }

    /// Text rows and bars as plain text, for logs and replays.
    func ascii() -> [String] {
        var lines = (0..<2).map { row in
            (0..<displayCells).map { cell in
                cells[row][(cell * cellWidth)..<((cell + 1) * cellWidth)].map { String($0.char) + ($0.dot ? "." : "") }.joined()
            }.joined(separator: "|")
        }
        lines.append((0..<displayCells).map { cell in
            let b = bars[cell]
            let body = b.map { v -> String in let s = v >= 68 ? v - 68 : v; return s == 0 ? " " : (s == 3 ? "#" : "+") }.joined()
            return (b[0] >= 68 ? "[" : " ") + body.prefix(7) + (b[0] >= 68 ? "]" : " ")
        }.joined(separator: "|"))
        return lines
    }
}

/// Print every glyph as a small segment drawing (to check the font without a keyboard).
func showFont() {
    for (ch, _) in glyphSpecs {
        let g = glyphs[ch]!
        func on(_ s: String) -> Bool { g & segmentBits[s]! != 0 }
        func p(_ s: String, _ c: Character) -> Character { on(s) ? c : " " }
        let rows: [[Character]] = [
            [" ", p("a1", "-"), p("a1", "-"), " ", p("a2", "-"), p("a2", "-"), " "],
            [p("f", "|"), p("h", "\\"), " ", p("i", "|"), " ", p("j", "/"), p("b", "|")],
            [" ", p("g1", "-"), p("g1", "-"), " ", p("g2", "-"), p("g2", "-"), " "],
            [p("e", "|"), p("k", "/"), " ", p("l", "|"), " ", p("m", "\\"), p("c", "|")],
            [" ", p("d1", "-"), p("d1", "-"), " ", p("d2", "-"), p("d2", "-"), " "],
        ]
        print("'\(ch)' 0x" + String(format: "%04x", g))
        for r in rows { print("   " + String(r)) }
    }
}
