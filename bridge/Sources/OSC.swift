//
//  OSC.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  OSC messages over UDP: encoding, decoding and the link to REAPER.

import Foundation

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
