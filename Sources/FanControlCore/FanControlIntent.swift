public struct FanControlIntent: Equatable, Sendable {
    private var targets: [Int: Double] = [:]
    private var confirmedTargets: [Int: Double] = [:]
    private var confirmedRevisions: [Int: UInt64] = [:]
    private var fanRevisions: [Int: UInt64] = [:]
    private var fanInvalidationRevisions: [Int: UInt64] = [:]
    private var automaticRevision: UInt64 = 0
    private var nextRevision: UInt64 = 0
    private var stateGeneration: UInt64 = 0

    public init() {}

    public var isAutomatic: Bool { targets.isEmpty }
    public var manualTargets: [Int: Double] { targets }
    public var generation: UInt64 { stateGeneration }

    @discardableResult
    public mutating func requestManual(fan: Int, rpm: Double) -> UInt64 {
        nextRevision &+= 1
        stateGeneration &+= 1
        fanRevisions[fan] = nextRevision
        targets[fan] = rpm
        return nextRevision
    }

    public mutating func requestAutomatic() {
        nextRevision &+= 1
        stateGeneration &+= 1
        automaticRevision = nextRevision
        targets.removeAll()
        confirmedTargets.removeAll()
        confirmedRevisions.removeAll()
    }

    public mutating func cancelManual(fan: Int) {
        nextRevision &+= 1
        stateGeneration &+= 1
        fanRevisions[fan] = nextRevision
        fanInvalidationRevisions[fan] = nextRevision
        targets.removeValue(forKey: fan)
        confirmedTargets.removeValue(forKey: fan)
        confirmedRevisions.removeValue(forKey: fan)
    }

    public mutating func manualRequestSucceeded(
        fan: Int,
        rpm: Double,
        revision: UInt64
    ) {
        guard revision > automaticRevision,
              revision > fanInvalidationRevisions[fan, default: 0],
              revision > confirmedRevisions[fan, default: 0],
              let latestRequestRevision = fanRevisions[fan],
              revision <= latestRequestRevision else { return }
        confirmedTargets[fan] = rpm
        confirmedRevisions[fan] = revision
    }

    public mutating func manualRequestFailed(fan: Int, revision: UInt64) {
        guard revision > automaticRevision,
              fanRevisions[fan] == revision else { return }
        let previousTarget = targets[fan]
        if let confirmedTarget = confirmedTargets[fan] {
            targets[fan] = confirmedTarget
        } else {
            targets.removeValue(forKey: fan)
        }
        if targets[fan] != previousTarget {
            stateGeneration &+= 1
        }
    }
}
