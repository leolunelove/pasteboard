#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/pasteboard-canvas-check.XXXXXX")"
trap 'rm -rf -- "$TEST_DIRECTORY"' EXIT
TASK_FIXTURE="canvas"
if [[ "${1:-}" == "--benchmark" ]]; then TASK_FIXTURE="performance"; fi
xcrun swiftc -swift-version 5 -O -module-cache-path "${TMPDIR:-/tmp}/pasteboard-test-module-cache" \
  -framework AppKit -framework UniformTypeIdentifiers \
  "$PROJECT_ROOT"/mac/Source/{Brand,Arrangement,ImportIndicator,Model,Backups,Search,Cropping,BoardView,CanvasScene,Export,Snapping,PageTransfers,Swatches,SVGImages,SVGColours,DesignClipboard,WorkspaceOverview,Minimap}.swift \
  "$PROJECT_ROOT/tests/$TASK_FIXTURE/main.swift" -o "$TEST_DIRECTORY/check"
"$TEST_DIRECTORY/check"
