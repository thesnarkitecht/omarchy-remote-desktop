// Minimal RFB (VNC) client: lossless only (ZRLE / CopyRect / Raw), 24-bit true colour.
// We never advertise Tight/JPEG/H.264, so the server can't send lossy, chroma-subsampled frames.
import CZlib
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum RFBError: Error, CustomStringConvertible {
    case connect(String)
    case protocolError(String)
    case closed

    public var description: String {
        switch self {
        case .connect(let m): return "Could not connect: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .closed: return "Connection closed"
        }
    }
}

public final class RFBConnection {
    /// Framebuffer, one UInt32 per pixel: 0xFFRRGGBB (== BGRA bytes in memory, little endian).
    public private(set) var pixels: [UInt32] = []
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var name = ""
    /// Hold while reading `pixels`/`width`/`height` from another thread.
    public let lock = NSLock()

    /// Callbacks fire on the connection's reader thread.
    public var onFrame: (() -> Void)?
    public var onResize: (() -> Void)?
    public var onClipboard: ((String) -> Void)?
    public var onClose: ((Error) -> Void)?

    private let fd: Int32
    private let writeLock = NSLock()
    private var rbuf = [UInt8](repeating: 0, count: 1 << 16)
    private var rpos = 0, rlen = 0
    private var zs = z_stream()
    private var zReady = false
    private var zChunk = [UInt8](repeating: 0, count: 1 << 18)
    private var closedByUs = false

    public init(host: String, port: Int) throws {
        fd = try Self.connectTCP(host: host, port: port)
        do { try handshake() } catch { _ = shutdown(fd, Int32(SHUT_RDWR)); _ = sysClose(fd); throw error }
    }

    deinit { if zReady { inflateEnd(&zs) } }

    public func start() {
        Thread { [self] in
            var err: Error = RFBError.closed
            do { try loop() } catch { err = error }
            _ = sysClose(fd)
            if !closedByUs { onClose?(err) }
        }.start()
    }

    public func disconnect() {
        closedByUs = true
        _ = shutdown(fd, Int32(SHUT_RDWR))
    }

    // MARK: client -> server

    public func sendKey(_ keysym: UInt32, down: Bool) {
        transmit([4, down ? 1 : 0, 0, 0] + be32(keysym))
    }

    /// mask bits: 1 left, 2 middle, 4 right, 8/16 wheel up/down, 32/64 wheel left/right.
    public func sendPointer(x: Int, y: Int, mask: UInt8) {
        transmit([5, mask] + be16(UInt16(clamping: x)) + be16(UInt16(clamping: y)))
    }

    public func sendClipboard(_ text: String) {
        let bytes = [UInt8](text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data())
        transmit([6, 0, 0, 0] + be32(UInt32(bytes.count)) + bytes)
    }

    public func requestUpdate(incremental: Bool) {
        lock.lock(); let w = width, h = height; lock.unlock()
        transmit([3, incremental ? 1 : 0] + be16(0) + be16(0) + be16(UInt16(w)) + be16(UInt16(h)))
    }

    // MARK: handshake

