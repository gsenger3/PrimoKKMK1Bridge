// PrimoKKMK1Bridge — every control on a Komplete Kontrol S-series MK1, as MIDI on a virtual port, with an
// optional link to REAPER over OSC (macOS).
//
// The keyboard's own MIDI port keeps sending keys, pitch strip and mod strip. PrimoKKMK1Bridge switches the
// keyboard into native (host) mode with HID output report a0 00 00 (the init that NI's software and
// DrivenByMoss send), then turns the HID button, knob, touch and Navigate-knob reports into MIDI CCs
// on a virtual source ("Primo Komplete Kontrol MK1" by default).
//
// Button lights: in native mode the computer drives them (HID output report 0x80). PrimoKKMK1Bridge keeps
// mapped buttons dimly lit, lights a button fully while it is held, and lets the DAW switch lights on
// and off by sending the button's CC back to the virtual destination of the same name (value > 0 = lit).
// Knob CCs sent back to that destination also update PrimoKKMK1Bridge's absolute knob values, so a knob picks
// up from the DAW's value instead of jumping.
//
// Displays: the nine 8-character displays (HID output report 0xE0; one left of knob 1, one above each
// knob) show what the knobs control: CC numbers and values, or in REAPER mode track names and values.
//
// REAPER mode ("reaper": {"enabled": true}) talks to a REAPER OSC control surface. Mix view: the knobs are
// the volumes of 8 tracks at a time, and the page buttons scroll through the project's tracks. Track view
// (Instance switches): the knobs are the selected track's volume, pan, mute, solo and sends, and the
// up/down buttons under the Navigate knob (or turning it) pick the track. Transport buttons drive REAPER's
// transport. With Shift held, buttons and knobs send MIDI CCs on the Shift channel as in plain mode, apart
// from the Shift shortcuts in reaper.shiftButtons and the volume/pan resets. Buttons with no REAPER command
// send their CCs.
//
//   swiftc -O bridge/PrimoKKMK1Bridge.swift -o build/PrimoKKMK1Bridge
//   build/PrimoKKMK1Bridge [--config bridge/PrimoKKMK1Bridge.json] [--verbose]
//   build/PrimoKKMK1Bridge --print-default-config > bridge/PrimoKKMK1Bridge.json
//   build/PrimoKKMK1Bridge --replay device/tests/native_knobs_results/capture_mapping.log [--config ...]
//   build/PrimoKKMK1Bridge --show-font
//
// Native mode is not persistent: replugging returns the keyboard to MIDI mode. After PrimoKKMK1Bridge quits,
// the keyboard stays in native mode (knobs silent on its own MIDI port) until it is replugged.
// Protocol details: device/NOTES.md.

import CoreMIDI
import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Hardware map (verified on an S61 MK1, firmware 72)

let niVendorID = 0x17cc
let mk1Models: [Int: String] = [0x1340: "S25 MK1", 0x1350: "S49 MK1", 0x1360: "S61 MK1", 0x1410: "S88 MK1"]
let reportUI: UInt8 = 0x01    // input: buttons, touch, Navigate knob, knob positions, base note
let reportPage: UInt8 = 0x0f  // input: knob page; only sent while the keyboard is in MIDI mode
let reportLights: UInt8 = 0x80  // output: 25 button-light brightness bytes
let reportInit: UInt8 = 0xa0  // output: switch to native mode
let reportDisplay: UInt8 = 0xe0  // output: one display row (value bars and dots, or text)
let lightCount = 25

struct ButtonDef { let name: String; let bit: Int; let cc: Int }

/// Button bit n is in report byte 1 + n/8, mask 1 << (n % 8). Default CCs avoid the defined CCs.
let buttonDefs: [ButtonDef] = [
    ButtonDef(name: "NavigateClick", bit: 0, cc: 90),
    ButtonDef(name: "PresetUp", bit: 1, cc: 119),
    ButtonDef(name: "Enter", bit: 2, cc: 118),
    ButtonDef(name: "PresetDown", bit: 3, cc: 85),
    ButtonDef(name: "Browse", bit: 4, cc: 115),
    ButtonDef(name: "Instance", bit: 5, cc: 116),
    ButtonDef(name: "OctaveDown", bit: 6, cc: 111),
    ButtonDef(name: "OctaveUp", bit: 7, cc: 112),
    ButtonDef(name: "Stop", bit: 8, cc: 103),
    ButtonDef(name: "Rec", bit: 9, cc: 104),
    ButtonDef(name: "Play", bit: 10, cc: 102),
    ButtonDef(name: "NavRight", bit: 11, cc: 89),
    ButtonDef(name: "NavDown", bit: 12, cc: 87),
    ButtonDef(name: "NavLeft", bit: 13, cc: 88),
    ButtonDef(name: "Back", bit: 14, cc: 117),
    ButtonDef(name: "NavUp", bit: 15, cc: 86),
    ButtonDef(name: "Shift", bit: 16, cc: 108),
    ButtonDef(name: "Scale", bit: 17, cc: 109),
    ButtonDef(name: "Arp", bit: 18, cc: 110),
    ButtonDef(name: "Loop", bit: 19, cc: 105),
    ButtonDef(name: "PageRight", bit: 20, cc: 114),
    ButtonDef(name: "PageLeft", bit: 21, cc: 113),
    ButtonDef(name: "Rewind", bit: 22, cc: 106),
    ButtonDef(name: "FastForward", bit: 23, cc: 107),
]
let shiftBit = 16
let knobTouchFirstBit = 24  // knobs 1-8 touch = bits 24-31
let navigateTouchBit = 32

/// Light positions in output report 0x80, from DrivenByMoss. Octave −/+ and the Navigate click have none.
let lightSlot: [String: Int] = [
    "Shift": 0, "Scale": 1, "Arp": 2, "Loop": 3, "Rewind": 4, "FastForward": 5, "Play": 6, "Rec": 7,
    "Stop": 8, "PageLeft": 9, "PageRight": 10, "Browse": 11, "PresetUp": 12, "Instance": 13,
    "PresetDown": 14, "Back": 15, "NavUp": 16, "Enter": 17, "NavLeft": 18, "NavDown": 19, "NavRight": 20,
]

func isSet(_ r: [UInt8], _ bit: Int) -> Bool { r[1 + bit / 8] & UInt8(1 << (bit % 8)) != 0 }

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(("PrimoKKMK1Bridge: " + s + "\n").data(using: .utf8)!)
    exit(2)
}

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

// MARK: - OSC over UDP (REAPER link)

enum OSCArg: Equatable, CustomStringConvertible {
    case int(Int32), float(Float), string(String)
    var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .float(let v): return Double(v)
        case .string: return nil
        }
    }
    var text: String? { if case .string(let s) = self { return s } else { return nil } }
    var description: String {
        switch self {
        case .int(let v): return "\(v)"
        case .float(let v): return String(format: "%g", v)
        case .string(let s): return "\"\(s)\""
        }
    }
}

typealias OSCMessage = (address: String, args: [OSCArg])

enum OSC {
    private static func put(_ s: String, _ d: inout [UInt8]) {
        d += Array(s.utf8)
        d.append(0)
        while d.count % 4 != 0 { d.append(0) }
    }

    static func encode(_ address: String, _ args: [OSCArg]) -> [UInt8] {
        var d: [UInt8] = []
        put(address, &d)
        put("," + args.map { a -> String in
            switch a {
            case .int: return "i"
            case .float: return "f"
            case .string: return "s"
            }
        }.joined(), &d)
        for a in args {
            switch a {
            case .int(let v): d += withUnsafeBytes(of: v.bigEndian) { Array($0) }
            case .float(let v): d += withUnsafeBytes(of: v.bitPattern.bigEndian) { Array($0) }
            case .string(let s): put(s, &d)
            }
        }
        return d
    }

    /// The messages in a packet, with bundles flattened. Malformed parts are skipped.
    static func decode(_ data: [UInt8]) -> [OSCMessage] {
        var out: [OSCMessage] = []
        decode(data[...], depth: 0, into: &out)
        return out
    }

    private static func decode(_ d: ArraySlice<UInt8>, depth: Int, into out: inout [OSCMessage]) {
        var i = d.startIndex
        guard depth < 8, let head = string(d, &i) else { return }
        if head == "#bundle" {
            i += 8  // time tag
            while let n = int32(d, &i), n > 0, i + Int(n) <= d.endIndex {
                decode(d[i..<(i + Int(n))], depth: depth + 1, into: &out)
                i += Int(n)
            }
            return
        }
        guard head.hasPrefix("/") else { return }
        var args: [OSCArg] = []
        if i < d.endIndex, d[i] == UInt8(ascii: ","), let tags = string(d, &i) {
            for t in tags.dropFirst() {
                switch t {
                case "i": guard let v = int32(d, &i) else { return }; args.append(.int(v))
                case "f": guard let v = int32(d, &i) else { return }; args.append(.float(Float(bitPattern: UInt32(bitPattern: v))))
                case "s", "S": guard let s = string(d, &i) else { return }; args.append(.string(s))
                case "d":
                    guard let hi = int32(d, &i), let lo = int32(d, &i) else { return }
                    let bits = UInt64(UInt32(bitPattern: hi)) << 32 | UInt64(UInt32(bitPattern: lo))
                    args.append(.float(Float(Double(bitPattern: bits))))
                case "h":
                    guard let hi = int32(d, &i), let lo = int32(d, &i) else { return }
                    let v = Int64(bitPattern: UInt64(UInt32(bitPattern: hi)) << 32 | UInt64(UInt32(bitPattern: lo)))
                    args.append(.int(Int32(clamping: v)))
                case "T": args.append(.int(1))
                case "F": args.append(.int(0))
                case "N", "I": break
                case "b": guard let n = int32(d, &i), n >= 0 else { return }; i += (Int(n) + 3) & ~3
                default: return  // unknown type: the rest can't be read
                }
            }
        }
        out.append((head, args))
    }

