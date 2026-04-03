import Foundation

struct FanProfile: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var fan0MinRPM: Double  // left fan minimum floor
    var fan1MinRPM: Double  // right fan minimum floor

    init(name: String, fan0MinRPM: Double, fan1MinRPM: Double) {
        self.id         = UUID()
        self.name       = name
        self.fan0MinRPM = fan0MinRPM
        self.fan1MinRPM = fan1MinRPM
    }
}
