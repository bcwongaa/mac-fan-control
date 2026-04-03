import Foundation

// MARK: - Fan SMC Keys

enum FanKey {
    static let count = "FNum"    // Number of fans (ui8)

    // Fan 0 — left fan on M2 Pro
    static let fan0Actual = "F0Ac"  // Actual RPM (fpe2)
    static let fan0Min    = "F0Mn"  // Minimum RPM floor, writable (fpe2)
    static let fan0Max    = "F0Mx"  // Maximum RPM (fpe2)
    static let fan0Safe   = "F0Sf"  // Safe RPM (fpe2)
    static let fan0Target = "F0Tg"  // Target RPM (fpe2)

    // Fan 1 — right fan on M2 Pro
    static let fan1Actual = "F1Ac"
    static let fan1Min    = "F1Mn"
    static let fan1Max    = "F1Mx"
    static let fan1Safe   = "F1Sf"
    static let fan1Target = "F1Tg"
}

// MARK: - Temperature SMC Keys

enum TempKey {
    static let cpuProximity = "TC0P"  // CPU proximity
    static let cpuDie       = "TC0D"  // CPU die (most reliable on Intel; may be absent on AS)
    static let cpuCore1     = "TC1C"  // CPU core 1
    static let gpuProximity = "TG0P"  // GPU proximity
    static let gpuDie       = "TG0D"  // GPU die
    static let nandTemp     = "TH0x"  // SSD/NAND
    static let batteryTemp  = "TB0T"  // Battery
    static let palmRest     = "Ts0P"  // System / palm rest
    static let airflowLeft  = "TaLP"  // Left airflow
    static let airflowRight = "TaRP"  // Right airflow
}
