import Foundation

public struct SMCValue: Equatable, Sendable {
    public let dataType: String
    public let bytes: [UInt8]

    public init(dataType: String, bytes: [UInt8]) {
        self.dataType = dataType
        self.bytes = bytes
    }
}

public struct SMCKeyUnavailableError: Error, LocalizedError, Sendable {
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public var errorDescription: String? {
        "SMC key '\(key)' is unavailable"
    }
}

public protocol FanSMCClient: AnyObject {
    func read(_ key: String) throws -> SMCValue
    func write(_ key: String, bytes: [UInt8]) throws
}

public struct FanControlTiming: Sendable {
    public let settleDelay: TimeInterval
    public let retryDelay: TimeInterval
    public let maxAttempts: Int
    public let modeVerificationDelay: TimeInterval
    public let directResponseAttempts: Int

    public init(
        settleDelay: TimeInterval = 0.5,
        retryDelay: TimeInterval = 0.1,
        maxAttempts: Int = 100,
        modeVerificationDelay: TimeInterval = 0.1,
        directResponseAttempts: Int = 10
    ) {
        self.settleDelay = settleDelay
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
        self.modeVerificationDelay = modeVerificationDelay
        self.directResponseAttempts = directResponseAttempts
    }
}

public enum FanCommandError: Error, LocalizedError {
    case usage
    case invalidFanCount(Int)
    case invalidFan(Int, fanCount: Int)
    case invalidRPM(String)
    case rpmOutsideRange(Double, minimum: Double, maximum: Double)
    case missingModeKey(Int)
    case manualModeFailed(Int, details: String)
    case controlVerificationFailed(Int, details: String)
    case automaticResetFailed([String])

    public var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: FanHelper set-fan <fan> <rpm> | auto"
        case let .invalidFanCount(count):
            return "SMC reported an invalid fan count: \(count)"
        case let .invalidFan(fan, fanCount):
            return "Fan \(fan) is invalid; this Mac reports \(fanCount) fan(s)"
        case let .invalidRPM(value):
            return "Invalid fan RPM: \(value)"
        case let .rpmOutsideRange(rpm, minimum, maximum):
            return "Fan RPM \(rpm) is outside the reported range \(minimum)...\(maximum)"
        case let .missingModeKey(fan):
            return "No fan-mode SMC key found for fan \(fan)"
        case let .manualModeFailed(fan, details):
            return "Failed to enable manual mode for fan \(fan): \(details)"
        case let .controlVerificationFailed(fan, details):
            return "Failed to verify manual control for fan \(fan): \(details)"
        case let .automaticResetFailed(details):
            return "Failed to restore automatic fan control: \(details.joined(separator: "; "))"
        }
    }
}

public final class FanCommandRunner {
    private static let maximumSupportedFanCount = 8
    private static let targetTolerance = 1.0

    private let client: FanSMCClient
    private let timing: FanControlTiming
    private let sleep: (TimeInterval) -> Void
    private var manualFans: Set<Int> = []
    private var manualModeKeys: [Int: String] = [:]
    private var ownsForceTest = false

    public init(
        client: FanSMCClient,
        timing: FanControlTiming = FanControlTiming(),
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) {
        self.client = client
        self.timing = timing
        self.sleep = sleep
    }

    public func run(arguments: [String]) throws -> String {
        guard let command = arguments.first else { throw FanCommandError.usage }

        switch command {
        case "set-fan":
            guard arguments.count == 3,
                  let fan = Int(arguments[1]),
                  let rpm = Double(arguments[2]) else {
                throw FanCommandError.usage
            }
            return try setFan(fan, rpm: rpm, rawRPM: arguments[2])
        case "auto":
            guard arguments.count == 1 else { throw FanCommandError.usage }
            return try restoreAutomaticControl()
        default:
            throw FanCommandError.usage
        }
    }

