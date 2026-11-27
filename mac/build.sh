#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h}"
APP_DIR="$TASK_ROOT/Pasteboard.app"
TASK_ARCH="$(uname -m)"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -module-cache-path "${TMPDIR:-/tmp}/gather-swift-module-cache" -target "$TASK_ARCH-apple-macosx13.0" -framework AppKit -framework AVKit -framework AVFoundation -framework WebKit -framework UniformTypeIdentifiers "$TASK_ROOT"/Source/*.swift -o "$APP_DIR/Contents/MacOS/Pasteboard"
python3 - "$TASK_ROOT/Info.plist" "$APP_DIR/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
source, destination = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads(source.read_bytes())
info.pop('GatherUpdateFeedURL', None)
info.pop('GatherUpdateFolderURL', None)
info['PasteboardUpdateFeedURL'] = 'https://github.com/leolunelove/pasteboard/releases/latest/download/Pasteboard-Update.json'
info['PasteboardReleaseURL'] = 'https://github.com/leolunelove/pasteboard/releases'
destination.write_bytes(plistlib.dumps(info))
PY
if [[ -f "$TASK_ROOT/AppIcon.icns" ]]; then cp "$TASK_ROOT/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
codesign --force --deep --sign - "$APP_DIR"
echo "Built $APP_DIR"