    private static func string(_ d: ArraySlice<UInt8>, _ i: inout Int) -> String? {
        guard i < d.endIndex, let end = d[i...].firstIndex(of: 0) else { return nil }
        let s = String(decoding: d[i..<end], as: UTF8.self)
        i = min(d.endIndex, d.startIndex + ((end + 1 - d.startIndex + 3) & ~3))
        return s
    }

    private static func int32(_ d: ArraySlice<UInt8>, _ i: inout Int) -> Int32? {
        guard i + 4 <= d.endIndex else { return nil }
        let v = UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
        i += 4
        return Int32(bitPattern: v)
    }
}

final class OSCLink {
    private let fd: Int32
    private let dest: sockaddr_in
    private var source: DispatchSourceRead?
    var onMessage: ((String, [OSCArg]) -> Void)?

    init(host: String, sendPort: Int, receivePort: Int) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(sendPort), &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else {
            throw ConfigError(description: "reaper.host: cannot resolve \"\(host)\"")
        }
        dest = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        freeaddrinfo(res)

        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ConfigError(description: "cannot create a UDP socket (errno \(errno))") }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(UInt16(receivePort).bigEndian)
        // Listen on loopback only when REAPER is on this Mac.
        let loopback = UInt32(bigEndian: dest.sin_addr.s_addr) >> 24 == 127
        local.sin_addr.s_addr = loopback ? UInt32(0x7f00_0001).bigEndian : INADDR_ANY
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw ConfigError(description: e == EADDRINUSE
                ? "UDP port \(receivePort) is already in use (another PrimoKKMK1Bridge?). Change reaper.receivePort, and REAPER's device port to match."
                : "cannot listen on UDP port \(receivePort) (errno \(e))")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
    }

    private func drain() {
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { break }
            for m in OSC.decode(Array(buf[0..<n])) { onMessage?(m.address, m.args) }
        }
    }

    func send(_ address: String, _ args: [OSCArg]) {
        let d = OSC.encode(address, args)
        var to = dest
        _ = d.withUnsafeBytes { buf in
            withUnsafePointer(to: &to) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}

// MARK: - REAPER commands and state

enum ReaperCommand: Equatable {
    case play, stop, record, repeatToggle, rewind, forward
    case previousTrack, nextTrack, previousPage, nextPage, toggleView, mute, solo, metronome
    case goToStart, previousMarker, nextMarker, recordMode, undo, redo, browseFX, closeFX, panic
    case saveProject, renderProject
    case screenset(Int)  // REAPER window set 1-10
    case action(Int)

    static let named: [(String, ReaperCommand)] = [
        ("play", .play), ("stop", .stop), ("record", .record), ("repeat", .repeatToggle),
        ("rewind", .rewind), ("forward", .forward),
        ("previous-track", .previousTrack), ("next-track", .nextTrack),
        ("previous-page", .previousPage), ("next-page", .nextPage),
        ("toggle-view", .toggleView), ("mute", .mute), ("solo", .solo), ("metronome", .metronome),
        ("go-to-start", .goToStart), ("previous-marker", .previousMarker), ("next-marker", .nextMarker),
        ("record-mode", .recordMode), ("undo", .undo), ("redo", .redo),
        ("browse-fx", .browseFX), ("close-fx", .closeFX), ("panic", .panic),
        ("save-project", .saveProject), ("render-project", .renderProject),
    ]
    static var validNames: String {
        named.map(\.0).joined(separator: ", ") + ", screenset:<1-10>, action:<REAPER command ID>"
    }

    init?(_ s: String) {
        if s.hasPrefix("screenset:") {
            guard let n = Int(s.dropFirst(10)), (1...10).contains(n) else { return nil }
            self = .screenset(n)
            return
        }
        if s.hasPrefix("action:") {
            guard let id = Int(s.dropFirst(7)), id > 0, id <= Int(Int32.max) else { return nil }
            self = .action(id)
            return
        }
        guard let c = Self.named.first(where: { $0.0 == s })?.1 else { return nil }
        self = c
    }
}

let navigateTurnTargets = ["tracks", "pages"]
let bankSize = 8      // tracks per mix-view page, one per knob
let sendSlots = 16    // sends REAPER reports for the selected track; track view pages through them
let fxSlots = 16      // plugins REAPER reports for the selected track (Browse steps through their windows)

/// "VST3: Komplete Kontrol (Native Instruments) (32 out)" -> "Komplete Kontrol"
func pluginName(_ s: String) -> String {
    var n = s
    let kinds: Set<String> = ["VST", "VSTi", "VST3", "VST3i", "AU", "AUi", "JS", "CLAP", "CLAPi", "LV2", "LV2i", "DX", "DXi"]
    if let r = n.range(of: ": "), kinds.contains(String(n[..<r.lowerBound])) { n = String(n[r.upperBound...]) }
    while n.hasSuffix(")"), let open = n.range(of: " (", options: .backwards) { n = String(n[..<open.lowerBound]) }
    return n.isEmpty ? s : n
}
let toggleTurn = 24   // raw knob units to turn mute or solo on (right) or off (left)
// REAPER action command IDs, checked against REAPER 7.61's action table.
let refreshSurfacesAction: Int32 = 41743  // "Control surface: refresh all surfaces"
let goToStartAction: Int32 = 40042        // "Transport: Go to start of project"
let previousMarkerAction: Int32 = 40172   // "Markers: Go to previous marker/project start"
let nextMarkerAction: Int32 = 40173       // "Markers: Go to next marker/project end"
let recordNormalAction: Int32 = 40252     // "Record: Set record mode to normal"
let recordAutoPunchAction: Int32 = 40076  // "Record: Set record mode to time selection auto-punch"
let undoAction: Int32 = 40029             // "Edit: Undo"
let redoAction: Int32 = 40030             // "Edit: Redo"
let unselectAllTracksAction: Int32 = 40297  // "Track: Unselect (clear selection of) all tracks"
let scrollToSelectedAction: Int32 = 40913   // "Track: Vertical scroll selected tracks into view"
let panicAction: Int32 = 40345  // "Send all-notes-off and all-sounds-off to all MIDI outputs/plug-ins"
let saveProjectAction: Int32 = 40026    // "File: Save project"
let renderProjectAction: Int32 = 40015  // "File: Render project to disk..." (opens the Render dialog)
let windowSet1Action: Int32 = 40454     // "Screenset: Load window set #01"; #02-#10 follow in order

struct TrackStrip {
    var name = "", number = ""
    var volume: Double?, volumeText = "", volumeDB: Double?
    var pan: Double?, panText = "", width: Double?
    var mute = false, solo = false
    var recArm = false
    var monitor = 0  // record monitoring: 0 off, 1 on, 2 auto (tape style)
    /// REAPER fills a page past the last track with stand-ins: "Track 5" at -inf dB (-150) and 0% width
    /// (pan2 0.5). A real unnamed track is also called "Track 5", but has a real volume and 100% width.
    var isPlaceholder: Bool {
        name == "Track \(number)" && (volumeDB ?? 0) <= -150 && abs((width ?? 1) - 0.5) < 0.001
    }
    var exists: Bool { (!number.isEmpty || !name.isEmpty) && !isPlaceholder }
    var label: String { name.isEmpty ? "Track \(number)" : name }
}

struct SendStrip {
    var name = "", volume: Double?, volumeText = ""
    /// REAPER reports every send slot; unused ones are called "Send N" (their slot number) at -inf dB.
    func isRouted(slot: Int) -> Bool { !name.isEmpty && !(name == "Send \(slot + 1)" && volumeText == "-inf dB") }
}

enum ReaperView: CaseIterable {
    case mix, track, kk  // kk: the Komplete Kontrol view
    /// The name in the config (reaper.view) and the logs.
    var configName: String {
        switch self {
        case .mix: return "mix"
        case .track: return "track"
        case .kk: return "komplete-kontrol"
        }
    }
}
enum ReaperEvent {  // trackData: a value of the selected track
    case connected, track, trackData, bank, values, transport, view, recordMode
    case pluginShown(Int), pluginsClosed, noPlugins  // Browse / Shift + Browse
    case panic, saved, render, screenset(Int)
    case kkParam(Int)  // a host parameter of the device FX (the Komplete Kontrol plugin in that view) changed
}

/// What a knob controls in the current view and page.
enum KnobTarget: Equatable {
    case bankVolume(Int)  // mix view: volume of bank slot 0-7
    case volume, pan, mute, solo, recArm
    case send(Int)        // track view: send 0-15 of the selected track
}

/// What the displays show for one knob.
struct KnobInfo { let name: String; let short: String; let value: String; let bar: Double?; let isPan: Bool }

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

    // Komplete Kontrol view. The KK plugin exposes the loaded instrument's NKS parameters to the host, in NKS
    // page order, from its parameter "101 <name>" on (8 per page; "NNN -" is an empty slot). The bridge has
    // REAPER report the KK plugin's parameters (/fxparam/N/...) and mirrors them all, since REAPER only sends
    // values that changed.
    struct HostParam { var name = "", value: Double? = nil, text = "" }
    private(set) var devParams: [Int: HostParam] = [:]   // device FX host parameter N (1-based)
    private var deviceFX: Int?                           // the FX (0-based) REAPER reports parameters for
    private var kkPageByTrack: [String: Int] = [:]       // KK's NKS page, per track
    var kkFX: Int? { fxNames.firstIndex { pluginName($0).hasPrefix("Komplete Kontrol") } }
    var kkPage: Int {
        get { kkPageByTrack[track.number] ?? 0 }
        set { kkPageByTrack[track.number] = newValue }
    }
    /// NKS slot (0-based: page * 8 + knob) of a KK host parameter named "101 Volume" and on.
    static func nksSlot(_ name: String) -> Int? {
        guard let label = Int(name.prefix { $0.isNumber }), label >= 101 else { return nil }
        return label - 101
    }
    /// The NKS parameters (by slot) of the KK plugin; empty slots ("NNN -") are left out.
    var nks: [Int: HostParam] {
        guard deviceFX != nil, deviceFX == kkFX else { return [:] }
        var out: [Int: HostParam] = [:]
        for (_, p) in devParams {
            guard let slot = Self.nksSlot(p.name) else { continue }
            let name = String(p.name.drop { $0.isNumber }).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "-" else { continue }
            out[slot] = HostParam(name: name, value: p.value, text: p.text)
        }
        return out
    }
    var nksPages: Int { (nks.keys.max() ?? 0) / 8 + 1 }

    /// All 256 parameters of the device FX (the KK plugin's NKS ones start at 102) in the Komplete Kontrol view;
    /// just 1 in the other views, so a track change there doesn't bring a burst of plugin parameters.
    private func setParamReporting(_ on: Bool) {
        send("/device/fxparam/count", [.int(on && cfg.kompleteKontrol.hostParameters ? 256 : 1)])
    }

    /// In the Komplete Kontrol view, have REAPER report the selected track's KK plugin's parameters.
    func ensureKKSelected() {
        guard view == .kk, cfg.kompleteKontrol.hostParameters, let idx = kkFX, idx != deviceFX else { return }
        deviceFX = idx
        send("/device/fx/select", [.int(Int32(idx + 1))])
    }
    /// REAPER doesn't report the record mode over OSC, so this is the mode we last set (or saw an action report).
    private(set) var autoPunch = false
    private(set) var connected = false
    private var lastHandshake = Date.distantPast
    private var lastSent: [String: Date] = [:]           // address -> when a knob last set it
    private var toggleAccum = [Int](repeating: 0, count: 8)
    private var touchAddress = [String?](repeating: nil, count: 8)
    var onEvent: ((ReaperEvent) -> Void)?
    var onSend: ((String, [OSCArg]) -> Void)?
    var onReceive: ((String, [OSCArg]) -> Void)?

    init(cfg: ReaperConfig) throws {
        self.cfg = cfg
        view = ReaperView.allCases.first { $0.configName == cfg.view } ?? .mix
        link = try OSCLink(host: cfg.host, sendPort: cfg.sendPort, receivePort: cfg.receivePort)
        link.onMessage = { [weak self] in self?.receive($0, $1) }
    }

    /// Slots of the selected track's sends that are routed somewhere (unused slots are left out).
    var routedSends: [Int] { sends.indices.filter { sends[$0].isRouted(slot: $0) } }
    var sendCount: Int { routedSends.count }
    /// Track view page 1: volume, pan, mute, solo, record arm and sends 1-3; each later page: 8 more sends.
    var sendPages: Int { sendCount <= 3 ? 1 : 1 + (sendCount - 3 + 7) / 8 }

    func send(_ address: String, _ args: [OSCArg] = [.float(1)]) {
        link.send(address, args)
        onSend?(address, args)
    }

    /// Ask REAPER for 8 tracks per page and all sends of the selected track, to follow the track last clicked,
    /// and to send everything again: REAPER only sends values that changed since it last sent them, so
    /// without this a bridge started after REAPER never hears about tracks, pans or sends that haven't moved.
    func handshake() {
        guard Date().timeIntervalSince(lastHandshake) > 2 else { return }
        lastHandshake = Date()
        send("/device/track/count", [.int(Int32(bankSize))])
        send("/device/send/count", [.int(Int32(sendSlots))])
        send("/device/fx/count", [.int(Int32(fxSlots))])
        send("/device/fx/follows/device")
        setParamReporting(view == .kk)
        deviceFX = nil
        if cfg.followSelectedTrack { send("/device/track/follows/last_touched") }
        send("/action", [.int(refreshSurfacesAction)])
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
            if view == .track && cfg.mirrorSelection {
                // Make it REAPER's selected track too (only it), and scroll it into view. REAPER handles these in
                // order, so /track/select applies to the track just moved to.
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
            case .mix: view = .track
            case .track: view = .kk
            case .kk: view = .mix
            }
            sendPage = 0
            if view == .kk { setParamReporting(true); deviceFX = nil; ensureKKSelected() }
            if view == .mix { setParamReporting(false) }
            onEvent?(.view)
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

    func navigate(_ target: String, steps: Int) {
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

    func info(_ t: KnobTarget) -> KnobInfo {
        switch t {
        case .bankVolume(let i):
            let s = bank[i]
            return KnobInfo(name: s.label, short: s.label, value: s.volumeText, bar: s.volume, isPan: false)
        case .volume: return KnobInfo(name: "Volume", short: "Volume", value: track.volumeText, bar: track.volume, isPan: false)
        case .pan:  // REAPER reports a centred pan as "C"
            let text = ["c", "center"].contains(track.panText.lowercased()) ? "CENTER" : track.panText
            return KnobInfo(name: "Pan", short: "Pan", value: text, bar: track.pan, isPan: true)
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

    /// A knob turned by `d` raw units (positive = clockwise).
    func turn(_ k: Int, raw d: Int) {
        guard let t = target(k) else { return }
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

    /// Shift + a volume knob (track view knob 1, or any knob in mix view): volume straight to 0 dB. Sent in dB,
    /// since the 0-1 fader position of 0 dB depends on REAPER's fader settings.
    @discardableResult
    func resetVolume(_ k: Int) -> Bool {
        let path: String
        switch target(k) {
        case .bankVolume(let i)?:
            guard abs(bank[i].volumeDB ?? 1) > 0.01 else { return false }
            bank[i].volumeDB = 0
            path = "/track/\(i + 1)/volume"
        case .volume?:
            guard abs(track.volumeDB ?? 1) > 0.01 else { return false }
            track.volumeDB = 0
            path = "/track/volume"
        default:
            return false
        }
        lastSent[path] = nil  // take REAPER's new fader position
        send(path + "/db", [.float(0)])
        onEvent?(.values)
        return true
    }

    /// Knob touch: tells REAPER the fader is being touched (for automation in touch mode).
    func touch(_ k: Int, _ on: Bool) {
        if on {
            toggleAccum[k] = 0
            switch target(k) {
            case .bankVolume(let i)?: touchAddress[k] = "/track/\(i + 1)/volume/touch"
            case .volume?: touchAddress[k] = "/track/volume/touch"
            case .pan?: touchAddress[k] = "/track/pan/touch"
            default: touchAddress[k] = nil
            }
            if let a = touchAddress[k] { send(a, [.float(1)]) }
        } else if let a = touchAddress[k] {
            send(a, [.float(0)])  // released where it was touched, even if the view changed meanwhile
            touchAddress[k] = nil
        }
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
                if changed { lastShown = nil; deviceFX = nil; ensureKKSelected() }
                onEvent?(changed ? .track : .trackData)
            }
        case "play" where p.count == 1: playing = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "record" where p.count == 1: recording = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "repeat" where p.count == 1: repeating = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "click" where p.count == 1: metronome = (args.first?.number ?? 0) > 0.5; onEvent?(.transport)
        case "fx" where p.count == 3:  // /fx/N/name, /fx/N/openui: the selected track's plugins
            guard let n = Int(p[1]), (1...fxSlots).contains(n) else { return }
            switch p[2] {
            case "name":
                fxNames[n - 1] = args.first?.text ?? ""
                ensureKKSelected()
            case "openui": fxOpen[n - 1] = (args.first?.number ?? 0) > 0.5
            default: return
            }
            onEvent?(.values)
        case "fxparam" where p.count >= 3:  // /fxparam/N/name, value, value/str: the device FX's parameters
            guard let n = Int(p[1]), n >= 1 else { return }
            var hp = devParams[n] ?? HostParam()
            switch p.dropFirst(2).joined(separator: "/") {
            case "name": hp.name = args.first?.text ?? ""
            case "value": hp.value = args.first?.number
            case "value/str": hp.text = args.first?.text ?? ""
            default: return
            }
            devParams[n] = hp
            onEvent?(.kkParam(n))
        case "action" where p.count == 2 && (args.first?.number ?? 0) > 0.5:  // action state, if REAPER reports it
            if p[1] == String(recordAutoPunchAction) { autoPunch = true; onEvent?(.transport) }
            if p[1] == String(recordNormalAction) { autoPunch = false; onEvent?(.transport) }
        default: break
        }
    }
}

// MARK: - Config

struct ConfigError: Error, CustomStringConvertible { let description: String }

enum TurnMode: String, Codable {
    case absolute
    case relativeBinaryOffset = "relative-binary-offset"
    case relativeTwosComplement = "relative-twos-complement"
    case relativeSignedBit = "relative-signed-bit"
}

/// The Komplete Kontrol view: the knobs and navigation buttons send fixed MIDI CCs on the virtual port (an
/// NKS-style assignment like the Novation Launchkey MK4's) for Komplete Kontrol to pick up.
struct KKViewConfig: Codable {
    var channel = 1
    var encoderCCs = Array(21...28)
    var encoderMode = TurnMode.absolute
    var buttons: [String: Int?] = [
        "PresetUp": 37, "PresetDown": 36, "NavUp": 41, "NavDown": 40, "NavLeft": 42, "NavRight": 43,
    ]
    /// The buttons that make Komplete Kontrol show the previous / next NKS page, so the displays follow.
    var pageButtons = ["NavLeft", "NavRight"]
    /// Experimental, off: show the KK plugin's host parameters from "101" on, 8 per page. These are the loaded
    /// instrument's full parameter list, not KK's curated NKS pages, so they don't line up with KK's knobs,
    /// and asking REAPER for 256 parameters makes it send thousands of messages.
    var hostParameters = false
    /// The buttons that load the previous / next preset in Komplete Kontrol: the remembered knob values of that
    /// track are dropped and the page goes back to 1.
    var presetButtons = ["PresetUp", "PresetDown"]

    enum CodingKeys: String, CodingKey {
        case channel, encoderCCs, encoderMode, buttons, pageButtons, hostParameters, presetButtons
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? channel
        encoderCCs = try c.decodeIfPresent([Int].self, forKey: .encoderCCs) ?? encoderCCs
        encoderMode = try c.decodeIfPresent(TurnMode.self, forKey: .encoderMode) ?? encoderMode
        pageButtons = try c.decodeIfPresent([String].self, forKey: .pageButtons) ?? pageButtons
        hostParameters = try c.decodeIfPresent(Bool.self, forKey: .hostParameters) ?? hostParameters
        presetButtons = try c.decodeIfPresent([String].self, forKey: .presetButtons) ?? presetButtons
        if let user = try c.decodeIfPresent([String: Int?].self, forKey: .buttons) {
            for (name, cc) in user {
                guard name != "Shift", buttonDefs.contains(where: { $0.name == name }) else {
                    throw ConfigError(description: "reaper.kompleteKontrol.buttons: unknown button \"\(name)\"")
                }
                buttons.updateValue(cc, forKey: name)
            }
        }
    }

    func validate() throws {
        guard (1...16).contains(channel) else {
            throw ConfigError(description: "reaper.kompleteKontrol.channel must be 1-16, got \(channel)")
        }
        guard presetButtons.allSatisfy({ buttons[$0] != nil }) else {
            throw ConfigError(description: "reaper.kompleteKontrol.presetButtons must be buttons from its buttons list")
        }
        guard pageButtons.isEmpty || (pageButtons.count == 2 && pageButtons.allSatisfy { buttons[$0] != nil }) else {
            throw ConfigError(description: "reaper.kompleteKontrol.pageButtons needs 2 buttons from its buttons list (previous, next), or []")
        }
        guard encoderCCs.count == 8, encoderCCs.allSatisfy({ (0...127).contains($0) }) else {
            throw ConfigError(description: "reaper.kompleteKontrol.encoderCCs needs 8 CCs, each 0-127")
        }
        for (name, cc) in buttons {
            if let cc, !(0...127).contains(cc) {
                throw ConfigError(description: "reaper.kompleteKontrol.buttons.\(name) must be 0-127, got \(cc)")
            }
        }
    }
}

struct ReaperConfig: Codable {
    var enabled = false
    var host = "127.0.0.1"
    var sendPort = 8000     // REAPER's "Local listen port"
    var receivePort = 9000  // REAPER's "Device port"
    var view = "mix"
    var followSelectedTrack = true
    var knobFullRange = 600
    var navigateTurn: String? = "tracks"
    var trackNameSeconds = 2.0  // after a track change, how long only its number and name show
    var mirrorSelection = true  // track view: a track picked on the keyboard becomes REAPER's selected track
    var resourcePath = "~/Library/Application Support/REAPER"  // where REAPER keeps reaper-screensets.ini
    var kompleteKontrol = KKViewConfig()
    var buttons: [String: String?] = [
        "Play": "play", "Stop": "stop", "Rec": "record", "Loop": "repeat", "Rewind": "rewind", "FastForward": "forward",
        "NavUp": "next-track", "NavDown": "previous-track",  // the buttons under the big knob: track number up / down
        "PageLeft": "previous-page", "PageRight": "next-page", "Instance": "toggle-view", "Back": "undo",
        "Browse": "browse-fx", "NavigateClick": "panic", "Enter": "save-project",
        "Scale": "screenset:1", "Arp": "screenset:2",
    ]
    /// Commands for buttons pressed while Shift is held; other Shift + button presses send their CC on the Shift channel.
    var shiftButtons: [String: String?] = [
        "Rec": "metronome", "Stop": "go-to-start", "Rewind": "previous-marker", "FastForward": "next-marker",
        "Loop": "record-mode", "Back": "redo", "Browse": "close-fx", "Enter": "render-project",
    ]

    enum CodingKeys: String, CodingKey {
        case enabled, host, sendPort, receivePort, view, followSelectedTrack, knobFullRange, navigateTurn, buttons
        case shiftButtons, trackNameSeconds, mirrorSelection, resourcePath, kompleteKontrol
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? host
        sendPort = try c.decodeIfPresent(Int.self, forKey: .sendPort) ?? sendPort
        receivePort = try c.decodeIfPresent(Int.self, forKey: .receivePort) ?? receivePort
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? view
        followSelectedTrack = try c.decodeIfPresent(Bool.self, forKey: .followSelectedTrack) ?? followSelectedTrack
        knobFullRange = try c.decodeIfPresent(Int.self, forKey: .knobFullRange) ?? knobFullRange
        if c.contains(.navigateTurn) { navigateTurn = try c.decodeIfPresent(String.self, forKey: .navigateTurn) }
        trackNameSeconds = try c.decodeIfPresent(Double.self, forKey: .trackNameSeconds) ?? trackNameSeconds
        mirrorSelection = try c.decodeIfPresent(Bool.self, forKey: .mirrorSelection) ?? mirrorSelection
        resourcePath = try c.decodeIfPresent(String.self, forKey: .resourcePath) ?? resourcePath
        kompleteKontrol = try c.decodeIfPresent(KKViewConfig.self, forKey: .kompleteKontrol) ?? kompleteKontrol
        func merge(_ key: CodingKeys, into map: inout [String: String?]) throws {
            guard let user = try c.decodeIfPresent([String: String?].self, forKey: key) else { return }
            for (name, command) in user {
                guard name != "Shift", buttonDefs.contains(where: { $0.name == name }) else {
                    throw ConfigError(description: "reaper.\(key.stringValue): unknown button \"\(name)\". Valid names: "
                        + buttonDefs.map(\.name).filter { $0 != "Shift" }.joined(separator: ", "))
                }
                map.updateValue(command, forKey: name)
            }
        }
        try merge(.buttons, into: &buttons)
        try merge(.shiftButtons, into: &shiftButtons)
    }

    func validate() throws {
        for (v, what) in [(sendPort, "reaper.sendPort"), (receivePort, "reaper.receivePort")] {
            guard (1...65535).contains(v) else { throw ConfigError(description: "\(what) must be 1-65535, got \(v)") }
        }
        guard sendPort != receivePort else { throw ConfigError(description: "reaper.sendPort and reaper.receivePort must differ") }
        try kompleteKontrol.validate()
        guard ReaperView.allCases.contains(where: { $0.configName == view }) else {
            throw ConfigError(description: "reaper.view must be \"mix\", \"track\" or \"komplete-kontrol\", got \"\(view)\"")
        }
        guard knobFullRange >= 10 else { throw ConfigError(description: "reaper.knobFullRange must be at least 10") }
        guard (0...30).contains(trackNameSeconds) else {
            throw ConfigError(description: "reaper.trackNameSeconds must be 0-30, got \(trackNameSeconds)")
        }
        if let n = navigateTurn, !navigateTurnTargets.contains(n) {
            throw ConfigError(description: "reaper.navigateTurn must be one of \(navigateTurnTargets.joined(separator: ", ")) or null, got \"\(n)\"")
        }
        for (key, map) in [("buttons", buttons), ("shiftButtons", shiftButtons)] {
            for (name, command) in map {
                if let command, ReaperCommand(command) == nil {
                    throw ConfigError(description: "reaper.\(key).\(name): unknown command \"\(command)\". Valid: \(ReaperCommand.validNames)")
                }
            }
        }
    }
}

struct Config: Codable {
    var portName = "Primo Komplete Kontrol MK1"
    var channel = 1
    var shiftChannel: Int? = 2
    var buttons: [String: Int?] = Dictionary(uniqueKeysWithValues: buttonDefs.map { ($0.name, Optional($0.cc)) })
    var knobCCs = Array(14...21)
    var knobMode = TurnMode.absolute
    var knobStepsPerCC = 4
    var knobTouchCCs = Array(22...29)
    var navigateTurnCC: Int? = 30
    var navigateTurnMode = TurnMode.relativeBinaryOffset
    var navigateTouchCC: Int? = 31
    var lights = true
    var lightBrightness = 127
    var lightIdleBrightness = 6
    var displays = true
    var keyboardSource: String? = "auto"  // merged into the virtual port: "auto" (the keyboard's Port 1), a name, or null
    var reaper = ReaperConfig()

    enum CodingKeys: String, CodingKey {
        case portName, channel, shiftChannel, buttons, knobCCs, knobMode, knobStepsPerCC, knobTouchCCs
        case navigateTurnCC, navigateTurnMode, navigateTouchCC, lights, lightBrightness, lightIdleBrightness
        case displays, reaper, keyboardSource
    }

    init() {}

    /// Every key is optional; missing keys keep their defaults, and an explicit null disables an optional control.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func nullable(_ k: CodingKeys, _ current: Int?) throws -> Int? {
            if c.contains(k) { return try c.decodeIfPresent(Int.self, forKey: k) }
            return current
        }
        portName = try c.decodeIfPresent(String.self, forKey: .portName) ?? portName
        channel = try c.decodeIfPresent(Int.self, forKey: .channel) ?? channel
        shiftChannel = try nullable(.shiftChannel, shiftChannel)
        knobCCs = try c.decodeIfPresent([Int].self, forKey: .knobCCs) ?? knobCCs
        knobMode = try c.decodeIfPresent(TurnMode.self, forKey: .knobMode) ?? knobMode
        knobStepsPerCC = try c.decodeIfPresent(Int.self, forKey: .knobStepsPerCC) ?? knobStepsPerCC
        knobTouchCCs = try c.decodeIfPresent([Int].self, forKey: .knobTouchCCs) ?? knobTouchCCs
        navigateTurnCC = try nullable(.navigateTurnCC, navigateTurnCC)
        navigateTurnMode = try c.decodeIfPresent(TurnMode.self, forKey: .navigateTurnMode) ?? navigateTurnMode
        navigateTouchCC = try nullable(.navigateTouchCC, navigateTouchCC)
        lights = try c.decodeIfPresent(Bool.self, forKey: .lights) ?? lights
        lightBrightness = try c.decodeIfPresent(Int.self, forKey: .lightBrightness) ?? lightBrightness
        lightIdleBrightness = try c.decodeIfPresent(Int.self, forKey: .lightIdleBrightness) ?? lightIdleBrightness
        displays = try c.decodeIfPresent(Bool.self, forKey: .displays) ?? displays
        if c.contains(.keyboardSource) { keyboardSource = try c.decodeIfPresent(String.self, forKey: .keyboardSource) }
        reaper = try c.decodeIfPresent(ReaperConfig.self, forKey: .reaper) ?? reaper
        if let user = try c.decodeIfPresent([String: Int?].self, forKey: .buttons) {
            for (name, cc) in user {
                guard buttons[name] != nil else {
                    throw ConfigError(description: "unknown button \"\(name)\". Valid names: "
                        + buttonDefs.map(\.name).joined(separator: ", "))
                }
                buttons.updateValue(cc, forKey: name)
            }
        }
    }

    func validate() throws {
        func ch(_ v: Int, _ what: String) throws {
            guard (1...16).contains(v) else { throw ConfigError(description: "\(what) must be 1-16, got \(v)") }
        }
        func cc(_ v: Int, _ what: String) throws {
            guard (0...127).contains(v) else { throw ConfigError(description: "\(what) must be 0-127, got \(v)") }
        }
        try ch(channel, "channel")
        if let s = shiftChannel { try ch(s, "shiftChannel") }
        guard knobCCs.count == 8 else { throw ConfigError(description: "knobCCs needs exactly 8 entries") }
        guard knobTouchCCs.isEmpty || knobTouchCCs.count == 8 else {
            throw ConfigError(description: "knobTouchCCs needs 8 entries, or [] to turn knob touch off")
        }
        guard knobStepsPerCC >= 1 else { throw ConfigError(description: "knobStepsPerCC must be at least 1") }
        for (name, v) in buttons { if let v { try cc(v, "buttons.\(name)") } }
        for v in knobCCs { try cc(v, "knobCCs") }
        for v in knobTouchCCs { try cc(v, "knobTouchCCs") }
        if let v = navigateTurnCC { try cc(v, "navigateTurnCC") }
        if let v = navigateTouchCC { try cc(v, "navigateTouchCC") }
        for (v, what) in [(lightBrightness, "lightBrightness"), (lightIdleBrightness, "lightIdleBrightness")] {
            guard (0...255).contains(v) else { throw ConfigError(description: "\(what) must be 0-255, got \(v)") }
        }
        try reaper.validate()
    }

    func duplicateWarnings() -> [String] {
        var seen: [Int: String] = [:], warnings: [String] = []
        func add(_ v: Int?, _ what: String) {
            guard let v else { return }
            if let other = seen[v] { warnings.append("CC\(v) is used by both \(other) and \(what)") } else { seen[v] = what }
        }
        for d in buttonDefs { add(buttons[d.name] ?? nil, d.name) }
        for (i, v) in knobCCs.enumerated() { add(v, "knob \(i + 1)") }
        for (i, v) in knobTouchCCs.enumerated() { add(v, "knob \(i + 1) touch") }
        add(navigateTurnCC, "Navigate turn")
        add(navigateTouchCC, "Navigate touch")
        return warnings
    }
}

// MARK: - MIDI ports (virtual source out, virtual destination for DAW feedback)

func stableUniqueID(_ s: String) -> MIDIUniqueID {
    var h: UInt32 = 2_166_136_261  // FNV-1a, so DAWs see the same port ID on every launch
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return MIDIUniqueID(bitPattern: h)
}

/// Control changes in a raw MIDI 1.0 byte stream (running status aware); everything else is skipped.
func controlChanges(in bytes: [UInt8]) -> [(channel: Int, cc: Int, value: Int)] {
    var out: [(channel: Int, cc: Int, value: Int)] = []
    var status: UInt8 = 0
    var i = 0
    while i < bytes.count {
        let x = bytes[i]
        if x >= 0xF8 { i += 1; continue }  // realtime
        if x == 0xF0 {                     // SysEx
            while i < bytes.count && bytes[i] != 0xF7 { i += 1 }
            i += 1
            status = 0
            continue
        }
        if x >= 0x80 { status = x < 0xF0 ? x : 0; i += 1; continue }
        guard status != 0 else { i += 1; continue }
        let n = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
        guard i + n <= bytes.count else { break }
        if status & 0xF0 == 0xB0 { out.append((Int(status & 0x0F) + 1, Int(bytes[i]), Int(bytes[i + 1]))) }
        i += n
    }
    return out
}

func midiName(_ e: MIDIEndpointRef) -> String {
    var cf: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &cf)
    return (cf?.takeRetainedValue() as String?) ?? ""
}

