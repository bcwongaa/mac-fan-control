import Foundation

// MARK: - Fan SMC Keys

enum FanKey {
    static let count = "FNum"    // Number of fans (ui8)

    // Fan 0 — left fan (on M2 Pro: flt type = 4-byte LE float)
    static let fan0Actual = "F0Ac"  // Actual RPM
    static let fan0Min    = "F0Mn"  // Minimum RPM floor
    static let fan0Max    = "F0Mx"  // Maximum RPM
    static let fan0Safe   = "F0Sf"  // Safe RPM
    static let fan0Target = "F0Tg"  // Target RPM (write here for manual control)
    static let fan0Mode   = "F0Md"  // Fan mode: 0=auto, 1=manual, 3=system

    // Fan 1 — right fan
    static let fan1Actual = "F1Ac"
    static let fan1Min    = "F1Mn"
    static let fan1Max    = "F1Mx"
    static let fan1Safe   = "F1Sf"
    static let fan1Target = "F1Tg"
    static let fan1Mode   = "F1Md"

    // Unlock key — must write 1 before manual fan control on Apple Silicon
    static let forceTest  = "Ftst"  // ui8: 1=unlock manual mode, 0=restore auto
}

// MARK: - Temperature SMC Keys (M2 Pro)
//
// Apple Silicon uses entirely different key names from Intel.
// Data types are typically `flt ` (4-byte LE float) on M2.

enum TempKey {
    // M2 Pro CPU — Performance cores (up to 8)
    static let cpuPerf1 = "Tp01"
    static let cpuPerf2 = "Tp05"
    static let cpuPerf3 = "Tp09"
    static let cpuPerf4 = "Tp0D"
    static let cpuPerf5 = "Tp0X"
    static let cpuPerf6 = "Tp0b"
    static let cpuPerf7 = "Tp0f"
    static let cpuPerf8 = "Tp0j"

    // M2 Pro CPU — Efficiency cores (up to 4)
    static let cpuEff1  = "Tp1h"
    static let cpuEff2  = "Tp1t"
    static let cpuEff3  = "Tp1p"
    static let cpuEff4  = "Tp1l"

    // M2 Pro GPU
    static let gpu1     = "Tg0f"
    static let gpu2     = "Tg0j"

    // All CPU performance core keys to iterate
    static let cpuPerfAll = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]
    // All CPU efficiency core keys
    static let cpuEffAll  = ["Tp1h", "Tp1t", "Tp1p", "Tp1l"]
    // All GPU keys
    static let gpuAll     = ["Tg0f", "Tg0j"]

    // Intel fallbacks (for completeness)
    static let cpuProximity = "TC0P"
    static let cpuDie       = "TC0D"
    static let gpuProximity = "TG0P"
    static let gpuDie       = "TG0D"
}
