import AppKit
import Foundation
import Combine
import CryptoKit
import FanControlCore
import ServiceManagement

final class FanController: ObservableObject {

    // MARK: - Published State

    @Published var temperature: Double?   // CPU die aggregate with thermal-zone fallback

    @Published var fan0RPM: Double?
    @Published var fan1RPM: Double?

    @Published var fan0Target: Double = 0
    @Published var fan1Target: Double = 0

    @Published var isAutoMode: Bool = true
    @Published private(set) var fanCount: Int = 0

    @Published var profiles: [FanProfile] = []

    @Published var warningMessage: String?
    @Published var helperInstalled: Bool = false
    @Published var launchAtLogin: Bool = false

    // Fan RPM range (read once at launch)
    private(set) var fan0Min: Double = 0
    private(set) var fan0Max: Double = 0
    private(set) var fan1Min: Double = 0
    private(set) var fan1Max: Double = 0

    var hasFan0Control: Bool { fanCount > 0 && fan0Max > fan0Min }
    var hasFan1Control: Bool { fanCount > 1 && fan1Max > fan1Min }

    // MARK: - Private

    private let smc: SMCKit
    private let fallbackTemperatureCandidates: [String]
    private var primaryTemperatureKeys: [String]
    private var fallbackTemperatureKeys: [String]
    private let helperQueue = DispatchQueue(label: "FanControl.helper")
    private let installedHelperPath = FanHelperInstallation.executablePath
    private let sudoersPath = FanHelperInstallation.sudoersPath
    private lazy var helperSession = FanHelperSession(executablePath: installedHelperPath)
    private var wakeObserver: NSObjectProtocol?
    private var fanIntent = FanControlIntent()
    private var heartbeatQueued = false
    private var recoveryQueued = false
    private var recoveryRequested = false
    private let terminationLock = NSLock()
    private var terminationRequested = false

    // MARK: - Init

    init() {
        let smc = SMCKit()
        self.smc = smc

        let generation = AppleSiliconGeneration.current()
        let fallbackCandidates = TempKey.fallbackDieCandidates(for: generation)
        self.fallbackTemperatureCandidates = fallbackCandidates
        self.primaryTemperatureKeys = smc.resolveReadableKeys(TempKey.primaryDieCandidates)
        self.fallbackTemperatureKeys = smc.resolveReadableKeys(fallbackCandidates)

        loadFanLimits()
        loadProfiles()
        refreshHelperStatus()
        launchAtLogin = SMAppService.mainApp.status == .enabled

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    private func refreshHelperStatus() {
        let files = FileManager.default
        helperInstalled = files.fileExists(atPath: installedHelperPath) &&
                          files.fileExists(atPath: sudoersPath) &&
                          isRegularFile(atPath: helperPath) &&
                          files.contentsEqual(
                              atPath: installedHelperPath,
                              andPath: helperPath
                          ) &&
                          hasSecureOwnership(
                              atPath: installedHelperPath,
                              permissions: 0o755
                          ) &&
                          hasSecureOwnership(
                              atPath: sudoersPath,
                              permissions: 0o440
                          ) &&
                          verifyInstalledHelper()
    }

    private func isRegularFile(atPath path: String) -> Bool {
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func hasSecureOwnership(atPath path: String, permissions: Int) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let mode = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.intValue == 0 && mode.intValue == permissions
    }

    private func verifyInstalledHelper() -> Bool {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", installedHelperPath, "verify-install"]
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            return task.terminationStatus == 0 &&
                   output == FanHelperInstallation.verificationToken
        } catch {
            return false
        }
    }

    func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            warningMessage = "Login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Polling

    func refresh() {
        // Prefer the observed die aggregate; use physical-report thermal zones only
        // when the aggregate is absent or temporarily invalid.
        if let t = firstReading(from: primaryTemperatureKeys) ??
                   maxReading(from: fallbackTemperatureKeys) {
            temperature = t
        } else {
            resolveTemperatureKeys()
        }
        if fanCount > 0, let rpm = try? smc.readFanRPM(key: FanKey.actual(for: 0)) {
            fan0RPM = rpm
        }
        if fanCount > 1, let rpm = try? smc.readFanRPM(key: FanKey.actual(for: 1)) {
            fan1RPM = rpm
        } else {
            fan1RPM = nil
        }
        maintainHelperLease()
    }

