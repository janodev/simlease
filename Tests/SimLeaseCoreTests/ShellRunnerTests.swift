@testable import SimLeaseCore
import Testing

@Suite("Shell process runner")
struct ShellRunnerTests {
    @Test
    func drainsStandardOutputAndErrorConcurrently() throws {
        let byteCount = 131_072
        let script = """
        yes O | head -c \(byteCount) &
        yes E | head -c \(byteCount) >&2 &
        wait
        """

        let result = try ShellRunner().run(["/bin/sh", "-c", script])

        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == byteCount)
        #expect(result.stderr.utf8.count == byteCount)
    }
}
