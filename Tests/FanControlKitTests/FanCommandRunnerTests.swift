import Foundation
import Testing
@testable import FanControlCore

@Suite("Privileged fan command runner")
struct FanCommandRunnerTests {

    @Test func directModeUsesTheExistingUppercaseKey() throws {
        let client = makeClient(modeKey: "F0Md")
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        let expectedTarget = try SMCDataCodec.encodeFanRPM(3500, dataType: "flt ")

        #expect(client.writes.map(\.key) == ["F0Md", "F0Tg"])
        #expect(client.writes.last?.bytes == expectedTarget)
    }

    @Test func directModeUsesTheExistingLowercaseKey() throws {
        let client = makeClient(modeKey: "F0md")
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])

        #expect(client.writes.map(\.key) == ["F0md", "F0Tg"])
    }

    @Test func rejectedDirectModeFallsBackToForceTest() throws {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.modeRequiresForceTest = true
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])

        #expect(client.writes.map(\.key) == ["F0Md", "Ftst", "F0Md", "F0Tg"])
        #expect(client.values["Ftst"]?.bytes == [1])
    }

    @Test func forceTestRetriesWaitWhenModeWritesFailImmediately() {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.failedWriteKeys.insert("F0Md")
        var sleeps: [TimeInterval] = []
        let runner = FanCommandRunner(
            client: client,
            timing: FanControlTiming(
                settleDelay: 0,
                retryDelay: 0.1,
                maxAttempts: 3,
                modeVerificationDelay: 0.1,
                directResponseAttempts: 1
            ),
            sleep: { sleeps.append($0) }
        )

        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        }

        let retrySleeps = sleeps.filter { $0 > 0.09 }
        #expect(retrySleeps.count >= 2)
    }

    @Test func rejectedReadableLowercaseModeTriesUppercaseMode() throws {
        let client = makeClient(modeKey: "F0md")
        client.values["F0Md"] = SMCValue(dataType: "ui8 ", bytes: [0])
        client.failedWriteKeys.insert("F0md")
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])

        #expect(client.writes.map(\.key).prefix(3) == ["F0md", "F0Md", "F0Tg"])
    }

    @Test func silentDirectControlFallsBackWhenActualRPMStaysZero() throws {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.actualRequiresForceTest = true
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])

        #expect(client.writes.filter { $0.key == "F0Tg" }.count == 2)
        #expect(client.writes.contains { $0.key == "Ftst" && $0.bytes == [1] })
        #expect(client.values["F0Ac"]?.bytes == client.values["F0Tg"]?.bytes)
    }

    @Test func unchangedSpinningFanDoesNotSuppressForceTestFallback() throws {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.values["F0Ac"] = SMCValue(
            dataType: "flt ",
            bytes: try SMCDataCodec.encodeFanRPM(1500, dataType: "flt ")
        )
        client.actualRequiresForceTest = true
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "6000"])

        #expect(client.writes.filter { $0.key == "F0Tg" }.count == 2)
        #expect(client.writes.contains { $0.key == "Ftst" && $0.bytes == [1] })
    }

    @Test func forceTestReadbackFailureIsCleanedUp() {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.modeRequiresForceTest = true
        client.failForceTestReadAfterEnable = true
        let runner = makeRunner(client)

        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        }

        #expect(client.values[FanKey.forceTest]?.bytes == [0])
        #expect(client.writes.last?.key == FanKey.forceTest)
        #expect(client.writes.last?.bytes == [0])
    }

    @Test func forceTestCleanupFailureIsReported() {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.failedWriteKeys.insert("F0Md")
        client.failForceTestDisableWrites = true
        let runner = makeRunner(client)
        var message = ""

        do {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        } catch {
            message = error.localizedDescription
        }

        #expect(message.contains("Ftst cleanup"))
        #expect(client.values[FanKey.forceTest]?.bytes == [1])
    }

    @Test func zeroTargetUsesForceTestWhenActualRPMCannotProveControl() throws {
        let client = makeClient(
            modeKey: "F0Md",
            forceTestAvailable: true,
            minimumRPM: 0
        )
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "0"])

        #expect(client.writes.first?.key == "Ftst")
        #expect(client.values[FanKey.forceTest]?.bytes == [1])
    }

    @Test func zeroTargetRetriesAnUncertainForceTestProbe() throws {
        let client = makeClient(
            modeKey: "F0Md",
            forceTestAvailable: true,
            minimumRPM: 0
        )
        client.pendingForceTestReadFailures = 1
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "0"])

        #expect(client.writes.first?.key == FanKey.forceTest)
        #expect(client.values[FanKey.forceTest]?.bytes == [1])
    }

    @Test func reclaimedModeIsReportedAndRolledBack() {
        let client = makeClient(modeKey: "F0Md")
        client.reclaimModeAfterTarget = true
        let runner = makeRunner(client)

        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        }
        #expect(client.writes.last?.key == "F0Md")
        #expect(client.writes.last?.bytes == [0])
    }

    @Test func targetEncodingUsesTheReportedSMCDataType() throws {
        let client = makeClient(modeKey: "F0Md", rpmDataType: "fpe2")
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        let expectedTarget = try SMCDataCodec.encodeFanRPM(3500, dataType: "fpe2")

        #expect(client.writes.last?.bytes == expectedTarget)
    }

    @Test func oneFanHardwareRejectsFanOneWithoutWriting() {
        let client = makeClient(fanCount: 1, modeKey: "F0Md")
        let runner = makeRunner(client)
        var didThrow = false

        do {
            _ = try runner.run(arguments: ["set-fan", "1", "3500"])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(client.writes.isEmpty)
    }

    @Test func nonFiniteTargetIsRejectedWithoutWriting() {
        let client = makeClient(modeKey: "F0Md")
        let runner = makeRunner(client)
        var didThrow = false

        do {
            _ = try runner.run(arguments: ["set-fan", "0", "nan"])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(client.writes.isEmpty)
    }

    @Test func outOfRangeTargetIsRejectedWithoutEnteringManualMode() {
        let client = makeClient(modeKey: "F0Md")
        let runner = makeRunner(client)
        var didThrow = false

        do {
            _ = try runner.run(arguments: ["set-fan", "0", "9000"])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(client.writes.isEmpty)
    }

    @Test func targetFailureRestoresAutoAndForceTest() {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.modeRequiresForceTest = true
        client.failTargetWrites = true
        let runner = makeRunner(client)
        var didThrow = false

        do {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(client.writes.suffix(2).map(\.key) == ["F0Md", "Ftst"])
        #expect(client.writes.suffix(2).map(\.bytes) == [[0], [0]])
    }

    @Test func autoUsesTheReportedFanCount() throws {
        let client = makeTwoFanClient()
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["auto"])

        #expect(client.writes.map(\.key) == ["F0Md", "F1Md", "Ftst"])
        #expect(client.writes.allSatisfy { $0.bytes == [0] })
    }

    @Test func autoReportsPartialResetFailure() {
        let client = makeTwoFanClient()
        client.failedWriteKeys.insert("F1Md")
        let runner = makeRunner(client)
        var didThrow = false

        do {
            _ = try runner.run(arguments: ["auto"])
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(client.writes.map(\.key) == ["F0Md", "F1Md", "Ftst"])
    }

    @Test func automaticResetClearsEveryReadableModeAlias() throws {
        let client = makeClient(modeKey: "F0md")
        client.values["F0Md"] = SMCValue(dataType: "ui8 ", bytes: [1])
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["auto"])

        #expect(client.writes.map(\.key) == ["F0md", "F0Md"])
        #expect(client.writes.allSatisfy { $0.bytes == [0] })
    }

    @Test func automaticCleanupAttemptsKnownFansWhenFNumIsUnavailable() throws {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.modeRequiresForceTest = true
        let runner = makeRunner(client)
        _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        client.values.removeValue(forKey: FanKey.count)
        client.writes.removeAll()

        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["auto"])
        }

        #expect(client.writes.contains { $0.key == "F0Md" && $0.bytes == [0] })
        #expect(client.writes.contains { $0.key == FanKey.forceTest && $0.bytes == [0] })
    }

    @Test func automaticCleanupRetriesAnUncertainForceTestRead() throws {
        let client = makeClient(modeKey: "F0Md", forceTestAvailable: true)
        client.values[FanKey.forceTest] = SMCValue(dataType: "ui8 ", bytes: [1])
        client.pendingForceTestReadFailures = 1
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["auto"])

        #expect(client.writes.contains { $0.key == FanKey.forceTest && $0.bytes == [0] })
    }

    @Test func fanCountRequiresAUi8Value() {
        let client = makeClient(modeKey: "F0Md")
        client.values[FanKey.count] = SMCValue(dataType: "flt ", bytes: [1, 0, 0, 0])
        let runner = makeRunner(client)

        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        }
        #expect(client.writes.isEmpty)
    }

    @Test func failedSecondFanDoesNotClearGlobalForceTest() throws {
        let client = makeTwoFanClient()
        client.modeRequiresForceTest = true
        let runner = makeRunner(client)

        _ = try runner.run(arguments: ["set-fan", "0", "3500"])
        client.failedWriteKeys.insert("F1Tg")
        #expect(throws: (any Error).self) {
            _ = try runner.run(arguments: ["set-fan", "1", "3500"])
        }

        #expect(client.values[FanKey.forceTest]?.bytes == [1])
        #expect(client.writes.last?.key == "F1Md")
        #expect(client.writes.last?.bytes == [0])
    }
}