    /// Returns the highest valid reading. Filters out deep-sleep garbage
    /// (zones that report < 10°C or > 150°C when idle).
    private func maxReading(from keys: [String]) -> Double? {
        var best: Double?
        for key in keys {
            guard let value = try? smc.readTemperature(key: key),
                  isPlausibleTemperature(value) else { continue }
            if best == nil || value > best! { best = value }
        }
        return best
    }

    private func firstReading(from keys: [String]) -> Double? {
        for key in keys {
            if let value = try? smc.readTemperature(key: key),
               isPlausibleTemperature(value) {
                return value
            }
        }
        return nil
    }

    private func isPlausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && value > 10 && value < 150
    }

    private func resolveTemperatureKeys() {
        primaryTemperatureKeys = smc.resolveReadableKeys(TempKey.primaryDieCandidates)
        fallbackTemperatureKeys = smc.resolveReadableKeys(fallbackTemperatureCandidates)
    }

    private func handleWake() {
        let manualTargets = fanIntent.manualTargets

        resolveTemperatureKeys()
        loadFanLimits(preserveTargets: true)
        helperQueue.async { [weak self] in
            try? self?.helperSession.shutdown()
        }

        for (fan, rpm) in manualTargets.sorted(by: { $0.key < $1.key }) {
            switch fan {
            case 0 where hasFan0Control && rpm >= fan0Min && rpm <= fan0Max:
                setFan0Speed(rpm)
            case 1 where hasFan1Control && rpm >= fan1Min && rpm <= fan1Max:
                setFan1Speed(rpm)
            default:
                fanIntent.cancelManual(fan: fan)
            }
        }
        syncAutomaticState()
    }

    // MARK: - Fan Control (via privileged helper)
    //
    // SMC writes require root on Apple Silicon. Installation prompts once;
    // control commands then use the root-owned helper's leased sudo session.

    private var helperPath: String {
        // FanHelper is built alongside FanControl in .build/release/. Resolve
        // the actual executable instead of trusting the caller-controlled argv[0].
        guard let executableURL = Bundle.main.executableURL else { return "" }
        return executableURL.resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .appendingPathComponent("FanHelper", isDirectory: false)
            .path
    }

    // MARK: - One-time Helper Installation

    /// Installs FanHelper in the root-owned helper directory and writes a
    /// validated sudoers NOPASSWD rule so
    /// subsequent fan writes require no password. Prompts for admin credentials once.
    func installHelper(completion: @escaping (Error?) -> Void) {
        let src = helperPath
        let dst = installedHelperPath
        let dstTemp = dst + ".new"
        let sudoers = sudoersPath
        let sudoersTemp = sudoers + ".new"
        let expectedDigest: String
        do {
            guard isRegularFile(atPath: src) else {
                throw NSError(
                    domain: "FanControl",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Bundled FanHelper is missing or invalid"]
                )
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: src))
            expectedDigest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        } catch {
            completion(error)
            return
        }

        let script = """
        on run argv
            set srcPath to item 1 of argv
            set dstPath to item 2 of argv
            set dstTemp to item 3 of argv
            set sudoersPath to item 4 of argv
            set sudoersTemp to item 5 of argv
            set sudoersRule to item 6 of argv
            set expectedDigest to item 7 of argv
            set installHelper to "/usr/bin/install -o root -g wheel -m 755 " & quoted form of srcPath
            set installHelper to installHelper & " " & quoted form of dstTemp
            set hashManifest to expectedDigest & "  " & dstTemp
            set verifyHelper to "/bin/echo " & quoted form of hashManifest & " | /usr/bin/shasum -a 256 -c -"
            set writeRule to "/bin/echo " & quoted form of sudoersRule & " > " & quoted form of sudoersTemp
            set secureRule to "/usr/sbin/chown root:wheel " & quoted form of sudoersTemp
            set secureRule to secureRule & " && /bin/chmod 440 " & quoted form of sudoersTemp
            set validateRule to "/usr/sbin/visudo -cf " & quoted form of sudoersTemp
            set installRule to "/usr/bin/install -o root -g wheel -m 440 " & quoted form of sudoersTemp
            set installRule to installRule & " " & quoted form of sudoersPath
            set publishHelper to "/bin/mv -f " & quoted form of dstTemp & " " & quoted form of dstPath
            set removeTemp to "/bin/rm -f " & quoted form of sudoersTemp
            set removeLegacy to "/bin/rm -f /usr/local/bin/FanHelper"
            set cleanup to "/bin/rm -f " & quoted form of dstTemp & " " & quoted form of sudoersTemp
            set installAll to installHelper & " && " & verifyHelper & " && " & writeRule
            set installAll to installAll & " && " & secureRule & " && " & validateRule
            set installAll to installAll & " && " & installRule & " && " & publishHelper
            set installAll to installAll & " && " & removeTemp & " && " & removeLegacy
            set commandText to "( " & installAll & " ); status=$?; " & cleanup & "; exit $status"
            do shell script commandText with administrator privileges
        end run
        """

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = [
                "-e", script, "--", src, dst, dstTemp, sudoers, sudoersTemp,
                FanHelperInstallation.sudoersRule, expectedDigest,
            ]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    if task.terminationStatus == 0 {
                        self.refreshHelperStatus()
                        if self.helperInstalled {
                            completion(nil)
                        } else {
                            completion(NSError(
                                domain: "FanControl",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "Installed helper failed ownership or sudoers validation"]
                            ))
                        }
                    } else {
                        completion(NSError(
                            domain: "FanControl", code: Int(task.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey:
                                output.trimmingCharacters(in: .whitespacesAndNewlines)]))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    func setFan0Speed(_ rpm: Double) {
        let label = fanCount == 1 ? "Fan" : "Left"
        guard hasFan0Control, rpm.isFinite, rpm >= fan0Min, rpm <= fan0Max else {
            warningMessage = "\(label): RPM is outside this fan's reported range"
            return
        }
        let revision = fanIntent.requestManual(fan: 0, rpm: rpm)
        fan0Target = rpm
        syncAutomaticState()
        runHelper(
            arguments: ["set-fan", "0", "\(rpm)"],
            label: label,
            onFailure: { [weak self] in
                self?.manualRequestFailed(fan: 0, revision: revision)
            }
        ) { [weak self] in
            self?.fanIntent.manualRequestSucceeded(
                fan: 0,
                rpm: rpm,
                revision: revision
            )
        }
    }

    func setFan1Speed(_ rpm: Double) {
        guard hasFan1Control, rpm.isFinite, rpm >= fan1Min, rpm <= fan1Max else {
            warningMessage = "Right: fan is unavailable or RPM is outside its reported range"
            return
        }
        let revision = fanIntent.requestManual(fan: 1, rpm: rpm)
        fan1Target = rpm
        syncAutomaticState()
        runHelper(
            arguments: ["set-fan", "1", "\(rpm)"],
            label: "Right",
            onFailure: { [weak self] in
                self?.manualRequestFailed(fan: 1, revision: revision)
            }
        ) { [weak self] in
            self?.fanIntent.manualRequestSucceeded(
                fan: 1,
                rpm: rpm,
                revision: revision
            )
        }
    }

    func resetToAutomatic() {
        fanIntent.requestAutomatic()
        if hasFan0Control { fan0Target = fan0Min }
        if hasFan1Control { fan1Target = fan1Min }
        syncAutomaticState()
        runHelper(arguments: ["auto"], label: "Auto") {}
    }

    /// Synchronous fan reset called on app quit. No-op (and no password prompt)
    /// if the NOPASSWD helper isn't installed yet.
    func resetToAutomaticOnQuit() {
        requestTermination()
        fanIntent.requestAutomatic()
        recoveryQueued = false
        recoveryRequested = false
        guard helperInstalled else { return }
        let finished = DispatchSemaphore(value: 0)
        helperQueue.async { [weak self] in
            guard let self else {
                finished.signal()
                return
            }
            try? helperSession.shutdown()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + 5)
    }

    private func runHelper(
        arguments: [String],
        label: String,
        onFailure: @escaping () -> Void = {},
        onSuccess: @escaping () -> Void
    ) {
        guard helperInstalled else {
            warningMessage = "\(label): helper not set up — relaunch the app"
            onFailure()
            return
        }

        helperQueue.async { [weak self] in
            guard let self, !self.isTerminationRequested else { return }
            do {
                let result = try self.helperSession.run(arguments: arguments)

                DispatchQueue.main.async {
                    guard !self.isTerminationRequested else { return }
                    onSuccess()
                    self.warningMessage = nil
                    if result.recoveredSession {
                        self.reapplyDesiredManualControl()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isTerminationRequested else { return }
                    onFailure()
                    self.warningMessage = "\(label): \(error.localizedDescription)"
                    self.reapplyDesiredManualControl()
                }
            }
        }
    }

    private func manualRequestFailed(fan: Int, revision: UInt64) {
        fanIntent.manualRequestFailed(fan: fan, revision: revision)
        if let restoredTarget = fanIntent.manualTargets[fan] {
            if fan == 0 { fan0Target = restoredTarget }
            if fan == 1 { fan1Target = restoredTarget }
        } else {
            if fan == 0 { fan0Target = fan0Min }
            if fan == 1 { fan1Target = fan1Min }
        }
        syncAutomaticState()
    }

    private func syncAutomaticState() {
        isAutoMode = fanIntent.isAutomatic
    }

    private func maintainHelperLease() {
        guard !fanIntent.isAutomatic,
              helperInstalled,
              !heartbeatQueued,
              !recoveryQueued else { return }
        heartbeatQueued = true

        helperQueue.async { [weak self] in
            guard let self, !self.isTerminationRequested else { return }
            do {
                try self.helperSession.heartbeat()
                DispatchQueue.main.async {
                    guard !self.isTerminationRequested else { return }
                    self.heartbeatQueued = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard !self.isTerminationRequested else { return }
                    self.heartbeatQueued = false
                    self.warningMessage = "Helper lease: \(error.localizedDescription)"
                    self.reapplyDesiredManualControl()
                }
            }
        }
    }

    private func reapplyDesiredManualControl() {
        guard !fanIntent.isAutomatic else { return }
        if recoveryQueued {
            recoveryRequested = true
            return
        }
        recoveryQueued = true
        recoveryRequested = false
        helperQueue.async { [weak self] in
            guard let self, !self.isTerminationRequested else { return }
            // This queue marker runs after already-submitted helper commands.
            // Their main-queue callbacks are therefore ordered before the snapshot.
            DispatchQueue.main.async {
                guard !self.isTerminationRequested else { return }
                self.startManualRecovery()
            }
        }
    }

    private func startManualRecovery() {
        guard !isTerminationRequested, recoveryQueued, !fanIntent.isAutomatic else {
            recoveryQueued = false
            recoveryRequested = false
            return
        }

        let snapshot = ManualRecoverySnapshot(
            generation: fanIntent.generation,
            targets: fanIntent.manualTargets
                .filter { fan, _ in
                    (fan == 0 && hasFan0Control) ||
                    (fan == 1 && hasFan1Control)
                }
                .sorted(by: { $0.key < $1.key })
                .map { ($0.key, $0.value) }
        )
        guard !snapshot.targets.isEmpty else {
            recoveryQueued = false
            recoveryRequested = false
            return
        }

        helperQueue.async { [weak self] in
            guard let self, !self.isTerminationRequested else { return }

            var recoveryError: Error?
            do {
                try self.applyRecoveryTargets(snapshot.targets)
            } catch ManualRecoveryError.terminationRequested {
                return
            } catch {
                recoveryError = error
            }

            DispatchQueue.main.async {
                guard !self.isTerminationRequested else { return }
                let pendingRecovery = self.recoveryRequested
                self.recoveryQueued = false
                self.recoveryRequested = false

                let stateChanged = self.fanIntent.generation != snapshot.generation ||
                    self.fanIntent.manualTargets != Dictionary(
                        uniqueKeysWithValues: snapshot.targets
                    )

                if (stateChanged || pendingRecovery), !self.fanIntent.isAutomatic {
                    if let recoveryError {
                        self.warningMessage =
                            "Manual recovery retry: \(recoveryError.localizedDescription)"
                    }
                    // Coalesce commands that changed intent or requested recovery
                    // while this pass was active. Unchanged recovery failures still
                    // take the fail-closed path below instead of retrying recursively.
                    self.reapplyDesiredManualControl()
                    return
                }

                guard let recoveryError else { return }

                if !stateChanged {
                    self.fanIntent.requestAutomatic()
                    if self.hasFan0Control { self.fan0Target = self.fan0Min }
                    if self.hasFan1Control { self.fan1Target = self.fan1Min }
                    self.syncAutomaticState()
                }
                self.warningMessage =
                    "Manual recovery stopped: \(recoveryError.localizedDescription)"
            }
        }
    }

    private func applyRecoveryTargets(_ targets: [(Int, Double)]) throws {
        for _ in 0..<3 {
            guard !isTerminationRequested else {
                throw ManualRecoveryError.terminationRequested
            }
            var restarted = false
            for (fan, rpm) in targets {
                guard !isTerminationRequested else {
                    throw ManualRecoveryError.terminationRequested
                }
                let result = try helperSession.run(
                    arguments: ["set-fan", "\(fan)", "\(rpm)"]
                )
                if result.recoveredSession {
                    restarted = true
                    break
                }
            }
            if !restarted { return }
        }

        _ = try helperSession.run(arguments: ["auto"])
        throw ManualRecoveryError.unstableSession
    }

    private func requestTermination() {
        terminationLock.lock()
        terminationRequested = true
        terminationLock.unlock()
    }

    private var isTerminationRequested: Bool {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        return terminationRequested
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
        if hasFan0Control { setFan0Speed(profile.fan0MinRPM) }
        if hasFan1Control { setFan1Speed(profile.fan1MinRPM) }
    }

    func deleteProfile(_ profile: FanProfile) {
        profiles.removeAll { $0.id == profile.id }
        persistProfiles()
    }

    // MARK: - Private Helpers

    private func loadFanLimits(preserveTargets: Bool = false) {
        fanCount = 0
        fan0Min = 0
        fan0Max = 0
        fan1Min = 0
        fan1Max = 0

        guard let count = try? smc.readUInt8(key: FanKey.count),
              (1...2).contains(count) else {
            warningMessage = "No controllable fans were reported by the SMC"
            return
        }
        fanCount = Int(count)

        if let minimum = try? smc.readFanRPM(key: FanKey.minimum(for: 0)),
           let maximum = try? smc.readFanRPM(key: FanKey.maximum(for: 0)),
           minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum {
            fan0Min = minimum
            fan0Max = maximum
            if !preserveTargets { fan0Target = minimum }
        }

        if fanCount > 1,
           let minimum = try? smc.readFanRPM(key: FanKey.minimum(for: 1)),
           let maximum = try? smc.readFanRPM(key: FanKey.maximum(for: 1)),
           minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum {
            fan1Min = minimum
            fan1Max = maximum
            if !preserveTargets { fan1Target = minimum }
        }

        if !hasFan0Control || (fanCount > 1 && !hasFan1Control) {
            warningMessage = "Fan limits are unavailable; manual controls are disabled"
        }
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

private struct ManualRecoverySnapshot {
    let generation: UInt64
    let targets: [(Int, Double)]
}

private enum ManualRecoveryError: Error, LocalizedError {
    case unstableSession
    case terminationRequested

    var errorDescription: String? {
        switch self {
        case .unstableSession:
            return "Fan helper restarted repeatedly; automatic control was restored"
        case .terminationRequested:
            return "Fan helper recovery was cancelled during app termination"
        }
    }
}