final class MIDIPorts {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let dryRun: Bool
    /// Called on the main queue for every control change the DAW sends to the destination.
    var onControlChange: ((Int, Int, Int) -> Void)?
    private(set) var feedbackAvailable = false

    /// Keyboard merge: everything the keyboard's own MIDI port sends (keys, pitch and mod strips, pedals) is
    /// passed on to the virtual source too, so one DAW input carries both the keys and the bridge's CCs.
    private let keysSource: String?  // "auto" (the keyboard's Port 1), a source name, or nil for no merge
    private var keysPort = MIDIPortRef()
    private var keysConnected: [MIDIEndpointRef] = []
    /// Called on the main queue with the names of the merged sources whenever they change.
    var onKeysChanged: (([String]) -> Void)?

    init(name: String, dryRun: Bool, keysSource: String? = nil) {
        self.dryRun = dryRun
        self.keysSource = keysSource
        guard !dryRun else { return }
        var st = MIDIClientCreateWithBlock("PrimoKKMK1Bridge" as CFString, &client) { [weak self] note in
            // A device came or went (e.g. the keyboard was replugged): reconnect the merge.
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.connectKeys() }
        }
        guard st == noErr else { fail("MIDIClientCreate failed (\(st))") }
        st = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard st == noErr else { fail("could not create the virtual MIDI port \"\(name)\" (\(st))") }
        MIDIObjectSetIntegerProperty(source, kMIDIPropertyUniqueID, stableUniqueID(name))

