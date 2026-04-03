import Foundation
import Testing
@testable import FanControlKit

@Suite("FanProfile")
struct FanProfileTests {

    @Test func initSetsFields() {
        let p = FanProfile(name: "Silent", fan0MinRPM: 1200, fan1MinRPM: 1200)
        #expect(p.name == "Silent")
        #expect(p.fan0MinRPM == 1200)
        #expect(p.fan1MinRPM == 1200)
    }

    @Test func jsonRoundTrip() throws {
        let original = FanProfile(name: "Performance", fan0MinRPM: 3000, fan1MinRPM: 3500)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.name == original.name)
        #expect(decoded.fan0MinRPM == original.fan0MinRPM)
        #expect(decoded.fan1MinRPM == original.fan1MinRPM)
    }

    @Test func jsonArrayRoundTrip() throws {
        let profiles = [
            FanProfile(name: "Silent",      fan0MinRPM: 1000, fan1MinRPM: 1000),
            FanProfile(name: "Balanced",    fan0MinRPM: 2000, fan1MinRPM: 2000),
            FanProfile(name: "Performance", fan0MinRPM: 4000, fan1MinRPM: 4000),
        ]
        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([FanProfile].self, from: data)

        #expect(decoded.count == 3)
        for (orig, dec) in zip(profiles, decoded) {
            #expect(orig.id == dec.id)
            #expect(orig.name == dec.name)
        }
    }

    @Test func idsAreUnique() {
        let p1 = FanProfile(name: "A", fan0MinRPM: 1000, fan1MinRPM: 1000)
        let p2 = FanProfile(name: "B", fan0MinRPM: 2000, fan1MinRPM: 2000)
        #expect(p1.id != p2.id)
    }
}
