import Foundation

struct InstalledRelease {
    let version: String
    let build: Int
    let feedURL: URL?
    let folderURL: URL?
    let bundleURL: URL
    let identifier: String
    init(bundle: Bundle = .main) {
        version =
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        feedURL =
            ((bundle.object(forInfoDictionaryKey: "PasteboardUpdateFeedURL")
            ?? bundle.object(forInfoDictionaryKey: "GatherUpdateFeedURL")) as? String).flatMap(
                URL.init(string:))
        folderURL =
            ((bundle.object(forInfoDictionaryKey: "PasteboardReleaseURL")
            ?? bundle.object(forInfoDictionaryKey: "GatherUpdateFolderURL")) as? String).flatMap(
                URL.init(string:))
        bundleURL = bundle.bundleURL
        identifier = bundle.bundleIdentifier ?? "fun.leolune.gather"
    }
}

struct LocalRelease: Codable {
    let formatVersion: Int
    let version: String
    let build: Int
    let appURL: String
    let archiveURL: String
    let releasedAt: String
    let notes: [String]
    var installURL: String?
    var sha256: String? = nil
    var archiveBytes: Int? = nil
    var architecture: String? = nil
    var isRemote: Bool { URL(string: archiveURL)?.scheme == "https" }
    enum Availability { case update, current, newerInstalled }
    func availability(installedBuild: Int) -> Availability {
        build > installedBuild ? .update : build == installedBuild ? .current : .newerInstalled
    }
    static func decode(_ data: Data) throws -> LocalRelease {
        let release = try JSONDecoder().decode(LocalRelease.self, from: data)
        guard release.formatVersion == 1, release.build > 0, !release.version.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if release.isRemote {
            try GitHubUpdates.validate(release)
            return release
        }
        guard let app = URL(string: release.appURL), app.isFileURL, app.pathExtension.lowercased() == "app",
            let archive = URL(string: release.archiveURL), archive.isFileURL,
            archive.pathExtension.lowercased() == "zip"
        else { throw CocoaError(.fileReadCorruptFile) }
        if let value = release.installURL {
            guard let url = URL(string: value), url.isFileURL, url.pathExtension.lowercased() == "app" else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return release
    }
    static func read(at url: URL) throws -> LocalRelease {
        if url == GitHubUpdates.feedURL {
            let release = try decode(ReleaseTransport.fetch(url, maxBytes: 1_048_576))
            guard release.isRemote else { throw CocoaError(.fileReadCorruptFile) }
            return release
        }
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try decode(Data(contentsOf: url))
    }
}
