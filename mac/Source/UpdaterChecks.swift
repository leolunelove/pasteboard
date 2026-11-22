import AppKit

func localUpdaterTest(directory: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("Latest build's.app"), target = directory.appendingPathComponent("Installed Gather.app"), state = directory.appendingPathComponent("State")
    try fm.copyItem(at: Bundle.main.bundleURL, to: source); try fm.copyItem(at: Bundle.main.bundleURL, to: target)
    let identifier = Bundle.main.bundleIdentifier!, build = (Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String) ?? 0) + 100
    let infoURL = source.appendingPathComponent("Contents/Info.plist")
    var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as! [String: Any]
    info["CFBundleShortVersionString"] = "99.0.0"; info["CFBundleVersion"] = String(build)
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL, options: .atomic)
    try LocalUpdater.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", source.path])
    let release = LocalRelease(formatVersion: 1, version: "99.0.0", build: build, appURL: source.absoluteString, archiveURL: directory.appendingPathComponent("Release.zip").absoluteString, releasedAt: "test", notes: ["Fixture"], installURL: source.absoluteString)
    try fm.createDirectory(at: state, withIntermediateDirectories: true)
    let workspace = Data("preserve workspace data exactly".utf8); try workspace.write(to: state.appendingPathComponent("Workspace.json"))
    let beforeInfo = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
    let cancelled = try LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)
    try check(cancelled.staged != nil && fm.fileExists(atPath: cancelled.staged!.path))
    let unchanged = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")); try check(unchanged == beforeInfo)
    cancelled.cancel(); try check(!fm.fileExists(atPath: cancelled.taskDirectory.path) && !fm.fileExists(atPath: cancelled.staged!.path))
    try check((try? LocalUpdater.prepare(release, installedAt: target, identifier: "wrong.bundle", stateDirectory: state)) == nil)
    // A helper must leave the installed app alone while its process is alive.
    let waiting = try LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)
    let waiter = try waiting.launchHelper(launcher: "/usr/bin/true")
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    let stillOld = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")); try check(waiter.isRunning && stillOld == beforeInfo)
    waiter.terminate(); try waitFor { !waiter.isRunning }; waiting.cancel()
    // Force a failed relaunch and verify the old bundle is restored atomically.
    let failure = try LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)
    let failing = try failure.launchHelper(pid: 999999, launcher: "/usr/bin/false")
    try waitFor { !failing.isRunning }; try check(failing.terminationStatus != 0)
    let rolledBack = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")); try check(rolledBack == beforeInfo && fm.fileExists(atPath: failure.failure.path))
    failure.cancel()
    let prepared = try LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)
    let installing = try prepared.launchHelper(pid: 999999, launcher: "/usr/bin/true")
    try waitFor { !installing.isRunning }; try check(installing.terminationStatus == 0)
    try LocalUpdater.validate(target, release: release, identifier: identifier)
    try check(!fm.fileExists(atPath: prepared.backup.path) && !fm.fileExists(atPath: prepared.failure.path))
    let savedWorkspace = try Data(contentsOf: state.appendingPathComponent("Workspace.json")); try check(savedWorkspace == workspace)
    prepared.cancel()
    let relaunch = try LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)
    try check(relaunch.staged == nil); relaunch.cancel()
    var bad = try JSONSerialization.jsonObject(with: JSONEncoder().encode(release)) as! [String: Any]; bad["installURL"] = "https://example.invalid/update.app"
    let badData = try JSONSerialization.data(withJSONObject: bad); try check((try? LocalRelease.decode(badData)) == nil)
    // Valid release metadata alone is insufficient: a changed signed resource is rejected.
    try Data("tampered".utf8).write(to: source.appendingPathComponent("Contents/Resources/AppIcon.icns"), options: .atomic)
    try check((try? LocalUpdater.prepare(release, installedAt: target, identifier: identifier, stateDirectory: state)) == nil)
    print("PASS: local update staging, bundle/version/signature validation, paths with spaces and quotes, quit-before-replace, rollback, install, relaunch-only and workspace preservation")
}
