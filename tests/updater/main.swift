import AppKit

func check(_ value: @autoclosure () throws -> Bool, file: String = #fileID, line: Int = #line) throws {
    if try !value() {
        throw NSError(
            domain: "RemoteCheck", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Failed at \(file):\(line)"])
    }
}
func waitFor(_ value: () -> Bool, timeout: Double = 10, file: String = #fileID, line: Int = #line) throws {
    let end = Date().addingTimeInterval(timeout)
    while !value() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try check(value(), file: file, line: line)
}
let directory = URL(fileURLWithPath: "/private/tmp/PasteboardRemoteChecks-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
do { try githubUpdaterTest(directory: directory, app: URL(fileURLWithPath: CommandLine.arguments[1])) } catch
{
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