    private func setFan(_ fan: Int, rpm: Double, rawRPM: String) throws -> String {
        guard rpm.isFinite else { throw FanCommandError.invalidRPM(rawRPM) }

        let count = try fanCount()
        guard fan >= 0, fan < count else {
            throw FanCommandError.invalidFan(fan, fanCount: count)
        }

        let minimum = try readRPM(FanKey.minimum(for: fan))
        let maximum = try readRPM(FanKey.maximum(for: fan))
        guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum else {
            throw FanCommandError.rpmOutsideRange(rpm, minimum: minimum, maximum: maximum)
        }
        guard rpm >= minimum, rpm <= maximum else {
            throw FanCommandError.rpmOutsideRange(rpm, minimum: minimum, maximum: maximum)
        }

        let targetKey = FanKey.target(for: fan)
        let targetValue = try client.read(targetKey)
        let targetBytes = try SMCDataCodec.encodeFanRPM(rpm, dataType: targetValue.dataType)
        let initialActualRPM = try? readRPM(FanKey.actual(for: fan))
        let zeroTargetNeedsUnlock = try forceTestRequiredForZeroTarget(rpm)
        var mode = try enableManualMode(
            fan: fan,
            requireForceTest: zeroTargetNeedsUnlock
        )

        do {
            try writeAndVerifyTarget(
                targetKey,
                rpm: rpm,
                dataType: targetValue.dataType,
                bytes: targetBytes
            )

            let directAttempts = mode.usesForceTest
                ? max(1, timing.maxAttempts)
                : max(1, timing.directResponseAttempts)
            var actualResponded = verifyActualResponse(
                fan: fan,
                targetRPM: rpm,
                initialRPM: initialActualRPM,
                attempts: directAttempts
            )

            if !actualResponded, !mode.usesForceTest, forceTestIsAvailable() {
                try writeAndVerifyMode(mode.key, value: 0)
                mode = try enableManualMode(fan: fan, requireForceTest: true)
                try writeAndVerifyTarget(
                    targetKey,
                    rpm: rpm,
                    dataType: targetValue.dataType,
                    bytes: targetBytes
                )
                actualResponded = verifyActualResponse(
                    fan: fan,
                    targetRPM: rpm,
                    initialRPM: initialActualRPM,
                    attempts: max(1, timing.maxAttempts)
                )
            } else if !actualResponded, !mode.usesForceTest {
                actualResponded = verifyActualResponse(
                    fan: fan,
                    targetRPM: rpm,
                    initialRPM: initialActualRPM,
                    attempts: max(1, timing.maxAttempts)
                )
            }

            guard actualResponded else {
                throw FanVerificationError(
                    "F\(fan)Ac did not respond to a \(rpm) RPM target"
                )
            }
            guard try readUInt8(mode.key) == 1 else {
                throw FanVerificationError("\(mode.key) did not remain in manual mode")
            }
        } catch {
            let rollbackDetails = rollbackManualMode(fan: fan, modeKey: mode.key)
            let suffix = rollbackDetails.isEmpty ? "" : "; rollback: \(rollbackDetails)"
            throw FanCommandError.controlVerificationFailed(
                fan,
                details: "\(error.localizedDescription)\(suffix)"
            )
        }

        manualFans.insert(fan)
        manualModeKeys[fan] = mode.key
        return "OK: fan \(fan) manual at \(rpm) RPM"
    }

