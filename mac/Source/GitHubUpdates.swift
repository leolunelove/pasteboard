import CryptoKit
import Foundation

enum GitHubUpdates {
    static let repository = "https://github.com/leolunelove/pasteboard"
    static let releasesURL = URL(string: repository + "/releases")!
    static let feedURL = URL(string: repository + "/releases/latest/download/Pasteboard-Update.json")!
    static let maximumArchiveBytes = 128 * 1024 * 1024

    static func validate(_ release: LocalRelease) throws {
        guard release.formatVersion == 1, release.build > 0,
            release.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
            release.appURL == repository + "/releases/tag/v" + release.version,
            release.archiveURL == repository + "/releases/download/v" + release.version
                + "/Pasteboard-Mac.zip",
            release.installURL == nil,
            let digest = release.sha256,
            digest.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
            let bytes = release.archiveBytes, bytes > 0, bytes <= maximumArchiveBytes,
            let architecture = release.architecture, ["arm64", "universal"].contains(architecture)
        else {
            throw LocalUpdater.error(
                "The GitHub update record is incomplete or doesn’t match the official Pasteboard release.")
        }
        #if !arch(arm64)
            guard architecture == "universal" else {
                throw LocalUpdater.error("This update needs an Apple Silicon Mac.")
            }
        #endif
    }

    static func verifyArchive(_ data: Data, release: LocalRelease) throws {
        try validate(release)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.archiveBytes, digest == release.sha256?.lowercased() else {
            throw LocalUpdater.error(
                "The download didn’t match the published checksum. Your app is unchanged. Please try again.")
        }
    }

    static func validateArchivePaths(_ names: [String], listing: String, totals: String) throws {
        guard !names.isEmpty, names.count <= 5_000,
            names.allSatisfy({ name in
                !name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/").contains("..")
                    && name.rangeOfCharacter(from: .controlCharacters) == nil
            }),
            !listing.split(separator: "\n").contains(where: { $0.first == "l" }),
            let range = totals.range(of: #"\d+ bytes uncompressed"#, options: .regularExpression),
            let expanded = Int(totals[range].split(separator: " ")[0]), expanded <= 512 * 1024 * 1024
        else {
            throw LocalUpdater.error("The update archive can’t be safely unpacked. Your app is unchanged.")
        }
    }

    static func unpack(_ data: Data, release: LocalRelease, directory: URL) throws -> URL {
        try verifyArchive(data, release: release)
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("Update.zip")
        let expanded = directory.appendingPathComponent("Expanded")
        try data.write(to: archive, options: .atomic)
        let names = try LocalUpdater.run("/usr/bin/unzip", ["-Z1", archive.path]).split(separator: "\n").map(
            String.init)
        let listing = try LocalUpdater.run("/usr/bin/unzip", ["-Z", "-l", archive.path])
        let totals = try LocalUpdater.run("/usr/bin/unzip", ["-Z", "-t", archive.path])
        try validateArchivePaths(names, listing: listing, totals: totals)
        try LocalUpdater.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let app = expanded.appendingPathComponent("Pasteboard/Pasteboard.app")
        try LocalUpdater.validate(app, release: release, identifier: "fun.leolune.gather")
        return app
    }

    static func prepare(
        _ release: LocalRelease, installedAt target: URL, identifier: String, stateDirectory: URL
    ) throws -> PreparedUpdate {
        try validate(release)
        guard let url = URL(string: release.archiveURL), let archiveBytes = release.archiveBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try ReleaseTransport.fetch(
            url, maxBytes: min(archiveBytes, maximumArchiveBytes), timeout: 120)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PasteboardDownload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try unpack(data, release: release, directory: directory)
        var local = release
        local.installURL = app.absoluteString
        return try LocalUpdater.prepare(
            local, installedAt: target, identifier: identifier, stateDirectory: stateDirectory)
    }
}
