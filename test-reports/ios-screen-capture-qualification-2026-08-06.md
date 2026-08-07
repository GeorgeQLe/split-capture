# iOS Screen Capture Qualification

- Repository baseline: `260fb6960`
- Planned evidence directory:
  `/Users/Shared/split-capture-ios-qualification-260fb69-r1`
- Date: 2026-08-06
- Result: **PARTIAL PASS — automated checks pass; physical qualification not run**

## Toolchain readiness

- Xcode 27 beta 4 (`27A5228h`) is installed at
  `/Applications/Xcode-beta.app` with the iOS 27.0 SDK.
- Xcode 26.6 (`17F113`) remains installed at `/Applications/Xcode.app`.
- The machine-wide `xcode-select` setting points to
  `/Applications/Xcode-beta.app/Contents/Developer`; `xcodebuild -version`
  reports Xcode 27.0 (`27A5228h`) without a `DEVELOPER_DIR` override.
- The iOS 27.0 simulator runtime (`24A5390f`) is installed.
- Available disk space after installation: 32 GiB.

## Device blocker

- The only paired device is the existing iPhone 17 Pro Max. Per the
  qualification constraint, it was not upgraded or used as the required
  separate iOS 27 device.

## Completed automated checks

- The project, Info plist, and entitlements parse successfully.
- The shared `SplitCapture` scheme exposes the app and unit-test targets.
- Automatic signing is configured for team `NC56VXK48K` and bundle ID
  `com.lexcorp.splitcapture`.
- Four valid signing identities are present in the login keychain, but no iOS
  App Development provisioning profile for `com.lexcorp.splitcapture` is
  currently installed. Xcode must create or download that profile before the
  first signed device build.
- The app builds successfully against the physical-device iOS 27 SDK with
  signing disabled.
- All ten state-machine and persistence unit tests pass on an iPhone 17 Pro
  simulator running iOS 27.0; zero tests failed or were skipped.
- Test result bundle:
  `/tmp/SplitCapture-Xcode27-installed/Logs/Test/Test-SplitCapture-2026.08.06_20-52-29--0400.xcresult`.
- The 1024 × 1024 app icon is derived from
  `branding/split-capture-icon-1024.png`, with its transparent corners filled
  using the existing navy background color to satisfy iOS icon requirements.
- Source implementation follows Apple’s current iOS 27 ScreenCaptureKit sample
  API surface.

## Work remaining

In Xcode 27, confirm the Apple Developer account for team `NC56VXK48K`, let
automatic signing create or download the provisioning profile, and connect a
separate iPhone running iOS 27. Then execute every physical scenario in
`docs/ios-screen-capture-qualification.md`. ScreenCaptureKit is unavailable in
the simulator, so the microphone, system audio, orientation, interruption,
Photos, and system-stop paths cannot receive a final pass until those runs are
complete. Generate a new report from the append-only harness; do not convert
this partial report to a full pass.