        if keysSource != nil {
            st = MIDIInputPortCreateWithProtocol(client, "keyboard in" as CFString, ._1_0, &keysPort) { [weak self] list, _ in
                guard let self else { return }
                MIDIReceivedEventList(self.source, list)  // pass the keyboard's events straight on
            }
            if st != noErr { print("warning: could not create the keyboard merge port (\(st)); keys stay on the keyboard's own port") }
        }

        let listHeader = MemoryLayout<MIDIPacketList>.offset(of: \MIDIPacketList.packet) ?? 4
        let lengthOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.length) ?? 8
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data) ?? 10
        st = MIDIDestinationCreateWithBlock(client, name as CFString, &destination) { [weak self] list, _ in
            var found: [(channel: Int, cc: Int, value: Int)] = []
            var pkt = UnsafeRawPointer(list) + listHeader
            for _ in 0..<list.pointee.numPackets {
                let len = Int(pkt.loadUnaligned(fromByteOffset: lengthOffset, as: UInt16.self))
                found += controlChanges(in: Array(UnsafeRawBufferPointer(start: pkt + dataOffset, count: len)))
                pkt = UnsafeRawPointer(MIDIPacketNext(pkt.assumingMemoryBound(to: MIDIPacket.self)))
            }
            guard !found.isEmpty else { return }
            DispatchQueue.main.async { for m in found { self?.onControlChange?(m.channel, m.cc, m.value) } }
        }
        if st == noErr {
            MIDIObjectSetIntegerProperty(destination, kMIDIPropertyUniqueID, stableUniqueID(name + " feedback"))
            feedbackAvailable = true
        } else {
            print("warning: could not create the feedback port (\(st)); lights will only follow button presses")
        }
    }

    /// (Re)connect the keyboard's MIDI source(s) to the merge, if the matching sources changed.
    func connectKeys(report: Bool = false) {
        guard let want = keysSource, keysPort != 0 else { return }
        var matches: [MIDIEndpointRef] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            guard src != source else { continue }  // never our own port
            let n = midiName(src)
            let hit = want == "auto" ? n.uppercased().hasPrefix("KOMPLETE KONTROL S") && n.hasSuffix("Port 1") : n == want
            if hit { matches.append(src) }
        }
        guard matches != keysConnected || report else { return }
        for e in keysConnected { MIDIPortDisconnectSource(keysPort, e) }
        keysConnected = matches.filter { MIDIPortConnectSource(keysPort, $0, nil) == noErr }
        onKeysChanged?(keysConnected.map(midiName))
    }

    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8) {
        guard !dryRun else { return }
        var word = UInt32(0x2000_0000) | UInt32(status) << 16 | UInt32(d1) << 8 | UInt32(d2)  // UMP MIDI 1.0 voice
        var list = MIDIEventList()
        withUnsafeMutablePointer(to: &list) { lp in
            let pkt = MIDIEventListInit(lp, ._1_0)
            _ = MIDIEventListAdd(lp, MemoryLayout<MIDIEventList>.size, pkt, 0, 1, &word)
            MIDIReceivedEventList(source, lp)
        }
    }
}

