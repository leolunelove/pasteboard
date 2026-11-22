import AppKit
import CryptoKit

struct PreparedUpdate {
    let target: URL
    let staged: URL?
    let backup: URL
    let helper: URL
    let failure: URL
    let taskDirectory: URL
    func cancel() { if let staged { try? FileManager.default.removeItem(at: staged) }; try? FileManager.default.removeItem(at: taskDirectory) }
    // The helper waits for the old process to exit before replacing anything.
    func launchHelper(pid: Int32 = ProcessInfo.processInfo.processIdentifier, launcher: String = "/usr/bin/open") throws -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [helper.path, String(pid), target.path, staged?.path ?? "", backup.path, failure.path, launcher]
        let handle = try FileHandle(forWritingTo: taskDirectory.appendingPathComponent("Installer.log"))
        process.standardOutput = handle; process.standardError = handle
        try process.run(); try? handle.close(); return process
    }
}

enum LocalUpdater {
    static func error(_ text: String) -> NSError { NSError(domain: "Gather.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw error(String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "The update could not be verified.") }
        return String(data: output, encoding: .utf8) ?? ""
    }
    static func validate(_ app: URL, release: LocalRelease, identifier: String) throws {
        guard app.isFileURL, app.pathExtension.lowercased() == "app",
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundlePackageType"] as? String == "APPL",
              info["CFBundleShortVersionString"] as? String == release.version,
              (info["CFBundleVersion"] as? String).flatMap(Int.init) == release.build,
              let executable = info["CFBundleExecutable"] as? String, executable == URL(fileURLWithPath: executable).lastPathComponent,
              FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path) else { throw error("The update doesn’t match this Pasteboard release. Check again for the latest build.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }
    static func prepare(_ release: LocalRelease, installedAt target: URL, identifier: String, stateDirectory: URL) throws -> PreparedUpdate {
        guard let sourceURL = URL(string: release.installURL ?? release.appURL), sourceURL.isFileURL, target.isFileURL, target.pathExtension == "app" else { throw error("This update location is unavailable.") }
        let source = sourceURL.resolvingSymlinksInPath(), target = target.resolvingSymlinksInPath()
        try validate(source, release: release, identifier: identifier)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GatherUpdater-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Gather-previous-" + UUID().uuidString + ".app")
        var staged: URL?
        do {
            // Building in place can already have replaced the on-disk bundle. In
            // that case only a relaunch is needed, still after signature checks.
            var alreadyInstalled = source == target
            if !alreadyInstalled, (try? validate(target, release: release, identifier: identifier)) != nil {
                let sourceExe = Bundle(url: source)?.executableURL, targetExe = Bundle(url: target)?.executableURL
                if let sourceExe, let targetExe { alreadyInstalled = try SHA256.hash(data: Data(contentsOf: sourceExe)) == SHA256.hash(data: Data(contentsOf: targetExe)) }
            }
            if !alreadyInstalled {
                guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw error("Pasteboard can’t replace this copy. Move it to a writable Applications folder, then try again.") }
                let stage = target.deletingLastPathComponent().appendingPathComponent(".Gather-update-" + UUID().uuidString + ".app"); staged = stage
                try FileManager.default.copyItem(at: source, to: stage)
                try validate(stage, release: release, identifier: identifier)
            }
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let helper = directory.appendingPathComponent("Install.zsh"), failure = stateDirectory.appendingPathComponent("LastUpdateFailure.txt")
            try installerScript.write(to: helper, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("Installer.log").path, contents: nil)
            return PreparedUpdate(target: target, staged: staged, backup: backup, helper: helper, failure: failure, taskDirectory: directory)
        } catch { if let staged { try? FileManager.default.removeItem(at: staged) }; try? FileManager.default.removeItem(at: directory); throw error }
    }
    static let installerScript = #"""
    set -u
    old_pid="$1"
    target="$2"
    staged="$3"
    backup="$4"
    failure="$5"
    launcher="$6"
    for attempt in {1..240}; do
      if ! /bin/kill -0 "$old_pid" 2>/dev/null; then break; fi
      /bin/sleep 0.25
    done
    if /bin/kill -0 "$old_pid" 2>/dev/null; then
      print -r -- "Pasteboard did not quit, so the update was left unchanged." > "$failure"
      [[ -n "$staged" ]] && /bin/rm -rf -- "$staged"
      exit 1
    fi
    if [[ -n "$staged" ]]; then
      if ! /bin/mv -- "$target" "$backup"; then
        print -r -- "The update could not replace this copy of Pasteboard. Your app and boards were kept." > "$failure"
        /bin/rm -rf -- "$staged"
        "$launcher" -n "$target"
        exit 1
      fi
      if ! /bin/mv -- "$staged" "$target"; then
        /bin/mv -- "$backup" "$target"
        print -r -- "The update could not finish. The previous app was restored." > "$failure"
        "$launcher" -n "$target"
        exit 1
      fi
    fi
    if ! /usr/bin/codesign --verify --deep --strict "$target" || ! "$launcher" -n "$target"; then
      print -r -- "The update could not launch. The previous app was restored; please check for updates again." > "$failure"
      if [[ -n "$staged" && -d "$backup" ]]; then
        /bin/mv -- "$target" "$staged"
        /bin/mv -- "$backup" "$target"
        /bin/rm -rf -- "$staged"
        "$launcher" -n "$target"
      fi
      exit 1
    fi
    /bin/rm -f -- "$failure"
    [[ -d "$backup" ]] && /bin/rm -rf -- "$backup"
    exit 0
    """#
}
