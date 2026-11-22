import AppKit

func check(_ condition: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) throws {
    if !condition() {
        throw NSError(
            domain: "Gather.Check", code: line,
            userInfo: [NSLocalizedDescriptionKey: "Check failed at \(file):\(line)"])
    }
}
func waitFor(_ condition: () -> Bool, timeout: Double = 10, file: String = #fileID, line: Int = #line) throws
{
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    try check(condition(), file: file, line: line)
}
let directory = URL(fileURLWithPath: "/private/tmp/PasteboardChecks-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
do {
    try spacingMathTest()
    try updateChannelTest(directory: directory.appendingPathComponent("releases"))
    try pageHierarchyTest(directory: directory.appendingPathComponent("pages"))
    try workspaceDeletionTest(directory: directory.appendingPathComponent("deletion"))
    try croppingTest(directory: directory.appendingPathComponent("crops"))
    try boardNavigationTest(directory: directory.appendingPathComponent("navigation"))
    try minimapTest(directory: directory.appendingPathComponent("minimap"))
    try svgTest(directory: directory.appendingPathComponent("svg"))
    try swatchTest(directory: directory.appendingPathComponent("swatches"))
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
