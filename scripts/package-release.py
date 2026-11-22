#!/usr/bin/env python3
"""Package the signed Mac app and its matching GitHub update manifest."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

REPOSITORY = "https://github.com/leolunelove/pasteboard"
BUNDLE_IDENTIFIER = "fun.leolune.gather"


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def inspect_app(app):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = int(info["CFBundleVersion"])
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or build < 1:
        raise SystemExit("Use an X.Y.Z version and a positive, increasing build number.")
    if info["CFBundleIdentifier"] != BUNDLE_IDENTIFIER:
        raise SystemExit("The app's bundle identity does not match Pasteboard.")
    architectures = run("lipo", "-archs", str(app / "Contents/MacOS/Pasteboard")).split()
    if "arm64" not in architectures:
        raise SystemExit("Build the downloadable preview on Apple Silicon.")
    return version, build, "universal" if len(architectures) > 1 else "arm64"


def package_archive(app, output):
    temporary_archive = output.with_suffix(".zip.tmp")
    with tempfile.TemporaryDirectory(prefix="Pasteboard-release-") as temporary:
        package = Path(temporary) / "Pasteboard"
        package.mkdir()
        run("ditto", str(app), str(package / "Pasteboard.app"))
        (package / "Read Me.txt").write_text(
            "Pasteboard is an early preview. Move Pasteboard.app to a writable Applications folder.\n"
            "Apple Silicon Mac, macOS 13 or later. Locally signed; not Apple-notarized.\n"
            "Keep a separate backup of important boards.\n"
            "Update from Pasteboard > Check for Updates or App updates in the sidebar.\n"
        )
        run("ditto", "-c", "-k", "--keepParent", str(package), str(temporary_archive))
    temporary_archive.replace(output)


def main():
    root = Path(__file__).resolve().parents[1]
    mac = root / "mac"
    app = mac / "Pasteboard.app"
    version, build, architecture = inspect_app(app)
    output = root / "release"
    output.mkdir(exist_ok=True)
    archive = output / "Pasteboard-Mac.zip"
    package_archive(app, archive)
    manifest = {
        "formatVersion": 1,
        "version": version,
        "build": build,
        "appURL": f"{REPOSITORY}/releases/tag/v{version}",
        "archiveURL": f"{REPOSITORY}/releases/download/v{version}/Pasteboard-Mac.zip",
        "releasedAt": datetime.now(timezone.utc).isoformat(),
        "notes": [
            line.strip()
            for line in (mac / "ReleaseNotes.txt").read_text().splitlines()
            if line.strip()
        ],
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "archiveBytes": archive.stat().st_size,
        "architecture": architecture,
    }
    temporary_manifest = output / ".Pasteboard-Update.json.tmp"
    temporary_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary_manifest.replace(output / "Pasteboard-Update.json")
    website_release = root / "website/release.json"
    website_release.write_text(
        json.dumps(
            {
                "version": version,
                "build": build,
                "bytes": manifest["archiveBytes"],
                "download": manifest["archiveURL"],
                "sha256": manifest["sha256"],
            },
            indent=2,
        ) + "\n"
    )
    print(f"Prepared {version} build {build} in {output}")


if __name__ == "__main__":
    main()
