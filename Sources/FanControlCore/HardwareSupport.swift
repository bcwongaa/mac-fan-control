import Darwin
import Foundation

public enum AppleSiliconGeneration: Equatable, Sendable {
    case m1
    case m2
    case m3
    case m4
    case m5
    case unknown

    public init(chipName: String) {
        let generationToken = chipName
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first { ["M1", "M2", "M3", "M4", "M5"].contains($0) }

        switch generationToken {
        case "M1": self = .m1
        case "M2": self = .m2
        case "M3": self = .m3
        case "M4": self = .m4
        case "M5": self = .m5
        default:   self = .unknown
        }
    }

    public static func current() -> AppleSiliconGeneration {
        guard let chipName = sysctlString("machdep.cpu.brand_string") else {
            return .unknown
        }
        return AppleSiliconGeneration(chipName: chipName)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            sysctlbyname(name, pointer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return String(cString: buffer)
    }
}

public enum FanKey {
    public static let count = "FNum"
    public static let forceTest = "Ftst"

    public static func actual(for fan: Int) -> String { "F\(fan)Ac" }
    public static func minimum(for fan: Int) -> String { "F\(fan)Mn" }
    public static func maximum(for fan: Int) -> String { "F\(fan)Mx" }
    public static func target(for fan: Int) -> String { "F\(fan)Tg" }

    public static func modeCandidates(for fan: Int) -> [String] {
        ["F\(fan)md", "F\(fan)Md"]
    }
}

public enum FanHelperInstallation {
    public static let executablePath =
        "/Library/PrivilegedHelperTools/com.local.FanControl.FanHelper"
    public static let sudoersPath = "/etc/sudoers.d/fan-control"
    public static let verificationToken = "FanHelper installation verified"

    public static var sudoersRule: String {
        "%admin ALL=(root) NOPASSWD: \(executablePath) serve, " +
        "\(executablePath) verify-install"
    }
}

public enum TempKey {
    // TCMz is the die maximum on observed M1-M4 systems. TCMb is a live
    // aggregate on every observed M1-M5 system and is the M5 fallback.
    public static let primaryDieCandidates = ["TCMz", "TCMb"]

    private static let m1DieCandidates = [
        "Tp0A", "Tp0U",
        "Tp02", "Tp06", "Tp0E", "Tp0I", "Tp0M", "Tp0Q", "Tp0Y", "Tp0c",
        "Tg05", "Tg0D", "Tg0L", "Tg0T",
        "Te00", "Te01", "Te02",
    ]

    private static let m2DieCandidates = [
        "Tp02", "Tp06", "Tp0A", "Tp0E", "Tp0g", "Tp0k", "Tp0o", "Tp0s",
        "Tp0a", "Tp0b", "Tp0c",
        "Te04", "Te05", "Te06",
        "Tg0f", "Tg0n", "Tg0r",
    ]

    private static let m3DieCandidates = [
        "Te06", "Te0I", "Te0P", "Te0Q", "Te0R", "Te0S", "Te0T", "Te0U", "Te0M",
        "Tp06", "Tp0E", "Tp0M", "Tp0c", "Tp0i", "Tp0o", "Tp1G", "Tp1S", "Tp10",
        "Tg05", "Tg0D", "Tg0L", "Tg01", "Tg0u", "Tg0v", "Tg13", "Tg1B", "Tg1l",
        "Tg0z", "Tg1F", "Tg17", "Tg1t", "Tg1y", "Tg22", "Tg2A", "Tg2I", "Tg34",
        "Tg3C", "Tg3K", "Tg3y",
    ]

    private static let m4DieCandidates = [
        "Te06", "Te0T", "Te0A", "Te0I", "Te0U", "Te0V", "Te0W", "Te0X",
        "TpxA", "TpxD", "Tex0", "Tex1", "Tex2", "Tex3",
        "Tp1k", "Tp1o", "Tp1u", "Tp1x", "Tp20", "Tp23", "Tp26", "Tp29", "Tp2C", "Tp2G",
        "Tp02", "Tp06", "Tp0A", "Tp0E", "Tp0I", "Tp0M", "Tp0Q", "Tp0U", "Tp0Y", "Tp0c",
        "Tp1C", "Tp1G", "Tp1S",
        "Tg0G", "Tg0H", "Tg0C", "Tg0K", "Tg0D", "Tg0L", "Tg0O", "Tg0d",
        "Tg0P", "Tg0e", "Tg0U", "Tg0j", "Tg0V", "Tg0k", "Tg0m", "Tg0n",
        "Tg04", "Tg05", "Tg0R", "Tg0S", "Tg0X", "Tg0Y", "Tg0y", "Tg0z",
        "Tg1E", "Tg1F", "Tg1U", "Tg1V", "Tg1c", "Tg1d", "Tg1k", "Tg1l",
        "Tg22", "Tg2I", "Tg2Q", "Tg2Y", "Tg2g", "Tg2o", "Tg34", "Tg3K",
        "Tg3a", "Tg3i", "Tg3q",
    ]

    private static let m5DieCandidates = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
        "Tp1E", "Tp1I", "Tp1Q", "Tp1U", "Tp1g",
        "Tg08", "Tg0C", "Tg0O", "Tg0R", "Tg0U", "Tg0X", "Tg0a", "Tg0d",
        "Tg0g", "Tg0j", "Tg12", "Tg16", "Tg1I", "Tg1M", "Tg1Q", "Tg1U",
        "Tg1Y", "Tg1c", "Tg1k", "Tg1o", "Tg1x", "Tg29", "Tg2D", "Tg2P",
        "Tg2T", "Tg2X", "Tg2b", "Tg2f", "Tg2j", "Tg2n", "Tg2r", "Tg3B",
        "Tg3F", "Tg3R", "Tg3V", "Tg3Z", "Tg3d", "Tg3h", "Tg3l", "Tg3t",
        "Tg3x", "Tg43",
    ]

    public static let allKnownDieCandidates: [String] = {
        let catalogs = [
            primaryDieCandidates,
            m1DieCandidates,
            m2DieCandidates,
            m3DieCandidates,
            m4DieCandidates,
            m5DieCandidates,
        ]
        return catalogs.joined().reduce(into: [String]()) { result, key in
            if !result.contains(key) { result.append(key) }
        }
    }()

    public static func dieCandidates(for generation: AppleSiliconGeneration) -> [String] {
        primaryDieCandidates + fallbackDieCandidates(for: generation)
    }

    public static func fallbackDieCandidates(
        for generation: AppleSiliconGeneration
    ) -> [String] {
        switch generation {
        case .m1:      return m1DieCandidates
        case .m2:      return m2DieCandidates
        case .m3:      return m3DieCandidates
        case .m4:      return m4DieCandidates
        case .m5:      return m5DieCandidates
        case .unknown: return allKnownDieCandidates.filter {
            !primaryDieCandidates.contains($0)
        }
        }
    }
}
