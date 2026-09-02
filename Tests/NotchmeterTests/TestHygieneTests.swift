import Foundation
import Testing
@testable import Notchmeter

/// The tests' own discipline. An expectation inside a task nobody awaits runs after its test has finished: it
/// gates nothing, its failures are recorded against no test, and its writes race the `defer` that empties the
/// test's defaults domain, which is how a domain came to be left behind with content in it.
@Suite struct TestHygiene {
    @Test func noTestLeavesItsExpectationsInATaskNobodyAwaits() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.range(of: #"\bTask(\.detached)?\s*(\(.*\))?\s*\{"#, options: .regularExpression) != nil else { continue }
                let awaited = line.contains("await ") || line.contains("= Task")
                #expect(awaited, "\(file.lastPathComponent):\(offset + 1) starts a task nothing waits for")
            }
        }
    }
}
