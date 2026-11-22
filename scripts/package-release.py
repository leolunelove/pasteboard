#!/usr/bin/env python3
"""Package the signed native app and its versioned GitHub update manifest."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
mac = root / "mac"
app = mac / "Pasteboard.app"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
output = root / "release"
output.mkdir(exist_ok=True)
archive = output / "Pasteboard-Mac.zip"
with tempfile.TemporaryDirectory(prefix="Pasteboard-release-") as temporary:
    package = Path(temporary) / "Pasteboard"
    package.mkdir()
    subprocess.run(["ditto", str(app), str(package / "Pasteboard.app")], check=True)
    (package / "Read Me.txt").write_text(
        "Pasteboard is an early preview. Move Pasteboard.app to a writable Applications folder.\n"
        "Apple Silicon Mac, macOS 13 or later. Locally signed; not Apple-notarized.\n"
        "Keep a separate backup of important boards.\n"
        "Update from Pasteboard > Check for Updates or App updates in the sidebar.\n"
    )
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(package), str(archive)], check=True)
version = info["CFBundleShortVersionString"]
repository = "https://github.com/leolunelove/pasteboard"
architecture = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/Pasteboard")], text=True).strip().split()
if "arm64" not in architecture:
    raise SystemExit("Build the downloadable preview on Apple Silicon.")
manifest = {
    "formatVersion": 1,
    "version": version,
    "build": int(info["CFBundleVersion"]),
    "appURL": repository + "/releases/tag/v" + version,
    "archiveURL": repository + "/releases/download/v" + version + "/Pasteboard-Mac.zip",
    "releasedAt": "",
    "notes": [line.strip() for line in (mac / "ReleaseNotes.txt").read_text().splitlines() if line.strip()],
    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    "archiveBytes": archive.stat().st_size,
    "architecture": "universal" if len(architecture) > 1 else "arm64",
}
(output / "Pasteboard-Update.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Prepared", version, "build", manifest["build"], "in", output)
