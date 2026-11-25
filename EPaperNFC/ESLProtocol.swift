import Foundation

// Fudan FMSH ESL command set (Good Display "NFC FMSC ESL User Development Manual").

typealias RawSend = ([UInt8]) async throws -> ([UInt8], UInt16)

enum ESL {
    static func apdu(_ cla: UInt8, _ ins: UInt8, _ p1: UInt8, _ p2: UInt8,
                     data: [UInt8] = [], le: UInt8? = nil) -> [UInt8] {
        var a: [UInt8] = [cla, ins, p1, p2]
        if !data.isEmpty { a.append(UInt8(data.count)); a += data }
        if let le { a.append(le) }
        return a
    }

    static let configInfo = apdu(0x00, 0xD1, 0x00, 0x00, le: 0x00)          // 7.4 Get Config Info
    static let busyStatus = apdu(0xF0, 0xDE, 0x00, 0x00, le: 0x01)          // 7.12 Get EPD Busy Status
    static func verifyPIN(_ pin: [UInt8]) -> [UInt8] { apdu(0x00, 0x20, 0x00, 0x01, data: pin) }   // 7.2

    /// 7.9 Set Screen Type, P1P2 = 0000. Data = manufacturer, size|pixels, colour.
    static func setScreenType(_ d: [UInt8]) -> [UInt8] { apdu(0xF0, 0xDA, 0x00, 0x00, data: d) }

    /// 7.9 Set Screen Type, P1P2 = 0001 (vertical scan) or 0101 (horizontal scan): colour control params.
    static func setColorParams(_ d: [UInt8], horizontalScan: Bool = false) -> [UInt8] {
        apdu(0xF0, 0xDA, horizontalScan ? 0x01 : 0x00, 0x01, data: d)
    }

    /// 7.5 Load Image: P1 = image index, P2 = packet number, 250 bytes per packet (last may be shorter).
    static func loadImage(index: UInt8, packet: UInt8, chunk: [UInt8]) -> [UInt8] {
        apdu(0xF0, 0xD2, index, packet, data: chunk)
    }

    /// 7.7 Redraw Screen: P1 = screen power-on delay (x100 ms; must be > 0 on a battery-free board,
    /// P1 = 0 means "switch on external battery"). P2 bit7 = 1 -> return immediately, bits6-0 = image index.
    static func redraw(index: UInt8, immediate: Bool, powerOnDelay: UInt8 = 0x01) -> [UInt8] {
        apdu(0xF0, 0xD4, powerOnDelay & 0x7F, (immediate ? 0x80 : 0x00) | (index & 0x7F), le: 0x00)
    }
}

enum ESLError: LocalizedError {
    case badAPDU, badResponse, timeout
    case status(UInt16)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badAPDU: return "Invalid APDU"
        case .badResponse: return "Unexpected tag response"
        case .timeout: return "Screen refresh timed out"
        case .message(let m): return m
        case .status(let sw):
            return String(format: "Tag error %04X", sw) + (ESLError.describe(sw).map { " – \($0)" } ?? "")
        }
    }

    static func describe(_ sw: UInt16) -> String? {
        if sw & 0xFFF0 == 0x63C0 {
            let left = sw & 0x0F
            return left == 0 ? "wrong PIN, PIN is now blocked" : "wrong PIN, \(left) tries left"
        }
        if sw & 0xFF00 == 0x6C00 { return String(format: "wrong Le, expected %02X", sw & 0xFF) }
        return names[sw]
    }

    // Manual Appendix A + section 6 notes.
    static let names: [UInt16: String] = [
        0x6281: "returned data may be wrong",
        0x6449: "configuration EEPROM error",
        0x6450: "screen init data error",
        0x6451: "screen init data has bad TAG",
        0x6452: "screen init data has bad value",
        0x6453: "screen init data missing required option",
        0x6454: "screen refresh failed",
        0x6455: "screen reset failed",
        0x6581: "EEPROM write failed",
        0x6700: "Lc/Le error",
        0x6781: "packet total length wrong",
        0x68C6: "screen reset failed / panel not detected – check the panel cable and that its custom DB driver flow is installed",
        0x68CA: "low voltage – hold the phone still and closer",
        0x68CB: "screen refresh timeout",
        0x6982: "security status not satisfied – verify PIN first",
        0x6983: "PIN blocked",
        0x6985: "conditions of use not satisfied",
        0x6988: "secure message data incorrect",
        0x6995: "image packet sequence mismatch",
        0x6996: "image index mismatch",
        0x6A80: "data field error",
        0x6A86: "P1/P2 error",
        0x6AE1: "NDEF file length error",
        0x6AE2: "NDEF format error",
        0x6AE3: "NDEF record is not mime type",
        0x6AE4: "NDEF write longer than CC allows",
        0x6AE5: "NDEF command executed twice",
        0x6D00: "command not supported (or not allowed inside NDEF)",
        0x6E00: "class not supported",
    ]
}

