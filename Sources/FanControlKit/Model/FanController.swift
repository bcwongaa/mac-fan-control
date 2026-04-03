import AppKit
import Foundation
import Combine

final class FanController: ObservableObject {

    // MARK: - Published State

    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?

    @Published var fan0RPM: Double?
    @Published var fan1RPM: Double?

    @Published var fan0Target: Double = 0
    @Published var fan1Target: Double = 0

    @Published var isAutoMode: Bool = true

    @Published var profiles: [FanProfile] = []

    @Published var warningMessage: String?

    // Fan RPM range (read once at launch)
    private(set) var fan0Min: Double = 0
    private(set) var fan0Max: Double = 6500
    private(set) var fan1Min: Double = 0
    private(set) var fan1Max: Double = 6500

    // MARK: - Private

    private let smc = SMCKit()

    // MARK: - Init

    init() {
        loadFanLimits()
        loadProfiles()
    }

    // MARK: - Polling

    func refresh() {
        // CPU — max across all cores, filtering out sleep-state garbage (< 10°C)
        cpuTemperature = maxReading(from: TempKey.cpuPerfAll + TempKey.cpuEffAll
                                        + [TempKey.cpuDie, TempKey.cpuProximity])

        gpuTemperature = maxReading(from: TempKey.gpuAll
                                        + [TempKey.gpuDie, TempKey.gpuProximity])

        fan0RPM = try? smc.readFanRPM(key: FanKey.fan0Actual)
        fan1RPM = try? smc.readFanRPM(key: FanKey.fan1Actual)
    }

    /// Returns the highest valid reading. Filters out deep-sleep garbage
    /// (cores that report < 10°C or > 130°C when idle).
    private func maxReading(from keys: [String]) -> Double? {
        var best: Double?
        for key in keys {
            guard let value = try? smc.readTemperature(key: key),
                  value > 10, value < 130 else { continue }
            if best == nil || value > best! { best = value }
        }
        return best
    }

    // MARK: - Fan Control (via privileged helper)
    //
    // SMC writes require root on Apple Silicon. The main app calls FanHelper
    // via osascript "do shell script ... with administrator privileges" which
    // prompts for the admin password once.

    private var helperPath: String {
        // FanHelper is built alongside FanControl in .build/release/
        let selfPath = ProcessInfo.processInfo.arguments[0]
        let dir = (selfPath as NSString).deletingLastPathComponent
        return dir + "/FanHelper"
    }

    func setFan0Speed(_ rpm: Double) {
        runHelper(args: "set-fan 0 \(rpm)", label: "Left") { [weak self] in
            self?.fan0Target = rpm
            self?.isAutoMode = false
        }
    }

    func setFan1Speed(_ rpm: Double) {
        runHelper(args: "set-fan 1 \(rpm)", label: "Right") { [weak self] in
            self?.fan1Target = rpm
            self?.isAutoMode = false
        }
    }

    func resetToAutomatic() {
        runHelper(args: "auto", label: "Auto") { [weak self] in
            guard let self else { return }
            self.fan0Target = self.fan0Min
            self.fan1Target = self.fan1Min
            self.isAutoMode = true
        }
    }

    private func runHelper(args: String, label: String, onSuccess: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let path = self.helperPath
            // Use osascript to prompt for admin password and run with sudo
            let script = "do shell script \"\(path) \(args)\" with administrator privileges"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
                task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    if task.terminationStatus == 0 {
                        onSuccess()
                        self.warningMessage = nil
                    } else {
                        self.warningMessage = "\(label): \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.warningMessage = "\(label): \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Debug

    func copySmcDump() {
        let dump = smc.dumpAllKeys()
        // Write to file and clipboard
        let path = NSHomeDirectory() + "/Desktop/smc-dump.txt"
        try? dump.write(toFile: path, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dump, forType: .string)
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
