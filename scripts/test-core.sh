#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/pasteboard-core-check.XXXXXX")"
trap 'rm -rf -- "$TEST_DIRECTORY"' EXIT
TASK_SOURCES=()
for TASK_SOURCE in "$PROJECT_ROOT"/mac/Source/*.swift; do
  case "${TASK_SOURCE:t}" in App.swift|main.swift) continue ;; esac
  TASK_SOURCES+=("$TASK_SOURCE")
done
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/pasteboard-test-module-cache" \
  -framework AppKit -framework AVKit -framework AVFoundation -framework WebKit -framework UniformTypeIdentifiers \
  "${TASK_SOURCES[@]}" "$PROJECT_ROOT/tests/core/main.swift" -o "$TEST_DIRECTORY/check"
"$TEST_DIRECTORY/check"
