import Foundation
import IOKit

// MARK: - Errors

enum SMCError: Error, LocalizedError {
    case serviceNotFound
    case failedToOpen
    case keyNotFound(String)
    case readFailed(kern_return_t)
    case writeFailed(kern_return_t)
    case writeNotPermitted

    var errorDescription: String? {
        switch self {
        case .serviceNotFound:        return "AppleSMC service not found"
        case .failedToOpen:           return "Failed to open SMC connection"
        case .keyNotFound(let key):   return "SMC key '\(key)' not found"
        case .readFailed(let code):   return "SMC read failed (kr=\(String(format:"0x%X", UInt32(bitPattern: code))))"
        case .writeFailed(let code):  return "SMC write failed (kr=\(String(format:"0x%X", UInt32(bitPattern: code))))"
        case .writeNotPermitted:      return "SMC write not permitted — Apple Silicon may restrict this key"
        }
    }
}

// MARK: - Raw SMC Buffer
//
// The AppleSMC driver expects a specific 80-byte struct.  Rather than relying
// on Swift's (non-guaranteed) struct padding to match the C layout, we
// allocate a plain byte array and write each field at its known offset.
//
// Layout (from the canonical C definition used across all known SMC tools):
//   0- 3  key            (UInt32, big-endian)
//   4- 9  version        (6 bytes, mostly unused)
//  10-11  [padding]
//  12-27  pLimitData     (16 bytes, mostly unused)
//  28-31  keyInfo.dataSize  (UInt32, big-endian)
//  32-35  keyInfo.dataType  (UInt32, big-endian — four-char code)
//     36  keyInfo.dataAttributes (UInt8)
//  37-39  [padding]
//     40  result         (UInt8, SMC status returned by driver)
//     41  status         (UInt8)
//     42  data8          (UInt8, sub-operation selector)
//     43  [padding]
//  44-47  data32         (UInt32, big-endian, used as key index)
//  48-79  bytes[32]      (raw data payload)

private let kBufSize = 80

private enum Off {
    static let key       = 0
    static let infoSize  = 28
    static let infoType  = 32
    static let result    = 40
    static let data8     = 42
    static let data32    = 44
    static let dataBytes = 48
}

private enum Sel: UInt8 {
    case getKeyFromIndex = 8
    case getKeyInfo      = 9
    case readKey         = 5
    case writeKey        = 6
}

private let kResultKeyNotFound: UInt8 = 0x84
private let kResultNotWritable: UInt8 = 0x85
private let kSMCYPCEvent: UInt32 = 2   // IOConnectCallStructMethod selector

// MARK: - SMCKit

final class SMCKit {

    private var connection: io_connect_t = 0
    private var isOpen = false

    init() { try? open() }
    deinit { close() }

    // MARK: - Connection

