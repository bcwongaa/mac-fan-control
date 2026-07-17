import Foundation
import Testing
@testable import FanControlKit

@Suite("Fan helper session")
struct FanHelperSessionTests {
    @Test func closedHelperPipeThrowsInsteadOfTerminatingTheApp() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        #expect(FanHelperSession.suppressSIGPIPE(on: pipe.fileHandleForWriting))

        var didThrow = false
        do {
            try pipe.fileHandleForWriting.write(contentsOf: Data("command\n".utf8))
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        try? pipe.fileHandleForWriting.close()
    }
}
