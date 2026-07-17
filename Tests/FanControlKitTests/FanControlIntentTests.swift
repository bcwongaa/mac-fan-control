import Testing
@testable import FanControlCore

@Suite("Fan control intent")
struct FanControlIntentTests {
    @Test func recordsOnlyFansExplicitlyPlacedInManualMode() {
        var intent = FanControlIntent()
        intent.requestManual(fan: 0, rpm: 3200)

        #expect(intent.manualTargets == [0: 3200])
        #expect(!intent.isAutomatic)
    }

    @Test func automaticRequestInvalidatesOlderManualFailure() {
        var intent = FanControlIntent()
        let oldRevision = intent.requestManual(fan: 0, rpm: 3200)
        intent.requestAutomatic()
        _ = intent.requestManual(fan: 0, rpm: 4100)

        intent.manualRequestFailed(fan: 0, revision: oldRevision)

        #expect(intent.manualTargets == [0: 4100])
    }

    @Test func latestManualFailureClearsOnlyThatFan() {
        var intent = FanControlIntent()
        let fan0Revision = intent.requestManual(fan: 0, rpm: 3200)
        _ = intent.requestManual(fan: 1, rpm: 3500)

        intent.manualRequestFailed(fan: 0, revision: fan0Revision)

        #expect(intent.manualTargets == [1: 3500])
    }

    @Test func failedUpdateRestoresLastConfirmedManualTarget() {
        var intent = FanControlIntent()
        let firstRevision = intent.requestManual(fan: 0, rpm: 3000)
        intent.manualRequestSucceeded(fan: 0, rpm: 3000, revision: firstRevision)
        let updateRevision = intent.requestManual(fan: 0, rpm: 4000)
        let generationBeforeFailure = intent.generation

        intent.manualRequestFailed(fan: 0, revision: updateRevision)

        #expect(intent.manualTargets == [0: 3000])
        #expect(intent.generation > generationBeforeFailure)
    }

    @Test func cancelledRequestCannotBecomeAConfirmedRollbackTarget() {
        var intent = FanControlIntent()
        let cancelledRevision = intent.requestManual(fan: 0, rpm: 3000)
        intent.cancelManual(fan: 0)
        let replacementRevision = intent.requestManual(fan: 0, rpm: 4000)

        intent.manualRequestSucceeded(
            fan: 0,
            rpm: 3000,
            revision: cancelledRevision
        )
        intent.manualRequestFailed(fan: 0, revision: replacementRevision)

        #expect(intent.isAutomatic)
    }

    @Test func olderSuccessCannotReplaceANewerConfirmedTarget() {
        var intent = FanControlIntent()
        let olderRevision = intent.requestManual(fan: 0, rpm: 3000)
        let newerRevision = intent.requestManual(fan: 0, rpm: 4000)

        intent.manualRequestSucceeded(fan: 0, rpm: 4000, revision: newerRevision)
        intent.manualRequestSucceeded(fan: 0, rpm: 3000, revision: olderRevision)
        let failedRevision = intent.requestManual(fan: 0, rpm: 5000)
        intent.manualRequestFailed(fan: 0, revision: failedRevision)

        #expect(intent.manualTargets == [0: 4000])
    }
}
