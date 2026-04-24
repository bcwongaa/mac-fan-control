/// FanHelper — tiny CLI tool that writes SMC fan keys.
/// Invoked by the main app via "sudo FanHelper <command> [args...]"
/// Commands:
///   set-fan <fan:0|1> <rpm>    — set F{fan} mode to manual, F{fan}Tg to rpm
///   auto                        — restore auto mode on both fans
///
/// Fan-mode key casing differs across Mac generations:
///   M2 Pro (Mac14,*): F0Md / F1Md  (capital M)
///   M5 Pro (Mac17,*): F0md / F1md  (lowercase m)
/// We resolve the actual key at runtime by probing both candidates.
import Foundation
import IOKit

// MARK: - SMC raw I/O (same logic as SMCKit, inlined for standalone binary)

let kBufSize = 80

enum Off {
    static let key = 0, infoSize = 28, infoType = 32
    static let result: Int = 40, data8: Int = 42, dataBytes = 48
}

var connection: io_connect_t = 0

func openSMC() -> Bool {
    let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
    guard svc != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(svc) }
    return IOServiceOpen(svc, mach_task_self_, 0, &connection) == kIOReturnSuccess
}

func setNat32(_ buf: inout [UInt8], _ off: Int, _ val: UInt32) {
    withUnsafeBytes(of: val) { s in for i in 0..<4 { buf[off+i] = s[i] } }
}
func getNat32(_ buf: [UInt8], _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    withUnsafeMutableBytes(of: &v) { d in for i in 0..<4 { d[i] = buf[off+i] } }
    return v
}
func fourCC(_ s: String) -> UInt32 {
    s.unicodeScalars.prefix(4).enumerated().reduce(0) { a, p in
        a | (UInt32(p.element.value) << UInt32((3 - p.offset) * 8))
    }
}

func rawCall(_ input: [UInt8]) -> (Int32, [UInt8]) {
    var inp = input
    var out = [UInt8](repeating: 0, count: kBufSize)
    var sz = kBufSize
    let kr = inp.withUnsafeMutableBufferPointer { ib in
        out.withUnsafeMutableBufferPointer { ob in
            IOConnectCallStructMethod(connection, 2, ib.baseAddress, kBufSize, ob.baseAddress, &sz)
        }
    }
    return (kr, out)
}

func smcRead(_ key: String) -> (type: String, bytes: [UInt8])? {
    var buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    buf[Off.data8] = 9 // getKeyInfo
    let (kr1, out1) = rawCall(buf)
    guard kr1 == kIOReturnSuccess, out1[Off.result] == 0 else { return nil }

    let dataSize = getNat32(out1, Off.infoSize)
    let codeStr: String = {
        let c = getNat32(out1, Off.infoType)
        return [24,16,8,0].map { Character(UnicodeScalar(UInt8((c >> $0) & 0xFF))) }
            .reduce("") { $0 + String($1) }
    }()

    buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    setNat32(&buf, Off.infoSize, dataSize)
    buf[Off.data8] = 5 // readKey
    let (kr2, out2) = rawCall(buf)
    guard kr2 == kIOReturnSuccess, out2[Off.result] == 0 else { return nil }
    return (codeStr, Array(out2[Off.dataBytes ..< min(Off.dataBytes + Int(dataSize), kBufSize)]))
}

/// Returns nil on success, or a descriptive error string.
/// Error string includes the SMC result code so the user sees *why* a write failed
/// (0x84 = key-not-found, 0x85 = not-writable, etc).
func smcWrite(_ key: String, bytes: [UInt8]) -> String? {
    var buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    buf[Off.data8] = 9 // getKeyInfo
    let (kr1, out1) = rawCall(buf)
    if kr1 != kIOReturnSuccess {
        return "getKeyInfo kr=\(String(format:"0x%X", UInt32(bitPattern: kr1)))"
    }
    if out1[Off.result] != 0 {
        return "getKeyInfo result=\(String(format:"0x%X", out1[Off.result]))"
    }

    buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    setNat32(&buf, Off.infoSize, UInt32(bytes.count))
    setNat32(&buf, Off.infoType, getNat32(out1, Off.infoType))
    buf[Off.data8] = 6 // writeKey
    for (i, b) in bytes.enumerated() where Off.dataBytes + i < kBufSize {
        buf[Off.dataBytes + i] = b
    }
    let (kr2, out2) = rawCall(buf)
    if kr2 != kIOReturnSuccess {
        return "write kr=\(String(format:"0x%X", UInt32(bitPattern: kr2)))"
    }
    if out2[Off.result] != 0 {
        return "write result=\(String(format:"0x%X", out2[Off.result]))"
    }
    return nil
}

/// Picks the first existing key from a list of candidates. Lets us cope with
/// SMC naming changes across Mac generations (e.g. F0Md on M2 Pro vs F0md on M5 Pro).
func resolveKey(_ candidates: [String]) -> String? {
    for k in candidates where smcRead(k) != nil { return k }
    return nil
}

func encodeFLT(_ value: Double) -> [UInt8] {
    let raw = Float(value).bitPattern
    return [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF),
            UInt8((raw >> 16) & 0xFF), UInt8((raw >> 24) & 0xFF)]
}

// MARK: - Main

guard openSMC() else { fputs("Failed to open SMC\n", stderr); exit(1) }

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: FanHelper set-fan <0|1> <rpm> | auto\n", stderr); exit(1)
}

func modeKey(forFan fan: Int) -> String? {
    resolveKey(["F\(fan)Md", "F\(fan)md"])
}

switch args[1] {
case "set-fan":
    guard args.count >= 4, let fan = Int(args[2]), let rpm = Double(args[3]) else {
        fputs("Usage: FanHelper set-fan <0|1> <rpm>\n", stderr); exit(1)
    }
    guard let mdKey = modeKey(forFan: fan) else {
        fputs("No fan-mode SMC key found for fan \(fan) (tried F\(fan)Md, F\(fan)md)\n", stderr); exit(1)
    }
    let tgKey = "F\(fan)Tg"

    if let err = smcWrite(mdKey, bytes: [1]) {
        fputs("Failed to set \(mdKey)=1: \(err)\n", stderr); exit(1)
    }
    if let err = smcWrite(tgKey, bytes: encodeFLT(rpm)) {
        fputs("Failed to set \(tgKey)=\(rpm): \(err)\n", stderr); exit(1)
    }
    print("OK: \(mdKey)=1 \(tgKey)=\(rpm)")

case "auto":
    var msgs: [String] = []
    for fan in 0..<2 {
        guard let mdKey = modeKey(forFan: fan) else {
            msgs.append("fan \(fan): no mode key"); continue
        }
        if let err = smcWrite(mdKey, bytes: [0]) {
            msgs.append("\(mdKey)=0 failed: \(err)")
        } else {
            msgs.append("\(mdKey)=0")
        }
    }
    print("OK: " + msgs.joined(separator: ", "))

default:
    fputs("Unknown command: \(args[1])\n", stderr); exit(1)
}

IOServiceClose(connection)