// MARK: - Bridge

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

final class Bridge {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    let cfg: Config
    let midi: MIDIPorts
    let verbose: Bool
    var clock: () -> String = { Bridge.timeFormatter.string(from: Date()) }

    var device: IOHIDDevice?
    var prev: [UInt8]?
    var pressChannel: [Int: Int] = [:]  // button bit -> channel its press went out on
    var knobAccum = [Int](repeating: 0, count: 8)
    var absValues: [Int: Int] = [:]     // channel * 128 + cc -> current absolute value
    var lastInit = Date.distantPast
    var rootPowerPort: io_connect_t = 0

    let buttonByCC: [Int: Int]          // cc -> button bit, for DAW feedback
    var held = Set<Int>()               // button bits currently down
    var lightState: [Int: Int] = [:]    // channel * 32 + bit -> last value the DAW sent
    var lightsSent: [UInt8]?
    var lightFlushPending = false

    let displays = Displays()
    var displaySent: [[UInt8]?] = [nil, nil, nil]
    var displayFlushPending = false
    var lastDisplayFlush = Date.distantPast
    var displayFailed = false
    var forcedRefreshPending = false
    var overlay: TrackOverlay?
    var message: (label: String, top: String, bottom: String, extra: String, until: Date)?  // a short notice
    var loggedTrack = ""
    var immediate = false               // replay: draw at once instead of on the run loop
    var onDisplayFrame: (([String]) -> Void)?

