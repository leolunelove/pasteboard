# Publish a Mac release

1. Increase `CFBundleShortVersionString` and the integer `CFBundleVersion` in `mac/Info.plist`. The version must use `X.Y.Z`; the build number must increase for every published update.
2. Write the user-facing changes in `mac/ReleaseNotes.txt`.
3. Run `./mac/build.sh`, exercise the app and the relevant native checks, then run `python3 scripts/package-release.py`.
4. Commit the exact source used to build the app.
5. Create a GitHub release tagged `vX.Y.Z` from that commit. Upload **both** `release/Pasteboard-Mac.zip` and `release/Pasteboard-Update.json` before publishing.
6. Mark the release as the latest release. The early-preview status is stated in the README, website and app. GitHub prereleases are not returned by the `/releases/latest/download/` feed.
7. Check the public manifest and download. Exercise **App updates → Update and Relaunch** from an older disposable app copy before announcing the release.
8. Wait for the **Publish website** GitHub Actions workflow to succeed. Verify the version and download at <https://leolunelove.github.io/pasteboard/>. The packaging step updates `website/release.json`; include it in the release's source commit so the GitHub Pages deployment shows the matching version.

Do not replace assets under an already published version. Publish a new version and higher build instead. The manifest’s ZIP size, SHA-256, app version, build and architecture must match the uploaded ZIP.

The installer accepts only the official repository’s versioned release URL. It restricts redirects to GitHub’s HTTPS release CDN, bounds download and unpacked sizes, rejects unsafe ZIP paths and symlinks, checks the app’s bundle identifier/version/code signature, and stages beside the installed app. The helper waits for the old process to exit before replacement. Saved boards live outside the app bundle.

These preview builds use ad-hoc code signing. SHA-256 verifies integrity against the HTTPS release manifest; it is not a Developer ID publisher signature. Apple notarization and Developer ID signing remain future distribution work.
