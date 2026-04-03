import Testing

// SMCKit's encode/decode logic is private, so we test the algorithms here by
// replicating them exactly. No SMC hardware is required.

@Suite("SMC FPE2 Decoding")
struct FPE2Tests {

    @Test func decodeZero() {
        #expect(decodeFPE2(0x00, 0x00) == 0.0)
    }

    @Test func decode1000RPM() {
        // 1000 × 4 = 4000 = 0x0FA0
        #expect(decodeFPE2(0x0F, 0xA0) == 1000.0)
    }

    @Test func decode2500RPM() {
        // 2500 × 4 = 10000 = 0x2710
        #expect(decodeFPE2(0x27, 0x10) == 2500.0)
    }

    @Test func decode6500RPM() {
        // 6500 × 4 = 26000 = 0x6590
        #expect(decodeFPE2(0x65, 0x90) == 6500.0)
    }

    @Test(arguments: [1000.0, 1500.0, 2000.0, 3000.0, 4500.0, 6000.0, 6500.0])
    func roundTrip(rpm: Double) {
        let encoded = encodeFPE2(rpm)
        let decoded = decodeFPE2(encoded[0], encoded[1])
        // FPE2 has 0.25 RPM resolution
        #expect(abs(decoded - rpm) <= 0.25)
    }

    @Test func negativeRPMClampedToZero() {
        let bytes = encodeFPE2(-100)
        #expect(decodeFPE2(bytes[0], bytes[1]) == 0.0)
    }
}

@Suite("SMC SP78 Decoding")
struct SP78Tests {

    @Test func decodeZero() {
        #expect(decodeSP78(0x00, 0x00) == 0.0)
    }

    @Test func decode25C() {
        // 25°C → 25 × 256 = 6400 = 0x1900
        #expect(decodeSP78(0x19, 0x00) == 25.0)
    }

    @Test func decode100C() {
        // 100°C → 100 × 256 = 25600 = 0x6400
        #expect(decodeSP78(0x64, 0x00) == 100.0)
    }

    @Test func decodeFractional() {
        // 25.5°C → 25.5 × 256 = 6528 = 0x1980
        #expect(abs(decodeSP78(0x19, 0x80) - 25.5) < 0.01)
    }

    @Test func decodeNegative() {
        // -1°C → raw = 0xFF00 as UInt16, Int16(bitPattern:) = -256 → /256 = -1
        #expect(decodeSP78(0xFF, 0x00) == -1.0)
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

// MARK: - Algorithm copies (mirrors private SMCKit implementations)

private func decodeFPE2(_ high: UInt8, _ low: UInt8) -> Double {
    Double(UInt16(high) << 8 | UInt16(low)) / 4.0
}

private func encodeFPE2(_ rpm: Double) -> [UInt8] {
    let raw = UInt16(max(0, rpm) * 4.0)
    return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
}

private func decodeSP78(_ high: UInt8, _ low: UInt8) -> Double {
    let raw = UInt16(high) << 8 | UInt16(low)
    return Double(Int16(bitPattern: raw)) / 256.0
}

private func fourCharCode(_ string: String) -> UInt32 {
    string.unicodeScalars.prefix(4).enumerated().reduce(0) { acc, pair in
        acc | (UInt32(pair.element.value) << UInt32((3 - pair.offset) * 8))
    }
}
