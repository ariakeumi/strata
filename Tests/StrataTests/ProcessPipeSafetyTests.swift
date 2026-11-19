import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct ProcessPipeSafetyTests {
    @Test func aClosedSFTPInputThrowsWithoutTerminatingTheApp() async throws {
        let tree = try TestTree()
        let gate = tree.url("gate"), ready = tree.url("ready")
        try #require(mkfifo(gate.path, 0o600) == 0)
        // Close stdin before announcing readiness. Keep stdout open behind a fixture FIFO so the test exercises
        // the failed write itself, independently of the SFTP reader noticing a process exit.
        let script = "exec 0<&-; printf ready > " + ShellQuote.quote(ready.path) + "; exec /bin/cat " + ShellQuote.quote(gate.path)
        let client = try SFTPClient(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], connect: false)
        defer { client.close() }
        // Fail a broken protection policy before deliberately writing to the closed pipe: mutation checks should
        // report an assertion failure, not kill the entire test process.
        try #require(client.suppressesBrokenPipeSignal)
        let deadline = ContinuousClock.now + .seconds(20)
        while !FileManager.default.fileExists(atPath: ready.path) {
            try #require(ContinuousClock.now < deadline, "The fixture did not close its input.")
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = await withCheckedContinuation { (done: CheckedContinuation<Result<Void, Error>, Never>) in
            DispatchQueue.global().async { done.resume(returning: Result { try client.connect() }) }
        }
        if case .success = result { Issue.record("A handshake unexpectedly wrote to a closed pipe.") }
        #expect(!client.isConnected)
        #expect(tree.text("ready") == "ready")
        #expect(tree.snapshot() == ["gate", "ready"])
    }
}