    private func handshake() throws {
        let ver = String(decoding: try bytes(12), as: UTF8.self)
        guard ver.hasPrefix("RFB "), let minor = Int(ver.dropFirst(8).prefix(3)) else {
            throw RFBError.protocolError("not a VNC server (\(ver.debugDescription))")
        }
        let use = minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
        transmit(Array("RFB 003.00\(use)\n".utf8))

        if use >= 7 {
            let n = Int(try u8())
            if n == 0 { throw RFBError.protocolError(try reason()) }
            let types = try bytes(n)
            guard types.contains(1) else {
                throw RFBError.protocolError("server wants authentication (types \(types)); run wayvnc without auth on 127.0.0.1 and reach it over SSH")
            }
            transmit([1])
        } else {
            let t = try u32()
            if t == 0 { throw RFBError.protocolError(try reason()) }
            guard t == 1 else { throw RFBError.protocolError("server wants authentication") }
        }
        if use >= 8, try u32() != 0 { throw RFBError.protocolError(try reason()) }

        transmit([1]) // ClientInit: shared
        let w = Int(try u16()), h = Int(try u16())
        try skip(16) // server pixel format; we override it below
        name = String(decoding: try bytes(Int(try u32())), as: UTF8.self)
        resize(w, h)

        // 32bpp, depth 24, little endian, true colour, 8 bits per channel: R<<16 | G<<8 | B.
        transmit([0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        let encodings: [Int32] = [16 /* ZRLE */, 1 /* CopyRect */, 0 /* Raw */, -223 /* DesktopSize */]
        transmit([2, 0] + be16(UInt16(encodings.count)) + encodings.flatMap { be32(UInt32(bitPattern: $0)) })
        requestUpdate(incremental: false)
    }

    private func reason() throws -> String {
        String(decoding: try bytes(Int(try u32())), as: UTF8.self)
    }

    // MARK: server -> client

    private func loop() throws {
        while true {
            switch try u8() {
            case 0:
                let resized = try readUpdate()
                onFrame?()
                requestUpdate(incremental: !resized)
            case 1: // colour map: unused in true colour
                try skip(3)
                try skip(Int(try u16()) * 6)
            case 2: break // bell
            case 3:
                try skip(3)
                let data = try bytes(Int(try u32()))
                onClipboard?(String(data: Data(data), encoding: .isoLatin1) ?? "")
            case let t:
                throw RFBError.protocolError("unknown server message \(t)")
            }
        }
    }

    /// Returns true if the desktop was resized.
    private func readUpdate() throws -> Bool {
        try skip(1)
        var resized = false
        for _ in 0..<Int(try u16()) {
            let x = Int(try u16()), y = Int(try u16()), w = Int(try u16()), h = Int(try u16())
            let enc = Int32(bitPattern: try u32())
            if enc == -223 {
                resize(w, h)
                resized = true
                onResize?()
                continue
            }
            guard x + w <= width, y + h <= height else {
                throw RFBError.protocolError("rectangle \(w)x\(h)+\(x)+\(y) outside \(width)x\(height)")
            }
            switch enc {
            case 0: try readRaw(x, y, w, h)
            case 1:
                let sx = Int(try u16()), sy = Int(try u16())
                guard sx + w <= width, sy + h <= height else { throw RFBError.protocolError("bad CopyRect") }
                copyRect(sx, sy, x, y, w, h)
            case 16: try readZRLE(x, y, w, h)
            default: throw RFBError.protocolError("unexpected encoding \(enc)")
            }
        }
        return resized
    }

    private func resize(_ w: Int, _ h: Int) {
        lock.lock()
        width = w; height = h
        pixels = [UInt32](repeating: 0xFF00_0000, count: w * h)
        lock.unlock()
    }

    private func readRaw(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let data = try bytes(w * h * 4)
        lock.lock(); defer { lock.unlock() }
        for r in 0..<h {
            for c in 0..<w {
                let i = (r * w + c) * 4
                pixels[(y + r) * width + x + c] =
                    UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | 0xFF00_0000
            }
        }
    }

    private func copyRect(_ sx: Int, _ sy: Int, _ dx: Int, _ dy: Int, _ w: Int, _ h: Int) {
        lock.lock(); defer { lock.unlock() }
        var tmp = [UInt32](); tmp.reserveCapacity(w * h)
        for r in 0..<h { tmp += pixels[((sy + r) * width + sx)..<((sy + r) * width + sx + w)] }
        for r in 0..<h { pixels.replaceSubrange(((dy + r) * width + dx)..<((dy + r) * width + dx + w), with: tmp[(r * w)..<(r * w + w)]) }
    }

    // MARK: ZRLE (RFC 6143 §7.7.6)

    private func readZRLE(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let d = try zInflate(try bytes(Int(try u32())), limit: w * h * 3 + 64 * 1024)
        var p = 0
        func need(_ n: Int) throws { if p + n > d.count { throw RFBError.protocolError("truncated ZRLE data") } }
        func cpixel() throws -> UInt32 {
            try need(3)
            defer { p += 3 }
            return UInt32(d[p]) | UInt32(d[p + 1]) << 8 | UInt32(d[p + 2]) << 16 | 0xFF00_0000
        }
        func runLength() throws -> Int {
            var len = 1
            while true {
                try need(1)
                let b = d[p]; p += 1
                len += Int(b)
                if b != 255 { return len }
            }
        }
        var tile = [UInt32](repeating: 0, count: 64 * 64)
        var palette = [UInt32]()

        lock.lock(); defer { lock.unlock() }
        for ty in stride(from: y, to: y + h, by: 64) {
            let th = min(64, y + h - ty)
            for tx in stride(from: x, to: x + w, by: 64) {
                let tw = min(64, x + w - tx), n = tw * th
                try need(1)
                let sub = Int(d[p]); p += 1
                palette.removeAll(keepingCapacity: true)
                switch sub {
                case 0:
                    for i in 0..<n { tile[i] = try cpixel() }
                case 1:
                    let c = try cpixel()
                    for i in 0..<n { tile[i] = c }
                case 2...16:
                    for _ in 0..<sub { palette.append(try cpixel()) }
                    let bits = sub == 2 ? 1 : (sub <= 4 ? 2 : 4)
                    let rowBytes = (tw * bits + 7) / 8
                    try need(rowBytes * th)
                    for r in 0..<th {
                        for c in 0..<tw {
                            let bit = c * bits
                            let idx = Int(d[p + r * rowBytes + bit / 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1)
                            guard idx < sub else { throw RFBError.protocolError("bad palette index") }
                            tile[r * tw + c] = palette[idx]
                        }
                    }
                    p += rowBytes * th
                case 128:
                    var i = 0
                    while i < n {
                        let c = try cpixel(), run = try runLength()
                        guard i + run <= n else { throw RFBError.protocolError("RLE overrun") }
                        for k in i..<(i + run) { tile[k] = c }
                        i += run
                    }
                case 130...255:
                    for _ in 0..<(sub - 128) { palette.append(try cpixel()) }
                    var i = 0
                    while i < n {
                        try need(1)
                        let b = d[p]; p += 1
                        let idx = Int(b & 0x7F)
                        guard idx < palette.count else { throw RFBError.protocolError("bad palette index") }
                        let run = b & 0x80 != 0 ? try runLength() : 1
                        guard i + run <= n else { throw RFBError.protocolError("RLE overrun") }
                        for k in i..<(i + run) { tile[k] = palette[idx] }
                        i += run
                    }
                default:
                    throw RFBError.protocolError("bad ZRLE subencoding \(sub)")
                }
                for r in 0..<th {
                    let dst = (ty + r) * width + tx
                    pixels.replaceSubrange(dst..<(dst + tw), with: tile[(r * tw)..<(r * tw + tw)])
                }
            }
        }
    }

    /// ZRLE uses one zlib stream for the whole connection.
    private func zInflate(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        if !zReady {
            guard inflateInit_(&zs, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw RFBError.protocolError("zlib init failed")
            }
            zReady = true
        }
        var out = [UInt8]()
        var input = input
        try input.withUnsafeMutableBufferPointer { ib in
            zs.next_in = ib.baseAddress
            zs.avail_in = uInt(ib.count)
            while true {
                var status: Int32 = 0
                let produced = zChunk.withUnsafeMutableBufferPointer { cb -> Int in
                    zs.next_out = cb.baseAddress
                    zs.avail_out = uInt(cb.count)
                    status = inflate(&zs, Z_SYNC_FLUSH)
                    return cb.count - Int(zs.avail_out)
                }
                guard status == Z_OK || status == Z_BUF_ERROR else { throw RFBError.protocolError("zlib error \(status)") }
                out += zChunk[0..<produced]
                if out.count > limit { throw RFBError.protocolError("ZRLE data too large") }
                if zs.avail_in == 0 && zs.avail_out != 0 { break }
                if produced == 0 && status == Z_BUF_ERROR { break }
            }
        }
        return out
    }

    // MARK: socket I/O

    private func transmit(_ data: [UInt8]) {
        writeLock.lock(); defer { writeLock.unlock() }
        var off = 0
        while off < data.count {
            #if canImport(Darwin)
            let r = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + off, data.count - off, 0) }
            #else
            let r = data.withUnsafeBytes { Glibc.send(fd, $0.baseAddress! + off, data.count - off, Int32(MSG_NOSIGNAL)) }
            #endif
            if r <= 0 { return } // the reader thread will notice the dead socket
            off += r
        }
    }

    private func fill() throws {
        let r = rbuf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if r <= 0 { throw RFBError.closed }
        rpos = 0; rlen = r
    }

    private func u8() throws -> UInt8 {
        if rpos == rlen { try fill() }
        rpos += 1
        return rbuf[rpos - 1]
    }

    private func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    private func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }

    private func bytes(_ n: Int) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(n)
        while out.count < n {
            if rpos == rlen { try fill() }
            let take = min(n - out.count, rlen - rpos)
            out += rbuf[rpos..<(rpos + take)]
            rpos += take
        }
        return out
    }

    private func skip(_ n: Int) throws { _ = try bytes(n) }

    private static func connectTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Darwin)
        hints.ai_socktype = SOCK_STREAM
        #else
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw RFBError.connect(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(first) }
        var lastErr = ECONNREFUSED
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let s = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if s >= 0 {
                if connect(s, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    #if canImport(Darwin)
                    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    #endif
                    return s
                }
                lastErr = errno
                _ = sysClose(s)
            }
            ai = a.pointee.ai_next
        }
        throw RFBError.connect(String(cString: strerror(lastErr)))
    }
}

private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

#if canImport(Darwin)
private func sysClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#else
private func sysClose(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#endif
