#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/pasteboard-soak.XXXXXX")"
trap 'rm -rf -- "$TEST_DIRECTORY"' EXIT
cp -R "$PROJECT_ROOT/mac/Source" "$TEST_DIRECTORY/Source"
cp "$PROJECT_ROOT/tests/soak/main.swift" "$TEST_DIRECTORY/main.swift"
TASK_SOURCES=("$TEST_DIRECTORY"/Source/{Brand,Arrangement,ImportIndicator,Model,Sections,Backups,Search,Cropping,BoardView,CanvasScene,Export,Snapping,PageTransfers,Swatches,SVGImages,SVGColours,DesignClipboard,WorkspaceOverview,SocialPosts,SocialPreview,Videos,VideoPlayer,Minimap,InteractionChecks}.swift)
xcrun swiftc -swift-version 5 -O -module-cache-path "${TMPDIR:-/tmp}/pasteboard-test-module-cache" \
  -framework AppKit -framework AVKit -framework AVFoundation -framework WebKit -framework UniformTypeIdentifiers \
  "${TASK_SOURCES[@]}" "$TEST_DIRECTORY/main.swift" -o "$TEST_DIRECTORY/check"
"$TEST_DIRECTORY/check" "${1:-60}" "${2:-0.1}"
