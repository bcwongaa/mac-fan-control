import Darwin
import Foundation

struct FanHelperRunResult {
    let message: String
    let recoveredSession: Bool
}

final class FanHelperSession {
    private static let commandTimeout: TimeInterval = 25
    private static let heartbeatTimeout: TimeInterval = 3

    private let executablePath: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var hasStartedSession = false
    private var recoveredSessionDuringRun = false

    init(executablePath: String) {
        self.executablePath = executablePath
    }

    static func suppressSIGPIPE(on handle: FileHandle) -> Bool {
        fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1
    }

    func run(arguments: [String]) throws -> FanHelperRunResult {
        recoveredSessionDuringRun = false
        do {
            let startedSession = try ensureRunning()
            if startedSession {
                _ = try exchange(
                    arguments: ["auto"],
                    startIfNeeded: false,
                    timeout: 5
                )
            }
            let message = try exchange(
                arguments: arguments,
                startIfNeeded: false,
                timeout: Self.commandTimeout
            )
            return FanHelperRunResult(
                message: message,
                recoveredSession: recoveredSessionDuringRun
            )
        } catch let error as FanHelperSessionError {
            if error.requiresCleanup { terminateProcess() }
            guard error.isRetryable else {
                try restoreAutomaticBaseline(after: error)
                throw error
            }
            try restoreAutomaticBaseline(after: error)
            do {
                let message = try exchange(
                    arguments: arguments,
                    startIfNeeded: false,
                    timeout: Self.commandTimeout
                )
                return FanHelperRunResult(
                    message: message,
                    recoveredSession: true
                )
            } catch let retryError as FanHelperSessionError {
                if retryError.requiresCleanup { terminateProcess() }
                try restoreAutomaticBaseline(after: retryError)
                throw retryError
            }
        }
    }

    func heartbeat() throws {
        do {
            _ = try exchange(
                arguments: ["heartbeat"],
                startIfNeeded: false,
                timeout: Self.heartbeatTimeout
            )
        } catch let error as FanHelperSessionError {
            if error.requiresCleanup { terminateProcess() }
            throw error
        }
    }

    func shutdown() throws {
        var shutdownError: Error?
        do {
            _ = try run(arguments: ["shutdown"])
        } catch {
            shutdownError = error
        }

        terminateProcess()
        if shutdownError == nil { hasStartedSession = false }
        if let shutdownError { throw shutdownError }
    }

    private func exchange(
        arguments: [String],
        startIfNeeded: Bool,
        timeout: TimeInterval
    ) throws -> String {
        if startIfNeeded {
            _ = try ensureRunning()
        } else if process?.isRunning != true {
            throw FanHelperSessionError.transport("Fan helper session expired")
        }

        guard let input, let output else {
            throw FanHelperSessionError.transport("Fan helper pipes are unavailable")
        }

        let command = arguments.joined(separator: " ") + "\n"
        do {
            try input.write(contentsOf: Data(command.utf8))
        } catch {
            throw FanHelperSessionError.transport(error.localizedDescription)
        }

        let response = try readLine(from: output, timeout: timeout)
        guard let separator = response.firstIndex(of: "\t") else {
            throw FanHelperSessionError.transport("Invalid fan helper response")
        }

        let status = String(response[..<separator])
        let message = String(response[response.index(after: separator)...])
        guard status == "OK" else {
            throw FanHelperSessionError.remote(
                message.isEmpty ? "Fan helper failed" : message
            )
        }
        return message
    }

    private func ensureRunning() throws -> Bool {
        if process?.isRunning == true { return false }
        let restarted = hasStartedSession
        if restarted { recoveredSessionDuringRun = true }
        cleanup()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", executablePath, "serve"]
        task.standardInput = inputPipe
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
        } catch {
            throw FanHelperSessionError.transport(error.localizedDescription)
        }

        let writeHandle = inputPipe.fileHandleForWriting
        guard Self.suppressSIGPIPE(on: writeHandle) else {
            task.terminate()
            throw FanHelperSessionError.transport("Could not secure fan helper pipe")
        }

        process = task
        hasStartedSession = true
        input = writeHandle
        output = outputPipe.fileHandleForReading
        errorOutput = errorPipe.fileHandleForReading
        return true
    }

    private func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        let deadline = DispatchTime.now().uptimeNanoseconds +
            UInt64(max(0, timeout) * 1_000_000_000)
        var data = Data()

        while data.count < 16_384 {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw FanHelperSessionError.timeout("Fan helper response timed out")
            }

            let remainingMilliseconds = min(
                UInt64(Int32.max),
                max(1, (deadline - now) / 1_000_000)
            )
            var descriptor = pollfd(
                fd: handle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(
                &descriptor,
                1,
                Int32(remainingMilliseconds)
            )
            if pollResult == 0 {
                throw FanHelperSessionError.timeout("Fan helper response timed out")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw FanHelperSessionError.transport(
                    String(cString: strerror(errno))
                )
            }

            var byte: UInt8 = 0
            let count = withUnsafeMutableBytes(of: &byte) { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, 1)
            }
            if count == 0 {
                let details = helperExitDetails()
                throw FanHelperSessionError.transport(
                    details.isEmpty ? "Fan helper exited without a response" : details
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw FanHelperSessionError.transport(
                    String(cString: strerror(errno))
                )
            }
            if byte == 0x0A { break }
            data.append(byte)
        }

        guard data.count < 16_384,
              let line = String(data: data, encoding: .utf8) else {
            throw FanHelperSessionError.transport(
                "Fan helper returned an invalid response"
            )
        }
        return line
    }

    private func helperExitDetails() -> String {
        _ = waitForExit(timeout: 0.25)
        guard process?.isRunning != true else { return "" }
        let data = errorOutput?.readDataToEndOfFile() ?? Data()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func terminateProcess() {
        try? input?.close()

        if !waitForExit(timeout: 1), let process, process.isRunning {
            process.terminate()
            if !waitForExit(timeout: 1), process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(timeout: 1)
            }
        }
        cleanup()
    }

    private func restoreAutomaticBaseline(after originalError: Error) throws {
        do {
            _ = try exchange(
                arguments: ["auto"],
                startIfNeeded: true,
                timeout: 5
            )
        } catch {
            terminateProcess()
            throw FanHelperSessionError.transport(
                "\(originalError.localizedDescription); automatic recovery failed: " +
                error.localizedDescription
            )
        }
    }

    private func waitForExit(timeout: TimeInterval) -> Bool {
        guard let process else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private func cleanup() {
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        input = nil
        output = nil
        errorOutput = nil
        process = nil
    }
}

private enum FanHelperSessionError: Error, LocalizedError {
    case transport(String)
    case timeout(String)
    case remote(String)

    var isRetryable: Bool {
        if case .transport = self { return true }
        return false
    }

    var requiresCleanup: Bool {
        if case .remote = self { return false }
        return true
    }

    var errorDescription: String? {
        switch self {
        case let .transport(message),
             let .timeout(message),
             let .remote(message):
            return message
        }
    }
}
