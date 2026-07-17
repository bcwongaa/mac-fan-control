import Foundation

public enum SMCDataCodecError: Error, LocalizedError, Equatable {
    case insufficientBytes(dataType: String, expected: Int, actual: Int)
    case unsupportedDataType(String)
    case invalidNumericValue(Double)

    public var errorDescription: String? {
        switch self {
        case let .insufficientBytes(dataType, expected, actual):
            return "SMC type '\(dataType)' requires \(expected) bytes; received \(actual)"
        case let .unsupportedDataType(dataType):
            return "Unsupported SMC data type '\(dataType)'"
        case let .invalidNumericValue(value):
            return "Invalid SMC numeric value \(value)"
        }
    }
}

public enum SMCDataCodec {
    public static func decodeUInt8(_ bytes: [UInt8], dataType: String) throws -> UInt8 {
        guard normalized(dataType) == "ui8" else {
            throw SMCDataCodecError.unsupportedDataType(dataType)
        }
        try require(bytes, count: 1, dataType: dataType)
        return bytes[0]
    }

    public static func decodeTemperature(_ bytes: [UInt8], dataType: String) throws -> Double {
        switch normalized(dataType) {
        case "flt":
            return try decodeFloat(bytes, dataType: dataType)
        case "si16":
            try require(bytes, count: 2, dataType: dataType)
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "sp78":
            try require(bytes, count: 2, dataType: dataType)
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        default:
            throw SMCDataCodecError.unsupportedDataType(dataType)
        }
    }

    public static func decodeFanRPM(_ bytes: [UInt8], dataType: String) throws -> Double {
        switch normalized(dataType) {
        case "flt":
            return try decodeFloat(bytes, dataType: dataType)
        case "ui16":
            try require(bytes, count: 2, dataType: dataType)
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "fpe2":
            try require(bytes, count: 2, dataType: dataType)
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        default:
            throw SMCDataCodecError.unsupportedDataType(dataType)
        }
    }

    public static func encodeFanRPM(_ rpm: Double, dataType: String) throws -> [UInt8] {
        guard rpm.isFinite, rpm >= 0 else {
            throw SMCDataCodecError.invalidNumericValue(rpm)
        }

        switch normalized(dataType) {
        case "flt":
            let value = Float(rpm)
            guard value.isFinite else { throw SMCDataCodecError.invalidNumericValue(rpm) }
            let raw = value.bitPattern
            return [
                UInt8(raw & 0xFF),
                UInt8((raw >> 8) & 0xFF),
                UInt8((raw >> 16) & 0xFF),
                UInt8((raw >> 24) & 0xFF),
            ]
        case "ui16":
            guard rpm <= Double(UInt16.max) else {
                throw SMCDataCodecError.invalidNumericValue(rpm)
            }
            let raw = UInt16(rpm.rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        case "fpe2":
            let scaled = rpm * 4.0
            guard scaled <= Double(UInt16.max) else {
                throw SMCDataCodecError.invalidNumericValue(rpm)
            }
            let raw = UInt16(scaled.rounded())
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        default:
            throw SMCDataCodecError.unsupportedDataType(dataType)
        }
    }

    private static func decodeFloat(_ bytes: [UInt8], dataType: String) throws -> Double {
        try require(bytes, count: 4, dataType: dataType)
        let raw = UInt32(bytes[0]) |
                  UInt32(bytes[1]) << 8 |
                  UInt32(bytes[2]) << 16 |
                  UInt32(bytes[3]) << 24
        return Double(Float(bitPattern: raw))
    }

    private static func require(_ bytes: [UInt8], count: Int, dataType: String) throws {
        guard bytes.count >= count else {
            throw SMCDataCodecError.insufficientBytes(
                dataType: dataType,
                expected: count,
                actual: bytes.count
            )
        }
    }

    private static func normalized(_ dataType: String) -> String {
        dataType.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