    var reaper: ReaperSession?
    var logOSC = false                        // --log-osc: print what REAPER sends
    let reaperCommands: [Int: ReaperCommand]       // button bit -> REAPER command (REAPER mode, without Shift)
    let reaperShiftCommands: [Int: ReaperCommand]  // button bit -> REAPER command while Shift is held
    let kkButtonCCs: [Int: Int]                    // button bit -> CC in the Komplete Kontrol view
    var pressCC: [Int: Int] = [:]                  // button bit -> CC its press sent, when not its usual one
    var kkKnobSent = [Date](repeating: .distantPast, count: 8)  // when each knob last sent its KK CC
    var kkMemory: [String: [Int]] = [:]  // "track/page" -> the 8 knob values left there (Komplete Kontrol view)
    var reaperHeld: [Int: ReaperCommand] = [:]     // buttons whose press went to REAPER, and the command it ran

    init(cfg: Config, midi: MIDIPorts, verbose: Bool) {
        self.cfg = cfg
        self.midi = midi
        self.verbose = verbose
        var byCC: [Int: Int] = [:]
        for d in buttonDefs { if let cc = cfg.buttons[d.name] ?? nil { byCC[cc] = d.bit } }
        buttonByCC = byCC
        func commands(_ map: [String: String?]) -> [Int: ReaperCommand] {
            guard cfg.reaper.enabled else { return [:] }
            var out: [Int: ReaperCommand] = [:]
            for d in buttonDefs { if let s = map[d.name] ?? nil, let c = ReaperCommand(s) { out[d.bit] = c } }
            return out
        }
        reaperCommands = commands(cfg.reaper.buttons)
        reaperShiftCommands = commands(cfg.reaper.shiftButtons)
        var kkCCs: [Int: Int] = [:]
        if cfg.reaper.enabled {
            for d in buttonDefs { if let cc = cfg.reaper.kompleteKontrol.buttons[d.name] ?? nil { kkCCs[d.bit] = cc } }
        }
        kkButtonCCs = kkCCs
    }

    func log(_ s: String) { print("\(clock()) \(s)") }

    func sendCC(_ channel: Int, _ cc: Int, _ value: Int, _ what: String) {
        midi.send(0xB0 | UInt8(channel - 1), UInt8(cc), UInt8(value))
        if verbose { log(what.padding(toLength: 24, withPad: " ", startingAt: 0) + "CC\(cc) ch\(channel) = \(value)") }
    }

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

    // MARK: device lifecycle

    func attached(_ dev: IOHIDDevice) {
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
        device = dev
        prev = nil
        pressChannel = [:]
        pressCC = [:]
        reaperHeld = [:]
        held = []
        lightsSent = nil
        displaySent = [nil, nil, nil]
        displayFailed = false
        knobAccum = Array(repeating: 0, count: 8)
        log("connected: Komplete Kontrol \(mk1Models[pid] ?? String(format: "0x%04x", pid))")
        lastInit = .distantPast
        sendInit(reason: "connect")
    }

    func removed(_ dev: IOHIDDevice) {
        guard let d = device, CFEqual(d, dev) else { return }
        releaseHeld()
        device = nil
        prev = nil
        held = []
        lightsSent = nil
        displaySent = [nil, nil, nil]
        log("disconnected; waiting for the keyboard")
    }