private struct FakeSMCError: Error {}

private final class FakeFanSMCClient: FanSMCClient {
    struct Write: Equatable {
        let key: String
        let bytes: [UInt8]
    }

    var values: [String: SMCValue]
    var writes: [Write] = []
    var failedWriteKeys: Set<String> = []
    var modeRequiresForceTest = false
    var actualRequiresForceTest = false
    var reclaimModeAfterTarget = false
    var failForceTestReadAfterEnable = false
    var failForceTestDisableWrites = false
    var pendingForceTestReadFailures = 0
    var failTargetWrites = false

    init(values: [String: SMCValue]) {
        self.values = values
    }

    func read(_ key: String) throws -> SMCValue {
        if key == FanKey.forceTest, pendingForceTestReadFailures > 0 {
            pendingForceTestReadFailures -= 1
            throw FakeSMCError()
        }
        guard let value = values[key] else {
            throw SMCKeyUnavailableError(key: key)
        }
        return value
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        writes.append(Write(key: key, bytes: bytes))

        if failedWriteKeys.contains(key) { throw FakeSMCError() }
        if key == FanKey.forceTest, bytes == [0], failForceTestDisableWrites {
            throw FakeSMCError()
        }
        if failTargetWrites && key.hasSuffix("Tg") { throw FakeSMCError() }
        if modeRequiresForceTest && key.lowercased().hasSuffix("md") && bytes == [1],
           values["Ftst"]?.bytes != [1] {
            throw FakeSMCError()
        }

        let dataType = values[key]?.dataType ?? "ui8 "
        values[key] = SMCValue(dataType: dataType, bytes: bytes)
        if key == FanKey.forceTest, bytes == [1], failForceTestReadAfterEnable {
            pendingForceTestReadFailures = 1
        }

        if key.hasSuffix("Tg"),
           !actualRequiresForceTest || values[FanKey.forceTest]?.bytes == [1] {
            let fan = String(key.prefix(2))
            values["\(fan)Ac"] = SMCValue(dataType: dataType, bytes: bytes)
        }
        if key.hasSuffix("Tg"), reclaimModeAfterTarget {
            let modeKeys = values.keys.filter { $0.lowercased().hasSuffix("md") }
            for modeKey in modeKeys {
                values[modeKey] = SMCValue(dataType: "ui8 ", bytes: [0])
            }
        }
    }
}