/// iOS-compatible transport: wraps each ESL APDU in an NDEF mime record (manual section 6).
/// The record is written to NDEF file E104, writing the 2-byte NDEF length triggers execution,
/// and the result (data || SW1 SW2) is read back from the same file.
final class NDEFWrapper {
    private let raw: RawSend
    private var selected = false
    init(raw: @escaping RawSend) { self.raw = raw }

    private func ok(_ cmd: [UInt8]) async throws -> [UInt8] {
        let (d, sw) = try await raw(cmd)
        guard sw == 0x9000 else { throw ESLError.status(sw) }
        return d
    }

    func send(_ apdu: [UInt8]) async throws -> ([UInt8], UInt16) {
        if !selected {
            _ = try await ok([0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00])
            _ = try await ok([0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04])
            selected = true
        }
        // NDEF record, type 'e' (0x65). Short record when payload < 256, else 4-byte length.
        var rec: [UInt8]
        if apdu.count < 256 {
            rec = [0xD2, 0x01, UInt8(apdu.count), 0x65] + apdu
        } else {
            let n = UInt32(apdu.count)
            rec = [0xC2, 0x01, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 0x65] + apdu
        }
        let file: [UInt8] = [0x00, 0x00] + rec   // NLEN = 0 while the body is written

        // Write body (the CC file limits UPDATE BINARY to 250 bytes)
        var off = 0
        while off < file.count {
            let n = min(250, file.count - off)
            _ = try await ok([0x00, 0xD6, UInt8(off >> 8), UInt8(off & 0xFF), UInt8(n)] + Array(file[off..<off + n]))
            off += n
        }
        // Writing the length triggers execution
        _ = try await ok([0x00, 0xD6, 0x00, 0x00, 0x02, UInt8(rec.count >> 8), UInt8(rec.count & 0xFF)])

        // Read result
        let lb = try await ok([0x00, 0xB0, 0x00, 0x00, 0x02])
        guard lb.count == 2 else { throw ESLError.badResponse }
        let len = Int(lb[0]) << 8 | Int(lb[1])
        var resp: [UInt8] = []
        var o = 2
        while resp.count < len {
            let n = min(250, len - resp.count)
            let d = try await ok([0x00, 0xB0, UInt8(o >> 8), UInt8(o & 0xFF), UInt8(n)])
            if d.isEmpty { break }
            resp += d
            o += d.count
        }
        // Parse record -> payload = data || SW1 SW2
        guard resp.count >= 4 else { throw ESLError.badResponse }
        let typeLen = Int(resp[1])
        var i: Int, payLen: Int
        if resp[0] & 0x10 != 0 {
            payLen = Int(resp[2]); i = 3
        } else {
            guard resp.count >= 6 else { throw ESLError.badResponse }
            payLen = Int(resp[2]) << 24 | Int(resp[3]) << 16 | Int(resp[4]) << 8 | Int(resp[5]); i = 6
        }
        i += typeLen
        guard resp.count >= i + payLen, payLen >= 2 else { throw ESLError.badResponse }
        let payload = Array(resp[i..<i + payLen])
        let sw = UInt16(payload[payLen - 2]) << 8 | UInt16(payload[payLen - 1])
        return (Array(payload.dropLast(2)), sw)
    }
}

/// Parsed Get Config Info ('D1') response, manual 7.4.3 (TLV).
/// Tag A0 (7 bytes) = manufacturer/driver, size|pixels, colour, X (2), Y (2).
struct TagConfig {
    var entries: [(tag: UInt8, value: [UInt8])] = []
    var manufacturer: UInt8?
    var sizeByte: UInt8?
    var colorByte: UInt8?
    var width: Int?
    var height: Int?
    var imageCapacity: Int?

    init(tlv d: [UInt8]) {
        var i = 0
        while i + 1 < d.count {
            let tag = d[i], len = Int(d[i + 1])
            guard i + 2 + len <= d.count else { break }
            let v = Array(d[(i + 2)..<(i + 2 + len)])
            entries.append((tag, v))
            switch tag {
            case 0xA0 where v.count >= 3:
                manufacturer = v[0]; sizeByte = v[1]; colorByte = v[2]
                if v.count >= 7 {
                    width = Int(v[3]) << 8 | Int(v[4])
                    height = Int(v[5]) << 8 | Int(v[6])
                }
            case 0xB1 where v.count == 1:
                imageCapacity = Int(v[0])
            default:
                break
            }
            i += 2 + len
        }
    }