    private func restoreAutomaticControl() throws -> String {
        var failures: [String] = []
        var fans = manualFans

        do {
            let count = try fanCount()
            fans.formUnion(0..<count)
        } catch {
            failures.append("FNum: \(error.localizedDescription)")
            // Every supported MacBook has one or two fans. If FNum is
            // temporarily unreadable, still attempt the complete known set.
            fans.formUnion(0...1)
        }

        for fan in fans.sorted() {
            do {
                try restoreAutomaticMode(for: fan)
                manualFans.remove(fan)
                manualModeKeys.removeValue(forKey: fan)
            } catch {
                failures.append("fan \(fan): \(error.localizedDescription)")
            }
        }

        if ownsForceTest {
            do {
                try disableForceTest()
                manualFans.removeAll()
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        } else {
            switch probeForceTest(attempts: 3) {
            case .available:
                do {
                    try disableForceTest()
                    manualFans.removeAll()
                } catch {
                    failures.append("Ftst: \(error.localizedDescription)")
                }
            case .unavailable:
                break
            case let .failed(error):
                failures.append("Ftst probe: \(error.localizedDescription)")
            }
        }

        guard failures.isEmpty else {
            throw FanCommandError.automaticResetFailed(failures)
        }
        return "OK: automatic fan control restored"
    }

    private func fanCount() throws -> Int {
        let value = try client.read(FanKey.count)
        let count = Int(try SMCDataCodec.decodeUInt8(value.bytes, dataType: value.dataType))
        guard count > 0, count <= Self.maximumSupportedFanCount else {
            throw FanCommandError.invalidFanCount(count)
        }
        return count
    }

    private func readRPM(_ key: String) throws -> Double {
        let value = try client.read(key)
        return try SMCDataCodec.decodeFanRPM(value.bytes, dataType: value.dataType)
    }

    private func readableModeKeys(for fan: Int) -> [String] {
        FanKey.modeCandidates(for: fan).filter { candidate in
            (try? readUInt8(candidate)) != nil
        }
    }

    private func enableManualMode(
        fan: Int,
        requireForceTest: Bool
    ) throws -> ManualMode {
        let modeKeys = readableModeKeys(for: fan)
        guard !modeKeys.isEmpty else { throw FanCommandError.missingModeKey(fan) }

        var failures: [String] = []
        if !requireForceTest {
            for modeKey in modeKeys {
                do {
                    try writeAndVerifyMode(modeKey, value: 1)
                    return ManualMode(key: modeKey, usesForceTest: false)
                } catch {
                    failures.append("\(modeKey): \(error.localizedDescription)")
                    do {
                        try ensureModeIsNotManual(modeKey)
                    } catch {
                        failures.append("\(modeKey) cleanup: \(error.localizedDescription)")
                        throw FanCommandError.manualModeFailed(
                            fan,
                            details: failures.joined(separator: "; ")
                        )
                    }
                }
            }
        }

        do {
            try enableForceTest()
        } catch {
            failures.append("Ftst: \(error.localizedDescription)")
            do {
                try resetOwnedForceTestIfUnused()
            } catch {
                failures.append("Ftst cleanup: \(error.localizedDescription)")
            }
            throw FanCommandError.manualModeFailed(
                fan,
                details: failures.joined(separator: "; ")
            )
        }

        if timing.settleDelay > 0 { sleep(timing.settleDelay) }

        for attempt in 0..<max(1, timing.maxAttempts) {
            let cycleStart = DispatchTime.now().uptimeNanoseconds
            for modeKey in modeKeys {
                do {
                    try writeAndVerifyMode(modeKey, value: 1)
                    return ManualMode(key: modeKey, usesForceTest: true)
                } catch {
                    failures.append("\(modeKey): \(error.localizedDescription)")
                    do {
                        try ensureModeIsNotManual(modeKey)
                    } catch {
                        failures.append("\(modeKey) cleanup: \(error.localizedDescription)")
                        do {
                            try resetOwnedForceTestIfUnused()
                        } catch {
                            failures.append("Ftst cleanup: \(error.localizedDescription)")
                        }
                        throw FanCommandError.manualModeFailed(
                            fan,
                            details: failures.suffix(4).joined(separator: "; ")
                        )
                    }
                }
            }
            let elapsed = Double(
                DispatchTime.now().uptimeNanoseconds - cycleStart
            ) / 1_000_000_000
            let remainingRetryDelay = max(0, timing.retryDelay - elapsed)
            if attempt + 1 < max(1, timing.maxAttempts), remainingRetryDelay > 0 {
                sleep(remainingRetryDelay)
            }
        }

        do {
            try resetOwnedForceTestIfUnused()
        } catch {
            failures.append("Ftst cleanup: \(error.localizedDescription)")
        }
        throw FanCommandError.manualModeFailed(
            fan,
            details: failures.suffix(4).joined(separator: "; ")
        )
    }

    private func enableForceTest() throws {
        let current = try readUInt8(FanKey.forceTest)
        guard current != 1 else { return }
        ownsForceTest = true

        do {
            try client.write(FanKey.forceTest, bytes: [1])
            guard try readUInt8(FanKey.forceTest) == 1 else {
                throw FanVerificationError("Ftst write was not retained")
            }
        } catch {
            let originalError = error.localizedDescription
            do {
                try disableForceTest()
            } catch {
                throw FanVerificationError(
                    "\(originalError); Ftst cleanup failed: \(error.localizedDescription)"
                )
            }
            throw FanVerificationError(originalError)
        }
    }

    private func forceTestIsAvailable() -> Bool {
        if case .available = probeForceTest(attempts: 3) { return true }
        return false
    }

    private func forceTestRequiredForZeroTarget(_ rpm: Double) throws -> Bool {
        guard rpm == 0 else { return false }

        switch probeForceTest(attempts: 3) {
        case .available:
            return true
        case .unavailable:
            return false
        case let .failed(error):
            throw FanVerificationError(
                "Could not determine whether Ftst is required: " +
                    error.localizedDescription
            )
        }
    }

    private func probeForceTest(attempts: Int) -> ForceTestProbe {
        var lastError: Error?
        for attempt in 0..<max(1, attempts) {
            do {
                _ = try readUInt8(FanKey.forceTest)
                return .available
            } catch is SMCKeyUnavailableError {
                return .unavailable
            } catch {
                lastError = error
                if attempt + 1 < max(1, attempts), timing.retryDelay > 0 {
                    sleep(timing.retryDelay)
                }
            }
        }
        return .failed(lastError ?? FanVerificationError("Ftst probe failed"))
    }

    private func disableForceTest() throws {
        try client.write(FanKey.forceTest, bytes: [0])
        guard try readUInt8(FanKey.forceTest) == 0 else {
            throw FanVerificationError("Ftst reset was not retained")
        }
        ownsForceTest = false
    }

    private func writeAndVerifyMode(_ key: String, value: UInt8) throws {
        try client.write(key, bytes: [value])
        if timing.modeVerificationDelay > 0 { sleep(timing.modeVerificationDelay) }
        let actual = try readUInt8(key)
        let acceptedValues: Set<UInt8> = value == 0 ? [0, 3] : [1]
        guard acceptedValues.contains(actual) else {
            throw FanVerificationError(
                "\(key) read back \(actual), expected \(value)"
            )
        }
    }

    private func ensureModeIsNotManual(_ key: String) throws {
        if let value = try? readUInt8(key), [0, 3].contains(value) { return }
        try writeAndVerifyMode(key, value: 0)
    }

    private func writeAndVerifyTarget(
        _ key: String,
        rpm: Double,
        dataType: String,
        bytes: [UInt8]
    ) throws {
        try client.write(key, bytes: bytes)
        let confirmed = try client.read(key)
        guard confirmed.dataType.trimmingCharacters(in: .whitespacesAndNewlines) ==
                dataType.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw FanVerificationError("\(key) datatype changed during write")
        }
        let confirmedRPM = try SMCDataCodec.decodeFanRPM(
            confirmed.bytes,
            dataType: confirmed.dataType
        )
        guard confirmedRPM.isFinite,
              abs(confirmedRPM - rpm) <= Self.targetTolerance else {
            throw FanVerificationError(
                "\(key) read back \(confirmedRPM) RPM, expected \(rpm)"
            )
        }
    }

