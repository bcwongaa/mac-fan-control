import Testing
@testable import FanControlCore

// No SMC hardware is required; these tests exercise the shared production codec.

@Suite("SMC FPE2 Decoding")
struct FPE2Tests {

    @Test func decodeZero() throws {
        #expect(try SMCDataCodec.decodeFanRPM([0x00, 0x00], dataType: "fpe2") == 0.0)
    }

    @Test func decode1000RPM() throws {
        // 1000 × 4 = 4000 = 0x0FA0
        #expect(try SMCDataCodec.decodeFanRPM([0x0F, 0xA0], dataType: "fpe2") == 1000.0)
    }

    @Test func decode2500RPM() throws {
        // 2500 × 4 = 10000 = 0x2710
        #expect(try SMCDataCodec.decodeFanRPM([0x27, 0x10], dataType: "fpe2") == 2500.0)
    }

    @Test func decode6500RPM() throws {
        // 6500 × 4 = 26000 = 0x6590
        #expect(try SMCDataCodec.decodeFanRPM([0x65, 0x90], dataType: "fpe2") == 6500.0)
    }

    @Test(arguments: [1000.0, 1500.0, 2000.0, 3000.0, 4500.0, 6000.0, 6500.0])
    func roundTrip(rpm: Double) throws {
        let encoded = try SMCDataCodec.encodeFanRPM(rpm, dataType: "fpe2")
        let decoded = try SMCDataCodec.decodeFanRPM(encoded, dataType: "fpe2")
        // FPE2 has 0.25 RPM resolution
        #expect(abs(decoded - rpm) <= 0.25)
    }

    @Test func negativeRPMIsRejected() {
        #expect(throws: SMCDataCodecError.self) {
            _ = try SMCDataCodec.encodeFanRPM(-100, dataType: "fpe2")
        }
    }
}

@Suite("SMC SP78 Decoding")
struct SP78Tests {

    @Test func decodeZero() throws {
        #expect(try SMCDataCodec.decodeTemperature([0x00, 0x00], dataType: "sp78") == 0.0)
    }

    @Test func decode25C() throws {
        // 25°C → 25 × 256 = 6400 = 0x1900
        #expect(try SMCDataCodec.decodeTemperature([0x19, 0x00], dataType: "sp78") == 25.0)
    }

    @Test func decode100C() throws {
        // 100°C → 100 × 256 = 25600 = 0x6400
        #expect(try SMCDataCodec.decodeTemperature([0x64, 0x00], dataType: "sp78") == 100.0)
    }

    @Test func decodeFractional() throws {
        // 25.5°C → 25.5 × 256 = 6528 = 0x1980
        let value = try SMCDataCodec.decodeTemperature([0x19, 0x80], dataType: "sp78")
        #expect(abs(value - 25.5) < 0.01)
    }

    @Test func decodeNegative() throws {
        // -1°C → raw = 0xFF00 as UInt16, Int16(bitPattern:) = -256 → /256 = -1
        #expect(try SMCDataCodec.decodeTemperature([0xFF, 0x00], dataType: "sp78") == -1.0)
    }
}

@Suite("SMC UInt8 Decoding")
struct UInt8Tests {
    @Test func acceptsPaddedUi8Type() throws {
        #expect(try SMCDataCodec.decodeUInt8([2], dataType: "ui8 ") == 2)
    }

    @Test func rejectsWrongType() {
        #expect(throws: SMCDataCodecError.self) {
            _ = try SMCDataCodec.decodeUInt8([2], dataType: "flt ")
        }
    }
}

@Suite("SMC FourCharCode")
struct FourCharCodeTests {

    @Test func fanActualKey() {
        // "F0Ac" → 0x46_30_41_63
        #expect(fourCharCode("F0Ac") == 0x46304163)
    }

    @Test func tempKey() {
        // "TC0P" → 0x54_43_30_50
        #expect(fourCharCode("TC0P") == 0x54433050)
    }

    @Test func allKeyCodesAreUnique() {
        let keys = ["F0Ac", "F0Mn", "F1Ac", "F1Mn", "TC0P", "TG0P", "FNum"]
        let codes = keys.map { fourCharCode($0) }
        #expect(Set(codes).count == keys.count)
    }
}

private func fourCharCode(_ string: String) -> UInt32 {
    string.unicodeScalars.prefix(4).enumerated().reduce(0) { acc, pair in
        acc | (UInt32(pair.element.value) << UInt32((3 - pair.offset) * 8))
    }
}
