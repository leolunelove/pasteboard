import AppKit
import CryptoKit

private final class UpdateFixtureProtocol: URLProtocol {
    static var bytes = Data()
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func githubUpdaterTest(directory: URL, app: URL = Bundle.main.bundleURL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("Package/Pasteboard/Pasteboard.app")
    let zip = directory.appendingPathComponent("Release.zip")
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: app, to: source)
    let info =
        try PropertyListSerialization.propertyList(
            from: Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")), format: nil)
        as! [String: Any]
    let version = info["CFBundleShortVersionString"] as! String
    let build = Int(info["CFBundleVersion"] as! String)!
    try LocalUpdater.run(
        "/usr/bin/ditto", ["-c", "-k", "--keepParent", source.deletingLastPathComponent().path, zip.path])
    let archive = try Data(contentsOf: zip)
    var release = LocalRelease(
        formatVersion: 1, version: version, build: build,
        appURL: GitHubUpdates.repository + "/releases/tag/v" + version,
        archiveURL: GitHubUpdates.repository + "/releases/download/v" + version + "/Pasteboard-Mac.zip",
        releasedAt: "test", notes: ["GitHub updates"])
    release.sha256 = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    release.archiveBytes = archive.count
    release.architecture = "arm64"
    let encoded = try JSONEncoder().encode(release)
    try check(try LocalRelease.decode(encoded).isRemote)
    try check(release.availability(installedBuild: build - 1) == .update)
    try check(release.availability(installedBuild: build) == .current)
    try check(release.availability(installedBuild: build + 1) == .newerInstalled)
    var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for (key, value) in [
        ("archiveURL", "http://github.com/leolunelove/pasteboard/file.zip"),
        ("appURL", "https://github.com/another/repository/releases/tag/v" + version), ("sha256", "invalid"),
        ("installURL", source.absoluteString), ("architecture", "x86_64"),
    ] {
        let original = object[key]
        object[key] = value
        try check((try? LocalRelease.decode(JSONSerialization.data(withJSONObject: object))) == nil)
        object[key] = original
    }
    var damaged = archive
    damaged[0] ^= 1
    try check((try? GitHubUpdates.verifyArchive(damaged, release: release)) == nil)
    try check(!ReleaseTransport.trusted(URL(string: "http://github.com/x")!))
    try check(!ReleaseTransport.trusted(URL(string: "https://github.com.evil.invalid/x")!))
    try check(!ReleaseTransport.trusted(URL(string: "https://github.com:444/x")!))
    try check(ReleaseTransport.trusted(URL(string: "https://release-assets.githubusercontent.com/x")!))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [UpdateFixtureProtocol.self]
    UpdateFixtureProtocol.bytes = Data("bounded download".utf8)
    let fetched = try ReleaseTransport.fetch(
        GitHubUpdates.feedURL, maxBytes: 100, timeout: 3, configuration: config)
    try check(fetched == UpdateFixtureProtocol.bytes)
    try check(
        (try? ReleaseTransport.fetch(GitHubUpdates.feedURL, maxBytes: 3, timeout: 3, configuration: config))
            == nil)
    UpdateFixtureProtocol.status = 404
    try check(
        (try? ReleaseTransport.fetch(GitHubUpdates.feedURL, maxBytes: 100, timeout: 3, configuration: config))
            == nil)
    UpdateFixtureProtocol.status = 200
    UpdateFixtureProtocol.bytes = archive
    // Actual network receiver, checksum, extraction, app validation, staging and
    // installer helper on disposable copies; never writes to a user's app/data.
    let target = directory.appendingPathComponent("Installed.app")
    let state = directory.appendingPathComponent("State")
    try fm.copyItem(at: app, to: target)
    let infoURL = target.appendingPathComponent("Contents/Info.plist")
    var oldInfo = info
    oldInfo["CFBundleVersion"] = String(build - 1)
    try PropertyListSerialization.data(fromPropertyList: oldInfo, format: .xml, options: 0).write(to: infoURL)
    try LocalUpdater.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", target.path])
    let beforeInfo = try Data(contentsOf: infoURL)
    try fm.createDirectory(at: state, withIntermediateDirectories: true)
    let board = Data("Keep all boards exactly".utf8)
    try board.write(to: state.appendingPathComponent("Workspace.json"))
    let receivedArchive = try ReleaseTransport.fetch(
        URL(string: release.archiveURL)!, maxBytes: archive.count, timeout: 3, configuration: config)
    let expanded = try GitHubUpdates.unpack(
        receivedArchive, release: release, directory: directory.appendingPathComponent("Download"))
    var local = release
    local.installURL = expanded.absoluteString
    let failed = try LocalUpdater.prepare(
        local, installedAt: target, identifier: "fun.leolune.gather", stateDirectory: state)
    let helper = try failed.launchHelper(pid: 999999, launcher: "/usr/bin/false")
    try waitFor { !helper.isRunning }
    try check(helper.terminationStatus != 0)
    try check(try Data(contentsOf: infoURL) == beforeInfo)
    failed.cancel()
    let prepared = try LocalUpdater.prepare(
        local, installedAt: target, identifier: "fun.leolune.gather", stateDirectory: state)
    let install = try prepared.launchHelper(pid: 999999, launcher: "/usr/bin/true")
    try waitFor { !install.isRunning }
    try check(install.terminationStatus == 0)
    try LocalUpdater.validate(target, release: release, identifier: "fun.leolune.gather")
    try check(try Data(contentsOf: state.appendingPathComponent("Workspace.json")) == board)
    prepared.cancel()
    let totals = "1 file, 0 bytes uncompressed, 0 bytes compressed"
    for name in ["../escape", "/absolute", "folder/../../escape", "folder\\escape"] {
        try check(
            (try? GitHubUpdates.validateArchivePaths([name], listing: "-rw-r--r--", totals: totals)) == nil)
    }
    try check(
        (try? GitHubUpdates.validateArchivePaths(["link"], listing: "lrwxr-xr-x", totals: totals)) == nil)
    try check(
        (try? GitHubUpdates.validateArchivePaths(
            ["safe"], listing: "-rw-r--r--", totals: "1 file, 999999999 bytes uncompressed")) == nil)
    // A checksum matching a bad app must still fail its code-signature check.
    try Data("tampered".utf8).write(to: expanded.appendingPathComponent("Contents/Resources/AppIcon.icns"))
    try check(
        (try? LocalUpdater.validate(expanded, release: release, identifier: "fun.leolune.gather")) == nil)
    print(
        "PASS: official HTTPS release metadata, version comparison, checksums, bounded HTTP downloads/errors, archive paths/symlinks/size, app signature, staged install, rollback and unchanged boards"
    )
}