    private func verifyActualResponse(
        fan: Int,
        targetRPM: Double,
        initialRPM: Double?,
        attempts: Int
    ) -> Bool {
        guard targetRPM > 0 else { return true }

        for attempt in 0..<max(1, attempts) {
            if let actual = try? readRPM(FanKey.actual(for: fan)),
               actual.isFinite,
               actualRPMResponded(
                   actual,
                   initialRPM: initialRPM,
                   targetRPM: targetRPM
               ) {
                return true
            }
            if attempt + 1 < max(1, attempts), timing.retryDelay > 0 {
                sleep(timing.retryDelay)
            }
        }
        return false
    }

    private func actualRPMResponded(
        _ actualRPM: Double,
        initialRPM: Double?,
        targetRPM: Double
    ) -> Bool {
        let targetTolerance = max(25, min(150, targetRPM * 0.05))
        if abs(actualRPM - targetRPM) <= targetTolerance { return true }

        guard let initialRPM, initialRPM.isFinite else { return false }
        let requestedChange = targetRPM - initialRPM
        if abs(requestedChange) <= targetTolerance {
            return actualRPM > 0
        }

        let requiredProgress = min(
            abs(requestedChange),
            max(50, min(500, abs(requestedChange) * 0.1))
        )
        let observedProgress = actualRPM - initialRPM
        return requestedChange > 0
            ? observedProgress >= requiredProgress
            : observedProgress <= -requiredProgress
    }

    private func restoreAutomaticMode(for fan: Int) throws {
        var modeKeys = readableModeKeys(for: fan)
        if let trackedKey = manualModeKeys[fan], !modeKeys.contains(trackedKey) {
            modeKeys.append(trackedKey)
        }
        guard !modeKeys.isEmpty else { throw FanCommandError.missingModeKey(fan) }

        var failures: [String] = []
        for modeKey in modeKeys {
            do {
                try writeAndVerifyMode(modeKey, value: 0)
            } catch {
                failures.append("\(modeKey): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw FanVerificationError(failures.joined(separator: "; "))
        }
    }

    private func readUInt8(_ key: String) throws -> UInt8 {
        let value = try client.read(key)
        return try SMCDataCodec.decodeUInt8(value.bytes, dataType: value.dataType)
    }

    private func rollbackManualMode(fan: Int, modeKey: String) -> String {
        var failures: [String] = []
        do {
            try writeAndVerifyMode(modeKey, value: 0)
        } catch {
            failures.append("mode: \(error.localizedDescription)")
        }

        manualFans.remove(fan)
        manualModeKeys.removeValue(forKey: fan)
        if manualFans.isEmpty, ownsForceTest {
            do {
                try disableForceTest()
            } catch {
                failures.append("Ftst: \(error.localizedDescription)")
            }
        }
        return failures.joined(separator: ", ")
    }

    private func resetOwnedForceTestIfUnused() throws {
        guard manualFans.isEmpty, ownsForceTest else { return }
        try disableForceTest()
    }
}

private struct ManualMode {
    let key: String
    let usesForceTest: Bool
}

private enum ForceTestProbe {
    case available
    case unavailable
    case failed(Error)
}

private struct FanVerificationError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
