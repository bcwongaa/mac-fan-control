import Testing
@testable import FanControlCore

@Suite("Apple Silicon hardware support")
struct HardwareSupportTests {

    @Test func chipNamesMapToTheirGeneration() {
        let cases: [(String, AppleSiliconGeneration)] = [
            ("Apple M1 Pro", .m1),
            ("Apple M1 Max", .m1),
            ("Apple M2", .m2),
            ("Apple M2 Pro", .m2),
            ("Apple M2 Max", .m2),
            ("Apple M3", .m3),
            ("Apple M3 Pro", .m3),
            ("Apple M3 Max", .m3),
            ("Apple M4", .m4),
            ("Apple M4 Pro", .m4),
            ("Apple M4 Max", .m4),
            ("Apple M5", .m5),
            ("Apple M5 Pro", .m5),
            ("Apple M5 Max", .m5),
        ]

        for (chipName, expected) in cases {
            #expect(AppleSiliconGeneration(chipName: chipName) == expected)
        }
    }

    @Test func unknownChipNamesDoNotGuessAGeneration() {
        for chipName in ["", "Intel(R) Core(TM) i9", "Apple M6 Pro", "M5-like"] {
            #expect(AppleSiliconGeneration(chipName: chipName) == .unknown)
        }
    }

    @Test func eachGenerationHasAValidDieTemperatureCatalog() {
        let representativeKeys: [(AppleSiliconGeneration, [String])] = [
            (.m1, ["TCMz", "TCMb", "Tp0A", "Tg0T"]),
            (.m2, ["TCMz", "TCMb", "Te06", "Tp0s", "Tg0r"]),
            (.m3, ["TCMz", "TCMb", "Te0U", "Tp1S", "Tg3y"]),
            (.m4, ["TCMz", "TCMb", "Tp1k", "Tp02", "Tg3q"]),
            (.m5, ["TCMz", "TCMb", "Tp0y", "Tg43"]),
        ]

        for (generation, expectedKeys) in representativeKeys {
            let keys = TempKey.dieCandidates(for: generation)
            #expect(keys.count > 10)
            #expect(Set(keys).count == keys.count)
            #expect(keys.allSatisfy { $0.utf8.count == 4 })
            #expect(keys.allSatisfy { $0.first == "T" })
            #expect(expectedKeys.allSatisfy(keys.contains))
        }
    }

    @Test func catalogsAvoidKnownMisidentifiedOrAbsentKeys() {
        let m2 = TempKey.dieCandidates(for: .m2)
        let m3 = TempKey.dieCandidates(for: .m3)
        let m5 = TempKey.dieCandidates(for: .m5)

        #expect(!m2.contains("Tp1h"))
        #expect(!m3.contains { $0.hasPrefix("Tf") })
        #expect(!m5.contains("Tg1g"))
    }

    @Test func primaryTemperatureKeysPreferMaxThenUniversalAggregate() {
        #expect(TempKey.primaryDieCandidates == ["TCMz", "TCMb"])
    }

    @Test func unknownGenerationUsesTheFullKnownCatalog() {
        #expect(TempKey.dieCandidates(for: .unknown) == TempKey.allKnownDieCandidates)
        #expect(Set(TempKey.allKnownDieCandidates).count == TempKey.allKnownDieCandidates.count)
    }

    @Test func modeCandidatesCoverBothObservedCasings() {
        #expect(FanKey.modeCandidates(for: 0) == ["F0md", "F0Md"])
        #expect(FanKey.modeCandidates(for: 1) == ["F1md", "F1Md"])
    }

    @Test func privilegedHelperUsesTheRootOwnedSystemLocation() {
        #expect(FanHelperInstallation.executablePath.hasPrefix(
            "/Library/PrivilegedHelperTools/"
        ))
        #expect(FanHelperInstallation.sudoersRule.contains(
            FanHelperInstallation.executablePath + " serve"
        ))
        #expect(FanHelperInstallation.sudoersRule.contains(
            FanHelperInstallation.executablePath + " verify-install"
        ))
    }
}