    /// Switch the keyboard to native mode. Rate-limited so a burst of MIDI-mode reports sends it once.
    func sendInit(reason: String) {
        guard let dev = device, Date().timeIntervalSince(lastInit) > 2 else { return }
        lastInit = Date()
        var report: [UInt8] = [reportInit, 0x00, 0x00]  // report ID first, as IOHIDDeviceSetReport expects
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportInit), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("init report failed: 0x\(String(st, radix: 16)) (\(reason))")
            return
        }
        log("native mode on (\(reason))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            sendLights(force: true)
            renderDisplays()
            flushDisplays(force: true)
        }
    }

    /// Send "off" for anything still held, so the DAW never sees a stuck button or touch.
    func releaseHeld() {
        for (_, c) in reaperHeld { reaper?.perform(c, down: false) }
        reaperHeld = [:]
        for (bit, ch) in pressChannel {
            if let def = buttonDefs.first(where: { $0.bit == bit }), let cc = pressCC[bit] ?? cfg.buttons[def.name] ?? nil {
                sendCC(ch, cc, 0, "\(def.name) up (released)")
            }
        }
        pressChannel = [:]
        pressCC = [:]
        guard let p = prev else { return }
        if let r = reaper {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) { r.touch(k, false) }
            return
        }
        if cfg.knobTouchCCs.count == 8 {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) {
                sendCC(cfg.channel, cfg.knobTouchCCs[k], 0, "Knob \(k + 1) untouch (released)")
            }
        }
        if let cc = cfg.navigateTouchCC, isSet(p, navigateTouchBit) { sendCC(cfg.channel, cc, 0, "Navigate untouch (released)") }
    }

    // MARK: button lights

    func lightLevel(_ def: ButtonDef, shiftHeld: Bool) -> UInt8 {
        // The button lights are single-colour, so Instance shows the view by brightness: mix off, track
        // half-way, Komplete Kontrol full.
        if let r = reaper, !shiftHeld, reaperCommands[def.bit] == .toggleView {
            switch r.view {
            case .mix: return 0
            case .track: return UInt8(cfg.lightBrightness / 4)
            case .kk: return UInt8(cfg.lightBrightness)
            }
        }
        if let r = reaper, !shiftHeld, r.view == .kk, kkButtonCCs[def.bit] != nil {
            return UInt8(held.contains(def.bit) ? cfg.lightBrightness : cfg.lightIdleBrightness)
        }
        if let r = reaper, let command = (shiftHeld ? reaperShiftCommands : reaperCommands)[def.bit] {
            return UInt8(held.contains(def.bit) || r.isActive(command) ? cfg.lightBrightness : cfg.lightIdleBrightness)
        }
        guard (cfg.buttons[def.name] ?? nil) != nil else { return 0 }  // unmapped buttons stay dark
        if held.contains(def.bit) { return UInt8(cfg.lightBrightness) }
        var state = lightState[cfg.channel * 32 + def.bit]
        if shiftHeld, let sc = cfg.shiftChannel, let s = lightState[sc * 32 + def.bit] { state = s }
        return UInt8((state ?? 0) > 0 ? cfg.lightBrightness : cfg.lightIdleBrightness)
    }

    /// Coalesce light changes from one run-loop pass into a single report.
    func scheduleLights() {
        guard cfg.lights, device != nil, !lightFlushPending else { return }
        lightFlushPending = true
        DispatchQueue.main.async { [self] in
            lightFlushPending = false
            sendLights()
        }
    }

    func sendLights(force: Bool = false, allOff: Bool = false) {
        guard cfg.lights, let dev = device else { return }
        let shiftHeld = prev.map { isSet($0, shiftBit) } ?? false
        var report = [UInt8](repeating: 0, count: 1 + lightCount)
        report[0] = reportLights
        if !allOff {
            for def in buttonDefs { if let slot = lightSlot[def.name] { report[1 + slot] = lightLevel(def, shiftHeld: shiftHeld) } }
        }
        guard force || report != lightsSent else { return }
        let st = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(reportLights), &report, report.count)
        guard st == kIOReturnSuccess else {
            log("light report failed: 0x\(String(st, radix: 16))")
            return
        }
        if verbose, let old = lightsSent {
            let changes = buttonDefs.compactMap { d -> String? in
                guard let s = lightSlot[d.name], old[1 + s] != report[1 + s] else { return nil }
                return "\(d.name) \(report[1 + s])"
            }
            if !changes.isEmpty { log("lights: " + changes.joined(separator: ", ")) }
        }
        lightsSent = report
    }

    /// A control change the DAW sent back to the feedback port.
    func feedback(channel: Int, cc: Int, value: Int) {
        guard channel == cfg.channel || channel == cfg.shiftChannel else { return }
        if cfg.knobMode == .absolute, cfg.knobCCs.contains(cc) { absValues[channel * 128 + cc] = value; scheduleDisplays() }
        if cfg.navigateTurnMode == .absolute, cfg.navigateTurnCC == cc { absValues[channel * 128 + cc] = value }
        guard let bit = buttonByCC[cc] else { return }
        lightState[channel * 32 + bit] = value
        if verbose { log("feedback CC\(cc) ch\(channel) = \(value)") }
        scheduleLights()
    }

    // MARK: displays

    /// A notice across the displays: label on the left, then `top` across the rest, or with `extra`, `top` on
    /// the second display only and `extra` from the third on.
    func showMessage(_ label: String, _ top: String, _ bottom: String = "", extra: String = "", seconds: Double = 1.5) {
        message = (label, top, bottom, extra, Date().addingTimeInterval(seconds))
        scheduleDisplays()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.02) { [weak self] in self?.scheduleDisplays() }
    }

    /// Komplete Kontrol view, per-page memory: where each knob was left on each page of each track, so going
    /// back to a page carries on from there instead of jumping (KK's own parameter values aren't available).
    func kkKey(_ r: ReaperSession) -> String { "\(r.track.number)/\(r.kkPage)" }

    /// Load the remembered knob values of the current track and page (64, the middle, where there are none).
    func kkLoadPage(_ r: ReaperSession) {
        let kk = cfg.reaper.kompleteKontrol
        guard r.view == .kk, kk.encoderMode == .absolute, !kk.hostParameters else { return }
        let values = kkMemory[kkKey(r)] ?? Array(repeating: 64, count: 8)
        for k in 0..<8 { absValues[kk.channel * 128 + kk.encoderCCs[k]] = values[k] }
    }

    func kkChangePage(_ r: ReaperSession, by step: Int) {
        if cfg.reaper.kompleteKontrol.hostParameters {
            r.kkPage = max(0, min(r.nksPages - 1, r.kkPage + step))
            syncKKKnobs()
        } else {
            r.kkPage = max(0, r.kkPage + step)  // KK's page count isn't known here, so there's no upper limit
            kkLoadPage(r)
        }
        if verbose { log("KK page \(r.kkPage + 1)") }
    }

    func kkForgetTrack(_ r: ReaperSession) {
        let prefix = "\(r.track.number)/"
        kkMemory = kkMemory.filter { !$0.key.hasPrefix(prefix) }
        r.kkPage = 0
        kkLoadPage(r)
        if verbose { log("KK preset change: page 1, knob values reset") }
    }

    /// Komplete Kontrol view, absolute knobs: start each knob's CC from its NKS parameter's current value, so
    /// turning it after a page change carries on from there instead of jumping. Not for a knob that's turning.
    func syncKKKnobs() {
        let kk = cfg.reaper.kompleteKontrol
        guard let r = reaper, r.view == .kk, kk.encoderMode == .absolute, kk.hostParameters else { return }
        let nks = r.nks, page = r.kkPage
        for k in 0..<8 {
            guard let v = nks[page * 8 + k]?.value, Date().timeIntervalSince(kkKnobSent[k]) > 0.3 else { continue }
            absValues[kk.channel * 128 + kk.encoderCCs[k]] = Int((v * 127).rounded())
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
        if let r = reaper { renderReaper(r, touched) } else { renderMIDI(touched) }
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
        func info(_ t: KnobTarget) -> KnobInfo { shiftHeld && t == .recArm ? r.monitorInfo : r.info(t) }
        for k in 0..<8 {
            guard let t = targets[k] else { displays.setBar(cell: k + 1, nil, framed: false); continue }
            let i = info(t)
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
        case .kk where !cfg.reaper.kompleteKontrol.hostParameters || r.nks.isEmpty:
            // The CC each knob sends, its value and a bar (absolute), or REL; the page KK should be on.
            let kk = cfg.reaper.kompleteKontrol
            displays.write(row: 0, cell: 0, "KOMPLETE")
            displays.write(row: 1, cell: 0, kk.pageButtons.isEmpty ? "KONTROL" : "PAGE \(r.kkPage + 1)")
            for k in 0..<8 {
                let cc = kk.encoderCCs[k]
                displays.write(row: 0, cell: k + 1, "CC \(cc)")
                if kk.encoderMode == .absolute {
                    let v = absValues[kk.channel * 128 + cc] ?? 64
                    displays.write(row: 1, cell: k + 1, "\(v)")
                    displays.setBar(cell: k + 1, Double(v) / 127, framed: touched.contains(k))
                } else {
                    displays.write(row: 1, cell: k + 1, "REL")
                    displays.setBar(cell: k + 1, nil, framed: touched.contains(k))
                }
            }
            return
        case .kk:  // experimental (hostParameters): the KK plugin's host parameters, 8 per page
            displays.write(row: 0, cell: 0, "KOMPLETE")
            guard r.kkFX != nil else {
                displays.write(row: 1, cell: 0, "KONTROL")
                displays.write(row: 0, cell: 1, "no Komplete Kontrol plugin on this track", span: 8)
                return
            }
            let nks = r.nks, page = r.kkPage
            displays.write(row: 1, cell: 0, nks.isEmpty ? "KONTROL" : "PAGE \(page + 1)/\(r.nksPages)")
            for k in 0..<8 {
                guard let p = nks[page * 8 + k] else { displays.setBar(cell: k + 1, nil, framed: touched.contains(k)); continue }
                let value = p.text.isEmpty ? p.value.map { "\(Int(($0 * 100).rounded()))%" } ?? "" : p.text
                displays.write(row: 0, cell: k + 1, abbreviate(p.name, cellWidth))
                displays.write(row: 1, cell: k + 1, fitValue(value, cellWidth))
                displays.setBar(cell: k + 1, p.value, framed: touched.contains(k))
            }
            return
        case .mix:
            let numbers = r.bank.filter(\.exists).map(\.number)
            displays.write(row: 0, cell: 0, "MIX")
            displays.write(row: 1, cell: 0, numbers.isEmpty ? "NO TRKS" : "\(numbers.first!)-\(numbers.last!)")
        case .track:
            displays.write(row: 0, cell: 0, abbreviate(r.track.exists ? r.track.label : "NO TRACK", cellWidth))
            displays.write(row: 1, cell: 0, r.sendPage == 0 ? "TRK \(r.track.number)" : "PAGE \(r.sendPage + 1)/\(r.sendPages)")
        }
        for k in 0..<8 {
            guard let t = targets[k] else { continue }
            let i = info(t)
            displays.write(row: 0, cell: k + 1, abbreviate(i.short, cellWidth))
            displays.write(row: 1, cell: k + 1, fitValue(i.value, cellWidth))
        }
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
            kkLoadPage(r)
        case .view:
            if verbose { log("REAPER \(r.view.configName) view") }
            syncKKKnobs()
            kkLoadPage(r)
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
        case .kkParam(let n):
            guard r.view == .kk, let p = r.devParams[n], let slot = ReaperSession.nksSlot(p.name) else { break }
            // A knob just turned and the parameter that moved is on another page: KK is showing that page.
            let k = slot % 8
            if Date().timeIntervalSince(kkKnobSent[k]) < 0.5, slot / 8 != r.kkPage {
                r.kkPage = slot / 8
                if verbose { log("KK page \(r.kkPage + 1)/\(r.nksPages) (knob \(k + 1) moved \"\(p.name)\")") }
            }
            syncKKKnobs()
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

    // MARK: reports

    func handleReport(_ id: UInt8, _ bytes: [UInt8]) {
        switch id {
        case reportUI where bytes.count >= 38:
            handleUI(bytes)
        case reportPage:
            log("keyboard is in MIDI mode (page report)")
            sendInit(reason: "recovered from MIDI mode")
        default:
            break
        }
    }

    func handleUI(_ b: [UInt8]) {
        var p = prev ?? b
        if prev == nil { for i in 1...5 { p[i] = 0 } }  // first report: buttons start up, positions start where they are
        prev = b
        let shiftHeld = isSet(b, shiftBit)
        let layer = (shiftHeld ? cfg.shiftChannel : nil) ?? cfg.channel
        let toReaper = reaper != nil && !shiftHeld  // without Shift the controls drive REAPER

        for def in buttonDefs {
            let was = isSet(p, def.bit), now = isSet(b, def.bit)
            guard was != now else { continue }
            if def.bit == shiftBit {
                if let cc = cfg.buttons[def.name] ?? nil { sendCC(cfg.channel, cc, now ? 127 : 0, "\(def.name) \(now ? "down" : "up")") }
            } else if now {
                if let r = reaper, !shiftHeld, r.view == .kk, let cc = kkButtonCCs[def.bit] {
                    let ch = cfg.reaper.kompleteKontrol.channel
                    pressChannel[def.bit] = ch
                    pressCC[def.bit] = cc
                    sendCC(ch, cc, 127, "\(def.name) down (KK)")
                    let kk = cfg.reaper.kompleteKontrol
                    if let i = kk.pageButtons.firstIndex(of: def.name) {  // KK changes its NKS page: follow it
                        kkChangePage(r, by: i == 0 ? -1 : 1)
                    } else if kk.presetButtons.contains(def.name) {   // a new preset: start over on page 1
                        kkForgetTrack(r)
                    }
                } else if let r = reaper, let command = (shiftHeld ? reaperShiftCommands : reaperCommands)[def.bit] {
                    reaperHeld[def.bit] = command
                    if verbose { log("\(shiftHeld ? "Shift + " : "")\(def.name) down") }
                    if command == .previousPage || command == .nextPage { overlay = nil }  // show the new page at once
                    r.perform(command, down: true)
                } else if let cc = cfg.buttons[def.name] ?? nil {
                    pressChannel[def.bit] = layer
                    sendCC(layer, cc, 127, "\(def.name) down")
                }
            } else if let command = reaperHeld.removeValue(forKey: def.bit) {
                reaper?.perform(command, down: false)
            } else if let cc = pressCC.removeValue(forKey: def.bit) {
                sendCC(pressChannel.removeValue(forKey: def.bit) ?? cfg.channel, cc, 0, "\(def.name) up (KK)")
            } else if let cc = cfg.buttons[def.name] ?? nil {
                sendCC(pressChannel.removeValue(forKey: def.bit) ?? cfg.channel, cc, 0, "\(def.name) up")
            }
        }
        let nowHeld = Set(buttonDefs.map(\.bit).filter { isSet(b, $0) })
        if nowHeld != held {
            held = nowHeld
            scheduleLights()
            refreshDisplaysSoon()
        }

        // Knob and Navigate touch: CCs in plain mode. In REAPER mode a knob touch shows the full name and
        // value, and tells REAPER the fader is touched (for touch automation).
        if let r = reaper {
            for k in 0..<8 where isSet(p, knobTouchFirstBit + k) != isSet(b, knobTouchFirstBit + k) {
                let now = isSet(b, knobTouchFirstBit + k)
                if now { overlay = nil }  // touching a knob ends the track name display
                r.touch(k, now)
            }
        } else {
            if cfg.knobTouchCCs.count == 8 {
                for k in 0..<8 {
                    let bit = knobTouchFirstBit + k
                    let was = isSet(p, bit), now = isSet(b, bit)
                    if was != now { sendCC(cfg.channel, cfg.knobTouchCCs[k], now ? 127 : 0, "Knob \(k + 1) \(now ? "touch" : "untouch")") }
                }
            }
            if let cc = cfg.navigateTouchCC, isSet(p, navigateTouchBit) != isSet(b, navigateTouchBit) {
                let now = isSet(b, navigateTouchBit)
                sendCC(cfg.channel, cc, now ? 127 : 0, "Navigate \(now ? "touch" : "untouch")")
            }
        }

        let a = Int(p[6] & 0x0f), c = Int(b[6] & 0x0f)
        if a != c {
            var d = c - a
            if d > 8 { d -= 16 } else if d < -8 { d += 16 }
            if toReaper, let r = reaper, let target = cfg.reaper.navigateTurn {
                if verbose { log("Navigate turn \(d > 0 ? "+" : "")\(d)") }
                if target == "pages" { overlay = nil }
                r.navigate(target, steps: d)
            } else if let cc = cfg.navigateTurnCC {
                turn(channel: layer, cc: cc, steps: d, mode: cfg.navigateTurnMode, what: "Navigate turn")
            }
        }

        for k in 0..<8 {
            let o = 7 + 2 * k
            let a = Int(p[o]) | Int(p[o + 1]) << 8, c = Int(b[o]) | Int(b[o + 1]) << 8
            guard a != c else { continue }
            var d = c - a
            if d > 500 { d -= 1000 } else if d < -500 { d += 1000 }  // positions wrap at 0-999
            if let r = reaper, shiftHeld {  // Shift + pan or volume knob: back to centre / 0 dB
                switch r.target(k) {
                case .pan?:
                    if r.centerPan(), verbose { log("Shift + pan knob: pan centred") }
                    continue
                case .volume?, .bankVolume?:
                    if r.resetVolume(k), verbose { log("Shift + volume knob \(k + 1): 0 dB") }
                    continue
                case .recArm?:
                    r.turnMonitor(k, raw: d)
                    continue
                default:
                    break
                }
            }
            if toReaper, let r = reaper, r.view == .kk {  // Komplete Kontrol view: the knob's CC
                let kk = cfg.reaper.kompleteKontrol
                knobAccum[k] += d
                let steps = knobAccum[k] / cfg.knobStepsPerCC
                guard steps != 0 else { continue }
                knobAccum[k] -= steps * cfg.knobStepsPerCC
                turn(channel: kk.channel, cc: kk.encoderCCs[k], steps: steps, mode: kk.encoderMode, what: "Knob \(k + 1) turn (KK)")
                kkKnobSent[k] = Date()
                if let v = absValues[kk.channel * 128 + kk.encoderCCs[k]] {  // remember it for this track and page
                    kkMemory[kkKey(r), default: Array(repeating: 64, count: 8)][k] = v
                }
                continue
            }
            if toReaper, let r = reaper {
                r.turn(k, raw: d)
                continue
            }
            knobAccum[k] += d
            let steps = knobAccum[k] / cfg.knobStepsPerCC
            guard steps != 0 else { continue }
            knobAccum[k] -= steps * cfg.knobStepsPerCC
            turn(channel: layer, cc: cfg.knobCCs[k], steps: steps, mode: cfg.knobMode, what: "Knob \(k + 1) turn")
        }
        scheduleDisplays()
    }

    func turn(channel: Int, cc: Int, steps: Int, mode: TurnMode, what: String) {
        let s = max(-63, min(63, steps))
        let value: Int
        switch mode {
        case .absolute:
            let key = channel * 128 + cc
            let old = absValues[key] ?? 64
            let new = max(0, min(127, old + steps))
            guard new != old else { return }
            absValues[key] = new
            value = new
        case .relativeBinaryOffset: value = 64 + s
        case .relativeTwosComplement: value = s >= 0 ? s : 128 + s
        case .relativeSignedBit: value = s >= 0 ? s : 64 - s
        }
        sendCC(channel, cc, value, "\(what) \(steps > 0 ? "+" : "")\(steps)")
    }
}

// MARK: - Main

let usage = """
    usage: PrimoKKMK1Bridge [--config FILE] [--verbose] [--log-osc]
           PrimoKKMK1Bridge --print-default-config
           PrimoKKMK1Bridge --replay CAPTURE_LOG [--config FILE] [--log-osc]
           PrimoKKMK1Bridge --show-font
    """

var args = Array(CommandLine.arguments.dropFirst())
func takeFlag(_ names: String...) -> Bool {
    guard let i = args.firstIndex(where: { names.contains($0) }) else { return false }
    args.remove(at: i)
    return true
}
func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

if takeFlag("-h", "--help") { print(usage); exit(0) }
let printDefault = takeFlag("--print-default-config")
let fontTest = takeFlag("--show-font")
let verbose = takeFlag("-v", "--verbose")
let logOSC = takeFlag("--log-osc")
let configPath = takeValue("--config")
let replayPath = takeValue("--replay")
guard args.isEmpty else { fail("unknown argument(s): \(args.joined(separator: " "))\n\(usage)") }

if fontTest { showFont(); exit(0) }

if printDefault {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! enc.encode(Config()), as: UTF8.self))
    exit(0)
}