    static func sizeName(_ b: UInt8) -> String {
        let sizes = ["2.13\"", "2.9\"", "1.54\"", "4.2\"", "2.7\"", "3.1\"", "2.66\""]
        let s = Int(b & 0x0F)
        return s < sizes.count ? sizes[s] : String(format: "size %02X", b)
    }

    static func colorName(_ b: UInt8) -> String {
        switch b {
        case 0x20: return "B/W"
        case 0x30: return "B/W/R"
        case 0x31: return "B/W/Y"
        default: return String(format: "colour %02X", b)
        }
    }

    var summary: String {
        var s: [String] = []
        if let m = manufacturer { s.append(m == 0xF0 ? "custom driver (F0)" : String(format: "driver %02X", m)) }
        if let b = sizeByte { s.append(TagConfig.sizeName(b)) }
        if let w = width, let h = height { s.append("\(w)×\(h)") }
        if let c = colorByte { s.append(TagConfig.colorName(c)) }
        if let n = imageCapacity { s.append("\(n) image slot(s)") }
        return s.isEmpty ? "No screen config found" : s.joined(separator: ", ")
    }

    var rawDescription: String {
        entries.map { String(format: "%02X: ", $0.tag) + $0.value.hex }.joined(separator: "  ")
    }
}

final class ESLClient {
    private let raw: RawSend
    private let wrapper: NDEFWrapper?
    let log: (String) -> Void

    init(raw: @escaping RawSend, wrapNDEF: Bool, log: @escaping (String) -> Void) {
        self.raw = raw
        self.wrapper = wrapNDEF ? NDEFWrapper(raw: raw) : nil
        self.log = log
    }

    @discardableResult
    func send(_ apdu: [UInt8], quiet: Bool = false) async throws -> [UInt8] {
        let d: [UInt8], sw: UInt16
        if let wrapper {
            do {
                (d, sw) = try await wrapper.send(apdu)
            } catch ESLError.status(0x6D00) {
                (d, sw) = ([], 0x6D00)
            }
            // Manual section 6, note 3: some commands are refused inside NDEF -> send them raw.
            // The refusal can come from the NDEF write itself or as the SW inside the result record.
            if sw == 0x6D00 {
                log("\(apdu.prefix(2).hex) refused in NDEF mode, retrying as raw APDU")
                (d, sw) = try await raw(apdu)
            }
        } else {
            (d, sw) = try await raw(apdu)
        }
        if !quiet { log("→ \(apdu.prefix(5).hex)  ← \(d.hex) \(String(format: "%04X", sw))") }
        guard sw == 0x9000 else { throw ESLError.status(sw) }
        return d
    }

    func readConfig() async throws -> TagConfig {
        TagConfig(tlv: try await send(ESL.configInfo, quiet: true))
    }

    /// Upload 1 plane (B/W) or 2 planes (B/W + colour) to index 0/1, refresh, wait for BUSY low.
    func writeImage(planes: [[UInt8]], progress: @escaping (Int) -> Void) async throws {
        let total = planes.reduce(0) { $0 + ($1.count + 249) / 250 }
        var done = 0
        for (index, plane) in planes.enumerated() {
            var packet = 0
            for start in stride(from: 0, to: plane.count, by: 250) {
                let chunk = Array(plane[start..<min(start + 250, plane.count)])
                try await send(ESL.loadImage(index: UInt8(index), packet: UInt8(packet), chunk: chunk), quiet: true)
                packet += 1; done += 1
                progress(done * 100 / max(total, 1))
            }
        }
        log("Image uploaded (\(done) packets). Refreshing…")
        // Battery-free board: the phone's RF field powers the refresh, so use immediate mode
        // and keep the session alive by polling BUSY ('DE') until the panel is idle.
        try await send(ESL.redraw(index: 0, immediate: true))
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            let r = try await send(ESL.busyStatus, quiet: true)
            if r.first == 0x00 { log("Refresh complete"); return }
        }
        throw ESLError.timeout
    }
}

extension Collection where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined() }
}

func hexBytes(_ s: String) -> [UInt8]? {
    let c = s.replacingOccurrences(of: " ", with: "")
    guard c.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = c.startIndex
    while i < c.endIndex {
        let j = c.index(i, offsetBy: 2)
        guard let b = UInt8(c[i..<j], radix: 16) else { return nil }
        out.append(b); i = j
    }
    return out
}
