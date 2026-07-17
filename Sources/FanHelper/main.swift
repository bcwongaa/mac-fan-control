/// FanHelper — tiny CLI tool that writes SMC fan keys.
/// Invoked by the main app via "sudo FanHelper <command> [args...]"
/// Commands:
///   set-fan <fan:0|1> <rpm>    — set F{fan} mode to manual, F{fan}Tg to rpm
///   auto                        — restore auto mode on both fans
///
/// Hardware differences are resolved at runtime: fan count, mode-key casing,
/// target datatype, and the optional Ftst unlock are all probed before writes.
import Darwin
import Foundation
import FanControlCore
import IOKit

// MARK: - SMC raw I/O (same logic as SMCKit, inlined for standalone binary)

let kBufSize = 80

enum Off {
    static let key = 0, infoSize = 28, infoType = 32
    static let result: Int = 40, data8: Int = 42, dataBytes = 48
}

var connection: io_connect_t = 0

func openSMC() -> Bool {
    let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleSMC"))
    guard svc != IO_OBJECT_NULL else { return false }
    defer { IOObjectRelease(svc) }
    return IOServiceOpen(svc, mach_task_self_, 0, &connection) == kIOReturnSuccess
}

func setNat32(_ buf: inout [UInt8], _ off: Int, _ val: UInt32) {
    withUnsafeBytes(of: val) { s in for i in 0..<4 { buf[off+i] = s[i] } }
}
func getNat32(_ buf: [UInt8], _ off: Int) -> UInt32 {
    var v: UInt32 = 0
    withUnsafeMutableBytes(of: &v) { d in for i in 0..<4 { d[i] = buf[off+i] } }
    return v
}
func fourCC(_ s: String) -> UInt32 {
    s.unicodeScalars.prefix(4).enumerated().reduce(0) { a, p in
        a | (UInt32(p.element.value) << UInt32((3 - p.offset) * 8))
    }
}

func rawCall(_ input: [UInt8]) -> (Int32, [UInt8]) {
    var inp = input
    var out = [UInt8](repeating: 0, count: kBufSize)
    var sz = kBufSize
    let kr = inp.withUnsafeMutableBufferPointer { ib in
        out.withUnsafeMutableBufferPointer { ob in
            IOConnectCallStructMethod(connection, 2, ib.baseAddress, kBufSize, ob.baseAddress, &sz)
        }
    }
    return (kr, out)
}

func smcRead(_ key: String) throws -> (type: String, bytes: [UInt8]) {
    var buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    buf[Off.data8] = 9 // getKeyInfo
    let (kr1, out1) = rawCall(buf)
    guard kr1 == kIOReturnSuccess else {
        throw RawSMCError(
            message: "\(key): getKeyInfo kr=" +
                String(format: "0x%X", UInt32(bitPattern: kr1))
        )
    }
    if out1[Off.result] == 0x84 {
        throw SMCKeyUnavailableError(key: key)
    }
    guard out1[Off.result] == 0 else {
        throw RawSMCError(
            message: "\(key): getKeyInfo result=" +
                String(format: "0x%X", out1[Off.result])
        )
    }

    let dataSize = getNat32(out1, Off.infoSize)
    let codeStr: String = {
        let c = getNat32(out1, Off.infoType)
        return [24,16,8,0].map { Character(UnicodeScalar(UInt8((c >> $0) & 0xFF))) }
            .reduce("") { $0 + String($1) }
    }()

    buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    setNat32(&buf, Off.infoSize, dataSize)
    buf[Off.data8] = 5 // readKey
    let (kr2, out2) = rawCall(buf)
    guard kr2 == kIOReturnSuccess else {
        throw RawSMCError(
            message: "\(key): read kr=" +
                String(format: "0x%X", UInt32(bitPattern: kr2))
        )
    }
    if out2[Off.result] == 0x84 {
        throw SMCKeyUnavailableError(key: key)
    }
    guard out2[Off.result] == 0 else {
        throw RawSMCError(
            message: "\(key): read result=" +
                String(format: "0x%X", out2[Off.result])
        )
    }
    return (codeStr, Array(out2[Off.dataBytes ..< min(Off.dataBytes + Int(dataSize), kBufSize)]))
}

/// Returns nil on success, or a descriptive error string.
/// Error string includes the SMC result code so the user sees *why* a write failed
/// (0x84 = key-not-found, 0x85 = not-writable, etc).
func smcWrite(_ key: String, bytes: [UInt8]) -> String? {
    var buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    buf[Off.data8] = 9 // getKeyInfo
    let (kr1, out1) = rawCall(buf)
    if kr1 != kIOReturnSuccess {
        return "getKeyInfo kr=\(String(format:"0x%X", UInt32(bitPattern: kr1)))"
    }
    if out1[Off.result] != 0 {
        return "getKeyInfo result=\(String(format:"0x%X", out1[Off.result]))"
    }

    buf = [UInt8](repeating: 0, count: kBufSize)
    setNat32(&buf, Off.key, fourCC(key))
    setNat32(&buf, Off.infoSize, UInt32(bytes.count))
    setNat32(&buf, Off.infoType, getNat32(out1, Off.infoType))
    buf[Off.data8] = 6 // writeKey
    for (i, b) in bytes.enumerated() where Off.dataBytes + i < kBufSize {
        buf[Off.dataBytes + i] = b
    }
    let (kr2, out2) = rawCall(buf)
    if kr2 != kIOReturnSuccess {
        return "write kr=\(String(format:"0x%X", UInt32(bitPattern: kr2)))"
    }
    if out2[Off.result] != 0 {
        return "write result=\(String(format:"0x%X", out2[Off.result]))"
    }
    return nil
}

