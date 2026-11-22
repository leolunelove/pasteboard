import AppKit
import CryptoKit

enum GitHubUpdates {
    static let repository = "https://github.com/leolunelove/pasteboard"
    static let releasesURL = URL(string: repository + "/releases")!
    static let feedURL = URL(string: repository + "/releases/latest/download/Pasteboard-Update.json")!
    static let maximumArchiveBytes = 128 * 1024 * 1024

    static func validate(_ release: LocalRelease) throws {
        guard release.formatVersion == 1, release.build > 0,
              release.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              release.appURL == repository + "/releases/tag/v" + release.version,
              release.archiveURL == repository + "/releases/download/v" + release.version + "/Pasteboard-Mac.zip",
              release.installURL == nil,
              let digest = release.sha256, digest.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
              let bytes = release.archiveBytes, bytes > 0, bytes <= maximumArchiveBytes,
              let architecture = release.architecture, ["arm64", "universal"].contains(architecture)
        else { throw LocalUpdater.error("The GitHub update record is incomplete or doesn’t match the official Pasteboard release.") }
        #if !arch(arm64)
        guard architecture == "universal" else { throw LocalUpdater.error("This update needs an Apple Silicon Mac.") }
        #endif
    }

    static func verifyArchive(_ data: Data, release: LocalRelease) throws {
        try validate(release)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.archiveBytes, digest == release.sha256?.lowercased() else {
            throw LocalUpdater.error("The download didn’t match the published checksum. Your app is unchanged. Please try again.")
        }
    }

    static func validateArchivePaths(_ names: [String], listing: String, totals: String) throws {
        guard !names.isEmpty, names.count <= 5_000,
              names.allSatisfy({ name in
                  !name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/").contains("..") &&
                  name.rangeOfCharacter(from: .controlCharacters) == nil
              }),
              !listing.split(separator: "\n").contains(where: { $0.first == "l" }),
              let range = totals.range(of: #"\d+ bytes uncompressed"#, options: .regularExpression),
              let expanded = Int(totals[range].split(separator: " ")[0]), expanded <= 512 * 1024 * 1024
        else { throw LocalUpdater.error("The update archive can’t be safely unpacked. Your app is unchanged.") }
    }

    static func unpack(_ data: Data, release: LocalRelease, directory: URL) throws -> URL {
        try verifyArchive(data, release: release)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("Update.zip"), expanded = directory.appendingPathComponent("Expanded")
        try data.write(to: archive, options: .atomic)
        let names = try LocalUpdater.run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n").map(String.init)
        let listing = try LocalUpdater.run("/usr/bin/unzip", ["-Z", "-l", archive.path])
        let totals = try LocalUpdater.run("/usr/bin/unzip", ["-Z", "-t", archive.path])
        try validateArchivePaths(names, listing: listing, totals: totals)
        try LocalUpdater.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let app = expanded.appendingPathComponent("Pasteboard/Pasteboard.app")
        try LocalUpdater.validate(app, release: release, identifier: "fun.leolune.gather")
        return app
    }

    static func prepare(_ release: LocalRelease, installedAt target: URL, identifier: String, stateDirectory: URL) throws -> PreparedUpdate {
        try validate(release)
        guard let url = URL(string: release.archiveURL) else { throw CocoaError(.fileReadCorruptFile) }
        let data = try ReleaseTransport.fetch(url, maxBytes: min(release.archiveBytes!, maximumArchiveBytes), timeout: 120)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteboardDownload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try unpack(data, release: release, directory: directory)
        var local = release; local.installURL = app.absoluteString
        return try LocalUpdater.prepare(local, installedAt: target, identifier: identifier, stateDirectory: stateDirectory)
    }
}

// A bounded, ephemeral HTTPS transfer. Redirects may only reach GitHub's own
// release CDN. No browser cookies or GitHub sign-in are needed for public assets.
final class ReleaseTransport: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var data = Data()
    private var failure: Error?
    private let finished = DispatchSemaphore(value: 0)
    private init(limit: Int) { self.limit = limit }
    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) &&
        ["github.com", "release-assets.githubusercontent.com", "releases.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }
    static func fetch(_ url: URL, maxBytes: Int, timeout: TimeInterval = 15, configuration: URLSessionConfiguration = .ephemeral) throws -> Data {
        guard trusted(url), maxBytes > 0 else { throw LocalUpdater.error("This update address isn’t trusted.") }
        let transfer = ReleaseTransport(limit: maxBytes)
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(timeout, 30); configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: transfer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("Pasteboard-Mac-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
        guard transfer.finished.wait(timeout: .now() + timeout + 1) == .success else { throw URLError(.timedOut) }
        if let failure = transfer.failure { throw failure }
        return transfer.data
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.trusted(url) else {
            failure = LocalUpdater.error("The update redirected outside GitHub. Your app is unchanged.")
            completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let url = response.url, Self.trusted(url), response.expectedContentLength <= limit else {
            failure = LocalUpdater.error("The GitHub download is unavailable or exceeds its expected size. Please try again.")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
        guard data.count <= limit - bytes.count else {
            failure = LocalUpdater.error("The update download exceeds its expected size."); dataTask.cancel(); return
        }
        data.append(bytes)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }
        finished.signal()
    }
}