var cfg = Config()
if let path = configPath {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    do { cfg = try JSONDecoder().decode(Config.self, from: data) } catch { fail("\(path): \(error)") }
}
do { try cfg.validate() } catch { fail("config: \(error)") }
for w in cfg.duplicateWarnings() { print("warning: \(w)") }

func ranges(_ v: [Int]) -> String {
    guard let f = v.first, let l = v.last else { return "off" }
    return v == Array(f...l) && v.count > 1 ? "CC\(f)-\(l)" : v.map { "CC\($0)" }.joined(separator: ",")
}

// Replay a capture log from tools/kkmap through the mapping, without a keyboard or MIDI port. With REAPER
// mode on, the OSC link is live (point it at tools/fake_reaper.py), and display frames are printed.
if let path = replayPath {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let bridge = Bridge(cfg: cfg, midi: MIDIPorts(name: cfg.portName, dryRun: true), verbose: true)
    var stamp = "start"
    bridge.clock = { stamp }
    bridge.immediate = true
    bridge.logOSC = logOSC
    bridge.onDisplayFrame = { lines in for l in lines { print("             display |" + l + "|") } }
    func spin(_ seconds: Double) { _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, false) }
    if cfg.reaper.enabled {
        bridge.startReaper()
        spin(0.5)
    }
    var count = 0
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ")
        guard f.count > 3, f[1] == "HID", f[2].hasPrefix("0x"), let id = UInt8(f[2].dropFirst(2), radix: 16) else { continue }
        stamp = String(f[0])
        bridge.handleReport(id, f[3...].compactMap { UInt8($0, radix: 16) })
        count += 1
        if bridge.reaper != nil { spin(0.01) }
    }
    if bridge.reaper != nil {
        stamp = "end"
        spin(0.5)
    }
    print("replayed \(count) HID reports from \(path)")
    exit(0)
}

let midi = MIDIPorts(name: cfg.portName, dryRun: false, keysSource: cfg.keyboardSource)
let bridge = Bridge(cfg: cfg, midi: midi, verbose: verbose)
bridge.logOSC = logOSC
midi.onControlChange = { bridge.feedback(channel: $0, cc: $1, value: $2) }
let ctx = Unmanaged.passUnretained(bridge).toOpaque()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatchingMultiple(manager, mk1Models.keys.sorted().map {
    [kIOHIDVendorIDKey: niVendorID, kIOHIDProductIDKey: $0, kIOHIDPrimaryUsagePageKey: 0xff01] as CFDictionary
} as CFArray)
IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue().attached(dev)
}, ctx)
IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
}, ctx)
IOHIDManagerRegisterInputReportCallback(manager, { ctx, result, _, _, rid, report, len in
    guard result == kIOReturnSuccess else { return }
    Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue()
        .handleReport(UInt8(truncatingIfNeeded: rid), Array(UnsafeBufferPointer(start: report, count: len)))
}, ctx)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openStatus != kIOReturnSuccess { bridge.log("HID manager open returned 0x\(String(openStatus, radix: 16))") }

// Re-send the init after sleep: the keyboard may come back from USB suspend in MIDI mode.
var powerNotifyPort: IONotificationPortRef?
var powerNotifier: io_object_t = 0
bridge.rootPowerPort = IORegisterForSystemPower(ctx, &powerNotifyPort, { ctx, _, messageType, messageArgument in
    let b = Unmanaged<Bridge>.fromOpaque(ctx!).takeUnretainedValue()
    switch messageType {
    case 0xE000_0270, 0xE000_0280:  // kIOMessageCanSystemSleep, kIOMessageSystemWillSleep
        IOAllowPowerChange(b.rootPowerPort, Int(bitPattern: messageArgument))
    case 0xE000_0300:  // kIOMessageSystemHasPoweredOn
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            b.lastInit = .distantPast
            b.sendInit(reason: "wake")
        }
    default:
        break
    }
}, &powerNotifier)
if bridge.rootPowerPort != 0, let port = powerNotifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler {
        bridge.releaseHeld()
        bridge.sendLights(force: true, allOff: true)
        bridge.blankDisplays()
        print("\nPrimoKKMK1Bridge stopped. The keyboard stays in native mode (knobs send no MIDI) until you replug it.")
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

print("PrimoKKMK1Bridge: Komplete Kontrol MK1 → virtual MIDI port \"\(cfg.portName)\"")
print("  buttons on ch\(cfg.channel)" + (cfg.shiftChannel.map { " (ch\($0) while Shift is held)" } ?? "")
      + ", knobs \(ranges(cfg.knobCCs)) \(cfg.knobMode.rawValue), knob touch \(ranges(cfg.knobTouchCCs))")
print("  Navigate turn \(cfg.navigateTurnCC.map { "CC\($0) \(cfg.navigateTurnMode.rawValue)" } ?? "off")"
      + ", Navigate touch \(cfg.navigateTouchCC.map { "CC\($0)" } ?? "off")")
if cfg.lights {
    print("  lights: idle \(cfg.lightIdleBrightness), lit \(cfg.lightBrightness)"
          + (midi.feedbackAvailable ? "; the DAW can light a button by sending its CC to the \"\(cfg.portName)\" output" : ""))
} else {
    print("  lights: off")
}
print("  displays: \(cfg.displays ? "on" : "off")")
if cfg.keyboardSource != nil {
    midi.onKeysChanged = { names in
        bridge.log(names.isEmpty ? "keys: no keyboard MIDI port found to merge yet"
                                 : "keys: merging \(names.map { "\"\($0)\"" }.joined(separator: ", ")) into \"\(cfg.portName)\"")
    }
    midi.connectKeys(report: true)
} else {
    print("  keys: not merged (keyboardSource is null); they stay on the keyboard's own MIDI port")
}
if cfg.reaper.enabled {
    let r = cfg.reaper
    print("  REAPER: OSC to \(r.host):\(r.sendPort), listening on port \(r.receivePort); starts in \(r.view) view"
          + " (Instance: mix -> track -> komplete-kontrol). Hold Shift for the MIDI CC layer.")
    bridge.startReaper()
}
print("  waiting for the keyboard… (Ctrl-C to quit)")
CFRunLoopRun()
