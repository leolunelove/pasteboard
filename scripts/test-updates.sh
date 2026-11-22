#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
TEST_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/pasteboard-update-check.XXXXXX")"
trap 'rm -rf -- "$TEST_DIRECTORY"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/pasteboard-test-module-cache" -framework AppKit \
  "$PROJECT_ROOT"/mac/Source/{Brand,Updates,LocalUpdater,GitHubUpdates}.swift \
  "$PROJECT_ROOT"/tests/updater/{GitHubUpdateChecks,main}.swift \
  -o "$TEST_DIRECTORY/check"
"$TEST_DIRECTORY/check" "$PROJECT_ROOT/mac/Pasteboard.app"