private func makeRunner(_ client: FakeFanSMCClient) -> FanCommandRunner {
    FanCommandRunner(
        client: client,
        timing: FanControlTiming(settleDelay: 0, retryDelay: 0, maxAttempts: 3),
        sleep: { _ in }
    )
}

private func makeClient(
    fanCount: UInt8 = 1,
    modeKey: String,
    forceTestAvailable: Bool = false,
    minimumRPM: Double = 2000,
    rpmDataType: String = "flt "
) -> FakeFanSMCClient {
    var values: [String: SMCValue] = [
        FanKey.count: SMCValue(dataType: "ui8 ", bytes: [fanCount]),
        "F0Mn": SMCValue(
            dataType: rpmDataType,
            bytes: try! SMCDataCodec.encodeFanRPM(minimumRPM, dataType: rpmDataType)
        ),
        "F0Mx": SMCValue(dataType: rpmDataType, bytes: try! SMCDataCodec.encodeFanRPM(6000, dataType: rpmDataType)),
        "F0Tg": SMCValue(dataType: rpmDataType, bytes: try! SMCDataCodec.encodeFanRPM(2000, dataType: rpmDataType)),
        "F0Ac": SMCValue(dataType: rpmDataType, bytes: try! SMCDataCodec.encodeFanRPM(0, dataType: rpmDataType)),
        modeKey: SMCValue(dataType: "ui8 ", bytes: [0]),
    ]
    if forceTestAvailable {
        values[FanKey.forceTest] = SMCValue(dataType: "ui8 ", bytes: [0])
    }
    return FakeFanSMCClient(values: values)
}

private func makeTwoFanClient() -> FakeFanSMCClient {
    let client = makeClient(fanCount: 2, modeKey: "F0Md", forceTestAvailable: true)
    client.values["F1Md"] = SMCValue(dataType: "ui8 ", bytes: [1])
    client.values["F1Mn"] = SMCValue(dataType: "flt ", bytes: try! SMCDataCodec.encodeFanRPM(2000, dataType: "flt "))
    client.values["F1Mx"] = SMCValue(dataType: "flt ", bytes: try! SMCDataCodec.encodeFanRPM(6000, dataType: "flt "))
    client.values["F1Tg"] = SMCValue(dataType: "flt ", bytes: try! SMCDataCodec.encodeFanRPM(2000, dataType: "flt "))
    client.values["F1Ac"] = SMCValue(dataType: "flt ", bytes: try! SMCDataCodec.encodeFanRPM(0, dataType: "flt "))
    return client
}