private struct RawSMCError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class RawFanSMCClient: FanSMCClient {
    func read(_ key: String) throws -> SMCValue {
        let value = try smcRead(key)
        return SMCValue(dataType: value.type, bytes: value.bytes)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        if let error = smcWrite(key, bytes: bytes) {
            throw RawSMCError(message: "\(key): \(error)")
        }
    }
}

private func writeServerResponse(ok: Bool, message: String) -> Bool {
    let sanitized = message
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let line = "\(ok ? "OK" : "ERR")\t\(sanitized)\n"
    do {
        try FileHandle.standardOutput.write(contentsOf: Data(line.utf8))
        return true
    } catch {
        return false
    }
}

private enum ServerInput {
    case line(String)
    case timeout
    case end
}

private func readServerInput(timeout: TimeInterval) -> ServerInput {
    let deadline = DispatchTime.now().uptimeNanoseconds +
        UInt64(max(0, timeout) * 1_000_000_000)
    var data = Data()

    while data.count < 16_384 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return .timeout }
        let remainingMilliseconds = min(
            UInt64(Int32.max),
            max(1, (deadline - now) / 1_000_000)
        )
        var descriptor = pollfd(
            fd: STDIN_FILENO,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        let pollResult = Darwin.poll(
            &descriptor,
            1,
            Int32(remainingMilliseconds)
        )
        if pollResult == 0 { return .timeout }
        if pollResult < 0 {
            if errno == EINTR { continue }
            return .end
        }

        var byte: UInt8 = 0
        let count = withUnsafeMutableBytes(of: &byte) { buffer in
            Darwin.read(STDIN_FILENO, buffer.baseAddress, 1)
        }
        if count == 0 { return .end }
        if count < 0 {
            if errno == EINTR { continue }
            return .end
        }
        if byte == 0x0A {
            guard let line = String(data: data, encoding: .utf8) else { return .end }
            return .line(line)
        }
        data.append(byte)
    }
    return .end
}

private func restoreAutomaticWithRetries(
    _ runner: FanCommandRunner
) -> Result<String, Error> {
    var lastError: Error = RawSMCError(message: "Automatic reset did not run")
    for attempt in 0..<3 {
        do {
            return .success(try runner.run(arguments: ["auto"]))
        } catch {
            lastError = error
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.1) }
        }
    }
    return .failure(lastError)
}

private func restoreAutomaticBeforeExit(_ runner: FanCommandRunner) -> Int32 {
    switch restoreAutomaticWithRetries(runner) {
    case .success:
        return 0
    case let .failure(error):
        fputs("Automatic fan recovery failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func runServer(_ runner: FanCommandRunner) -> Int32 {
    signal(SIGPIPE, SIG_IGN)

    while true {
        let line: String
        switch readServerInput(timeout: 12) {
        case let .line(value): line = value
        case .timeout, .end:
            return restoreAutomaticBeforeExit(runner)
        }

        let arguments = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        if arguments == ["heartbeat"] {
            guard writeServerResponse(ok: true, message: "alive") else {
                return restoreAutomaticBeforeExit(runner)
            }
            continue
        }

        if arguments == ["shutdown"] {
            switch restoreAutomaticWithRetries(runner) {
            case let .success(output):
                _ = writeServerResponse(ok: true, message: output)
                return 0
            case let .failure(error):
                _ = writeServerResponse(ok: false, message: error.localizedDescription)
                return 1
            }
        }

        do {
            let output = try runner.run(arguments: arguments)
            guard writeServerResponse(ok: true, message: output) else {
                return restoreAutomaticBeforeExit(runner)
            }
        } catch {
            guard writeServerResponse(ok: false, message: error.localizedDescription) else {
                return restoreAutomaticBeforeExit(runner)
            }
        }
    }
}

private func verifyInstallation() -> Bool {
    guard geteuid() == 0,
          URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path ==
            FanHelperInstallation.executablePath,
          let rule = try? String(
              contentsOfFile: FanHelperInstallation.sudoersPath,
              encoding: .utf8
          ),
          rule == FanHelperInstallation.sudoersRule + "\n",
          let attributes = try? FileManager.default.attributesOfItem(
              atPath: FanHelperInstallation.sudoersPath
          ),
          let owner = attributes[.ownerAccountID] as? NSNumber,
          let permissions = attributes[.posixPermissions] as? NSNumber else {
        return false
    }
    return owner.intValue == 0 && permissions.intValue == 0o440
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
let runningFromInstalledPath =
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path ==
    FanHelperInstallation.executablePath
if arguments == ["verify-install"] {
    guard verifyInstallation() else { exit(1) }
    print(FanHelperInstallation.verificationToken)
    exit(0)
}
if runningFromInstalledPath, arguments != ["serve"] {
    fputs("Installed FanHelper only accepts the leased server protocol\n", stderr)
    exit(1)
}

guard openSMC() else { fputs("Failed to open SMC\n", stderr); exit(1) }

let runner = FanCommandRunner(client: RawFanSMCClient())
var exitCode: Int32 = 0

if arguments == ["serve"] {
    exitCode = runServer(runner)
} else {
    do {
        let output = try runner.run(arguments: arguments)
        print(output)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exitCode = 1
    }
}

IOServiceClose(connection)
if exitCode != 0 { exit(exitCode) }
