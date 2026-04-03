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
        case .readFailed(let code):   return "SMC read failed (result=\(code))"
        case .writeFailed(let code):  return "SMC write failed (result=\(code))"
        case .writeNotPermitted:      return "SMC write not permitted — Apple Silicon may restrict this key"
        }
    }
}

// MARK: - Structures
//
// These structs must match the C layout the AppleSMC kernel driver expects.
// All are plain value types so Swift gives them C-compatible memory layout.

/// Alias for the 32-byte data buffer carried in SMCParamStruct.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

struct SMCVersion {
    var major: UInt8    = 0
    var minor: UInt8    = 0
    var build: UInt8    = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version:   UInt16 = 0
    var length:    UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize:       UInt32 = 0
    var dataType:       UInt32 = 0
    var dataAttributes: UInt8  = 0
}

/// The main in/out struct passed to IOConnectCallStructMethod (selector 2).
/// Sub-operation is chosen by setting `data8` to a `SMCSelector` raw value.
struct SMCParamStruct {
    var key         : UInt32       = 0
    var vers        = SMCVersion()
    var pLimitData  = SMCPLimitData()
    var keyInfo     = SMCKeyInfoData()
    var result      : UInt8        = 0
    var status      : UInt8        = 0
    var data8       : UInt8        = 0
    var data32      : UInt32       = 0
    var bytes       : SMCBytes     = (
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0
    )
}

/// Sub-operation selector placed in SMCParamStruct.data8.
private enum SMCSelector: UInt8 {
    case getKeyInfo  = 9
    case readKey     = 5
    case writeKey    = 6
}

// SMC result codes returned in SMCParamStruct.result
private let kSMCKeyNotFound:   UInt8 = 0x84
private let kSMCNotWritable:   UInt8 = 0x85

// IOConnectCallStructMethod selector for all SMC operations
private let kSMCHandleYPCEvent: UInt32 = 2

// MARK: - SMCKit

/// Thread-unsafe; only call from main thread / @MainActor context.
final class SMCKit {

    private var connection: io_connect_t = 0
    private var isOpen = false

    init() {
        try? open()
    }

    deinit {
        close()
    }

    // MARK: - Public API

    func readTemperature(key: String) throws -> Double {
        let output = try readKey(key)
        return decodeSP78(output.bytes)
    }

    func readFanRPM(key: String) throws -> Double {
        let output = try readKey(key)
        return decodeFPE2(output.bytes)
    }

    func writeFanRPM(key: String, rpm: Double) throws {
        let encoded = encodeFPE2(rpm)
        try writeKey(key, bytes: encoded, dataSize: 2)
    }

    // MARK: - Connection

    func open() throws {
        guard !isOpen else { return }
        let service = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard kr == kIOReturnSuccess else { throw SMCError.failedToOpen }
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(connection)
        isOpen = false
    }

    // MARK: - Low-level Calls

    private func callSMC(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard isOpen else { throw SMCError.serviceNotFound }
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            connection,
            kSMCHandleYPCEvent,
            &input,
            MemoryLayout<SMCParamStruct>.size,
            &output,
            &outSize
        )
        guard kr == kIOReturnSuccess else { throw SMCError.readFailed(kr) }
        return output
    }

    private func getKeyInfo(_ key: String) throws -> SMCKeyInfoData {
        var input = SMCParamStruct()
        input.key  = fourCharCode(key)
        input.data8 = SMCSelector.getKeyInfo.rawValue
        let output = try callSMC(&input)
        if output.result == kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.readFailed(kern_return_t(output.result)) }
        return output.keyInfo
    }

    private func readKey(_ key: String) throws -> SMCParamStruct {
        let info = try getKeyInfo(key)
        var input = SMCParamStruct()
        input.key              = fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8            = SMCSelector.readKey.rawValue
        let output = try callSMC(&input)
        if output.result == kSMCKeyNotFound { throw SMCError.keyNotFound(key) }
        guard output.result == 0 else { throw SMCError.readFailed(kern_return_t(output.result)) }
        return output
    }

    private func writeKey(_ key: String, bytes: [UInt8], dataSize: UInt32) throws {
        let info = try getKeyInfo(key)
        var input = SMCParamStruct()
        input.key              = fourCharCode(key)
        input.keyInfo.dataSize = dataSize
        input.keyInfo.dataType = info.dataType
        input.data8            = SMCSelector.writeKey.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { ptr in
            for (i, byte) in bytes.prefix(Int(dataSize)).enumerated() {
                ptr[i] = byte
            }
        }
        let output = try callSMC(&input)
        if output.result == kSMCNotWritable { throw SMCError.writeNotPermitted }
        guard output.result == 0 else { throw SMCError.writeFailed(kern_return_t(output.result)) }
    }

    // MARK: - Encoding / Decoding

    /// FPE2 (unsigned 14.2 fixed-point, big-endian):  raw = rpm × 4
    private func decodeFPE2(_ bytes: SMCBytes) -> Double {
        Double(UInt16(bytes.0) << 8 | UInt16(bytes.1)) / 4.0
    }

    private func encodeFPE2(_ rpm: Double) -> [UInt8] {
        let raw = UInt16(max(0, rpm) * 4.0)
        return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
    }

    /// SP78 (signed 7.8 fixed-point, big-endian):  raw / 256.0 = °C
    private func decodeSP78(_ bytes: SMCBytes) -> Double {
        let raw = UInt16(bytes.0) << 8 | UInt16(bytes.1)
        return Double(Int16(bitPattern: raw)) / 256.0
    }

    // MARK: - Helpers

    /// Encodes a 4-character ASCII string as a big-endian UInt32 SMC key.
    private func fourCharCode(_ string: String) -> UInt32 {
        string.unicodeScalars.prefix(4).enumerated().reduce(0) { acc, pair in
            acc | (UInt32(pair.element.value) << UInt32((3 - pair.offset) * 8))
        }
    }
}
