import Foundation
import Combine

/// All mutations happen on the main thread; @Published properties drive SwiftUI.
final class FanController: ObservableObject {

    // MARK: - Published State

    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?

    @Published var fan0RPM: Double?     // left fan actual
    @Published var fan1RPM: Double?     // right fan actual

    @Published var fan0Target: Double = 0
    @Published var fan1Target: Double = 0

    /// True when we haven't successfully written a custom speed yet.
    @Published var isAutoMode: Bool = true

    @Published var profiles: [FanProfile] = []

    /// Non-fatal warning surfaced in the UI (e.g. Apple Silicon write restriction).
    @Published var warningMessage: String?

    // Fan RPM range (read once at launch from SMC)
    private(set) var fan0Min: Double = 1000
    private(set) var fan0Max: Double = 6500
    private(set) var fan1Min: Double = 1000
    private(set) var fan1Max: Double = 6500

    // MARK: - Private

    private let smc = SMCKit()

    // MARK: - Init

    init() {
        loadFanLimits()
        loadProfiles()
    }

    // MARK: - Polling

    /// Call on the main thread every ~3 s to refresh readings.
    func refresh() {
        // CPU temperature — try die first, fall back to proximity
        cpuTemperature = (try? smc.readTemperature(key: TempKey.cpuDie))
                      ?? (try? smc.readTemperature(key: TempKey.cpuProximity))

        // GPU temperature
        gpuTemperature = (try? smc.readTemperature(key: TempKey.gpuDie))
                      ?? (try? smc.readTemperature(key: TempKey.gpuProximity))

        // Fan RPMs
        fan0RPM = try? smc.readFanRPM(key: FanKey.fan0Actual)
        fan1RPM = try? smc.readFanRPM(key: FanKey.fan1Actual)
    }

    // MARK: - Fan Control

    func setFan0Speed(_ rpm: Double) {
        do {
            try smc.writeFanRPM(key: FanKey.fan0Min, rpm: rpm)
            fan0Target = rpm
            isAutoMode = false
            warningMessage = nil
        } catch SMCError.writeNotPermitted {
            warningMessage = "Left fan write blocked — Apple Silicon may not allow direct SMC writes on this model."
        } catch {
            warningMessage = "Left fan write failed: \(error.localizedDescription)"
        }
    }

    func setFan1Speed(_ rpm: Double) {
        do {
            try smc.writeFanRPM(key: FanKey.fan1Min, rpm: rpm)
            fan1Target = rpm
            isAutoMode = false
            warningMessage = nil
        } catch SMCError.writeNotPermitted {
            warningMessage = "Right fan write blocked — Apple Silicon may not allow direct SMC writes on this model."
        } catch {
            warningMessage = "Right fan write failed: \(error.localizedDescription)"
        }
    }

    /// Restore original minimum floor so SMC regains full authority.
    func resetToAutomatic() {
        _ = try? smc.writeFanRPM(key: FanKey.fan0Min, rpm: fan0Min)
        _ = try? smc.writeFanRPM(key: FanKey.fan1Min, rpm: fan1Min)
        fan0Target = fan0Min
        fan1Target = fan1Min
        isAutoMode = true
        warningMessage = nil
    }

    // MARK: - Profiles

    func saveProfile(name: String) {
        let profile = FanProfile(name: name, fan0MinRPM: fan0Target, fan1MinRPM: fan1Target)
        profiles.removeAll { $0.name == name }
        profiles.append(profile)
        persistProfiles()
    }

    func loadProfile(_ profile: FanProfile) {
        setFan0Speed(profile.fan0MinRPM)
        setFan1Speed(profile.fan1MinRPM)
        fan0Target = profile.fan0MinRPM
        fan1Target = profile.fan1MinRPM
    }

    func deleteProfile(_ profile: FanProfile) {
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
    }

    // MARK: - Private Helpers

    private func loadFanLimits() {
        if let v = try? smc.readFanRPM(key: FanKey.fan0Min) { fan0Min = v }
        if let v = try? smc.readFanRPM(key: FanKey.fan0Max) { fan0Max = v }
        if let v = try? smc.readFanRPM(key: FanKey.fan1Min) { fan1Min = v }
        if let v = try? smc.readFanRPM(key: FanKey.fan1Max) { fan1Max = v }
        fan0Target = fan0Min
        fan1Target = fan1Min
    }

    private var profilesFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }

    private func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesFileURL),
              let saved = try? JSONDecoder().decode([FanProfile].self, from: data)
        else { return }
        profiles = saved
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: profilesFileURL, options: .atomic)
    }
}