    func open() throws {
        guard !isOpen else { return }
        let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard svc != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(svc) }
        let kr = IOServiceOpen(svc, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.failedToOpen }
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(connection)
        isOpen = false
    }

    // MARK: - Public API

    func readTemperature(key: String) throws -> Double {
        let (dataType, bytes) = try read(key)
        switch dataType {
        case "flt ": return decodeFLT(bytes)
        case "si16": return decodeSI16(bytes)
        default:     return decodeSP78(bytes)   // sp78 + unknown
        }
    }

    func readFanRPM(key: String) throws -> Double {
        let (dataType, bytes) = try read(key)
        switch dataType {
        case "flt ": return decodeFLT(bytes)
        case "ui16": return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:     return decodeFPE2(bytes)   // fpe2
        }
    }

    /// Read a ui8 value (e.g. F0Md, Ftst)
    func readUInt8(key: String) throws -> UInt8 {
        let (_, bytes) = try read(key)
        return bytes.first ?? 0
    }

    /// Write a ui8 value (e.g. F0Md, Ftst)
    func writeUInt8(key: String, value: UInt8) throws {
        try write(key, bytes: [value])
    }

    /// Write fan RPM — auto-detects type (flt on Apple Silicon, fpe2 on Intel).
    func writeFanRPM(key: String, rpm: Double) throws {
        let (dataType, _) = try read(key)
        switch dataType.trimmingCharacters(in: .whitespaces) {
        case "flt":
            try write(key, bytes: encodeFLT(rpm))
        default:
            try write(key, bytes: encodeFPE2(rpm))
        }
    }

    // MARK: - Debug Dump

    /// Returns the first key in `candidates` that the SMC recognizes, or nil.
    /// Used to handle SMC naming differences across Mac generations
    /// (e.g. F0Md on M2 Pro vs F0md on M5 Pro).
    func resolveKey(_ candidates: [String]) -> String? {
        for k in candidates {
            if (try? read(k)) != nil { return k }
        }
        return nil
    }

    /// Dump only the keys we care about (fans + temps + control keys).
    func dumpAllKeys() -> String {
        guard isOpen else { return "SMC not open" }

        let keysToCheck = [
            "FNum", "F0Ac", "F1Ac", "F0Mn", "F1Mn", "F0Mx", "F1Mx",
            "F0Tg", "F1Tg", "F0Md", "F1Md", "F0md", "F1md",
            "F0Sf", "F1Sf", "Ftst",
            "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j",
            "Tp1h", "Tp1t", "Tp1p", "Tp1l",
            "Tg0f", "Tg0j",
            "TC0P", "TC0D", "TG0P", "TG0D",
        ]

        var lines = ["SMC key dump (targeted)\n"]

        for key in keysToCheck {
            do {
                let (dataType, bytes) = try read(key)
                let typ = dataType.trimmingCharacters(in: .whitespaces)
                let hex = bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

                var decoded = ""
                if typ == "flt" && bytes.count >= 4 { decoded = String(format: "%.2f", decodeFLT(bytes)) }
                else if typ == "sp78" && bytes.count >= 2 { decoded = String(format: "%.2f °C", decodeSP78(bytes)) }
                else if typ == "fpe2" && bytes.count >= 2 { decoded = String(format: "%.2f RPM", decodeFPE2(bytes)) }
                else if typ == "ui8" && bytes.count >= 1 { decoded = "\(bytes[0])" }

                let val = decoded.isEmpty ? hex : "\(hex) → \(decoded)"
                lines.append("\(key)  type=\(typ)  size=\(bytes.count)  \(val)")
            } catch {
                lines.append("\(key)  \(error.localizedDescription)")
            }
        }

        // Also try a write test to F0Tg (read current value, write it back)
        lines.append("\n--- Write test ---")
        do {
            let (typ, bytes) = try read("F0Tg")
            lines.append("F0Tg read OK: type=\(typ.trimmingCharacters(in: .whitespaces)) bytes=\(bytes.map{String(format:"%02X",$0)}.joined(separator:" "))")
            // Try writing the same value back
            try write("F0Tg", bytes: bytes)
            lines.append("F0Tg write OK (wrote same value back)")
        } catch {
            lines.append("F0Tg write test: \(error.localizedDescription)")
        }

        if let mdKey = resolveKey(FanKey.fan0ModeCandidates) {
            do {
                try writeUInt8(key: mdKey, value: 1)
                lines.append("\(mdKey) write 1 OK")
                try writeUInt8(key: mdKey, value: 0)
                lines.append("\(mdKey) write 0 OK (restored)")
            } catch {
                lines.append("\(mdKey) write test: \(error.localizedDescription)")
            }
        } else {
            lines.append("Fan-mode key not found (tried \(FanKey.fan0ModeCandidates.joined(separator: ", ")))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Raw I/O

    private func read(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        // getKeyInfo
        var infoBuf = makeBuf()
        setNat32(&infoBuf, Off.key, fourCC(key))
        infoBuf[Off.data8] = Sel.getKeyInfo.rawValue
        let infoOut = try call(infoBuf)
        if infoOut[Off.result] == kResultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard infoOut[Off.result] == 0 else { throw SMCError.readFailed(kern_return_t(infoOut[Off.result])) }

        let dataSize = getNat32(infoOut, Off.infoSize)
        let dataType = codeStr(getNat32(infoOut, Off.infoType))

        // read
        var rdBuf = makeBuf()
        setNat32(&rdBuf, Off.key, fourCC(key))
        setNat32(&rdBuf, Off.infoSize, dataSize)
        rdBuf[Off.data8] = Sel.readKey.rawValue
        let rdOut = try call(rdBuf)
        if rdOut[Off.result] == kResultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard rdOut[Off.result] == 0 else { throw SMCError.readFailed(kern_return_t(rdOut[Off.result])) }

        let bytes = Array(rdOut[Off.dataBytes ..< min(Off.dataBytes + Int(dataSize), kBufSize)])
        return (dataType, bytes)
    }

    private func write(_ key: String, bytes: [UInt8]) throws {
        // getKeyInfo to get the type
        var infoBuf = makeBuf()
        setNat32(&infoBuf, Off.key, fourCC(key))
        infoBuf[Off.data8] = Sel.getKeyInfo.rawValue
        let infoOut = try call(infoBuf)
        if infoOut[Off.result] == kResultKeyNotFound { throw SMCError.keyNotFound(key) }
        guard infoOut[Off.result] == 0 else { throw SMCError.readFailed(kern_return_t(infoOut[Off.result])) }

        var wrBuf = makeBuf()
        setNat32(&wrBuf, Off.key, fourCC(key))
        setNat32(&wrBuf, Off.infoSize, UInt32(bytes.count))
        setNat32(&wrBuf, Off.infoType, getNat32(infoOut, Off.infoType))
        wrBuf[Off.data8] = Sel.writeKey.rawValue
        for (i, b) in bytes.enumerated() where Off.dataBytes + i < kBufSize {
            wrBuf[Off.dataBytes + i] = b
        }
        let wrOut = try call(wrBuf)
        if wrOut[Off.result] == kResultNotWritable { throw SMCError.writeNotPermitted }
        guard wrOut[Off.result] == 0 else { throw SMCError.writeFailed(kern_return_t(wrOut[Off.result])) }
    }

    /// Calls IOConnectCallStructMethod, throws on kern_return_t failure.
    private func call(_ input: [UInt8]) throws -> [UInt8] {
        guard isOpen else { throw SMCError.serviceNotFound }
        let (kr, out) = rawCall(input)
        guard kr == kIOReturnSuccess else {
            throw SMCError.readFailed(kr)
        }
        return out
    }

    /// Calls IOConnectCallStructMethod, returns the kern_return_t and output buffer.
    private func rawCall(_ input: [UInt8]) -> (kern_return_t, [UInt8]) {
        var inp = input
        var out = [UInt8](repeating: 0, count: kBufSize)
        var outSize = kBufSize
        let kr = inp.withUnsafeMutableBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                IOConnectCallStructMethod(
                    connection, kSMCYPCEvent,
                    inBuf.baseAddress, kBufSize,
                    outBuf.baseAddress, &outSize
                )
            }
        }
        return (kr, out)
    }


    // MARK: - Buffer Helpers

    private func makeBuf() -> [UInt8] { [UInt8](repeating: 0, count: kBufSize) }

    /// Write UInt32 in **native** byte order (little-endian on ARM64).
    /// The AppleSMC kernel driver stores struct fields in native endian.
    private func setNat32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { src in
            for i in 0..<4 { buf[offset + i] = src[i] }
        }
    }

    /// Read UInt32 in native byte order.
    private func getNat32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        var val: UInt32 = 0
        withUnsafeMutableBytes(of: &val) { dst in
            for i in 0..<4 { dst[i] = buf[offset + i] }
        }
        return val
    }

    // MARK: - Encode / Decode

    private func decodeFPE2(_ b: [UInt8]) -> Double {
        guard b.count >= 2 else { return 0 }
        return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
    }

    private func encodeFPE2(_ rpm: Double) -> [UInt8] {
        let raw = UInt16(max(0, rpm) * 4.0)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    private func decodeSP78(_ b: [UInt8]) -> Double {
        guard b.count >= 2 else { return 0 }
        return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
    }

    /// FLT on Apple Silicon is IEEE 754 float, **little-endian** byte order.
    private func decodeFLT(_ b: [UInt8]) -> Double {
        guard b.count >= 4 else { return 0 }
        let raw = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return Double(Float(bitPattern: raw))
    }

    private func encodeFLT(_ value: Double) -> [UInt8] {
        let raw = Float(value).bitPattern
        return [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
                UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF)]
    }

    private func decodeSI16(_ b: [UInt8]) -> Double {
        guard b.count >= 2 else { return 0 }
        return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
    }

    // MARK: - Four-char Code Helpers

    private func fourCC(_ s: String) -> UInt32 {
        s.unicodeScalars.prefix(4).enumerated().reduce(0) { acc, p in
            acc | (UInt32(p.element.value) << UInt32((3 - p.offset) * 8))
        }
    }

    private func codeStr(_ code: UInt32) -> String {
        [24, 16, 8, 0].map { shift -> Character in
            let b = UInt8((code >> shift) & 0xFF)
            return b > 31 && b < 127 ? Character(UnicodeScalar(b)) : "."
        }.reduce("") { $0 + String($1) }
    }
}
