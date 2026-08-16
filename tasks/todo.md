# Current work

- [ ] Complete the stable iOS 26 import-camera-compose qualification on a
  physical iPhone and preserve the append-only evidence report.
- [ ] Complete the physical iOS 27 ScreenCaptureKit qualification on the
  dedicated test iPhone and preserve the append-only evidence report.
- [ ] Complete the stable-signed macOS Dual Capture qualification run and preserve its final report.

# Completed this session

- [x] Make Photos movie import the primary iOS 26 Step 1 workflow without
  requesting full photo-library access.
- [x] Persist retained screen sources and replaceable PiP composites, including
  legacy latest-recording migration and presenter retakes from the source.
- [x] Isolate direct ScreenCaptureKit recording behind the iOS 27 SDK and runtime
  availability while keeping stable Xcode 26 archives free of iOS 27 symbols.
- [x] Prepare and verify stable and iOS 27 Release archives plus a signed App
  Store Connect IPA export for Split Capture 1.0 build 2.
- [x] Prevent the Swift 6 actor-isolation crash when PhotoKit saves a completed
  recording and advance the iOS archive build number to 2.
- [x] Add the native iOS 27 SwiftUI ScreenCaptureKit recorder, persistent latest
  recording, Photos add-only saving, sharing, and retry flow.
- [x] Add state-machine and recording-store unit coverage plus the physical
  qualification harness and runbook.
- [x] Configure the iPhone-only Xcode project, automatic signing, app icon,
  privacy descriptions, and valid audio-only background mode.
- [x] Migrate the shared Split Capture application ID to
  `com.lexcorp.splitcapture` across desktop packaging and signing metadata.
- [x] Build against the iOS 27 device SDK and pass all ten unit tests on the
  iOS 27 simulator.
- [x] Add explicit device refresh with selection preservation and delayed camera release handling.
- [x] Delay preview recreation after recording so DirectShow can release the camera cleanly.
- [x] Add native window controls and fullscreen support with F11/Escape shortcuts.
- [x] Suppress the upstream first-run setup wizard in Split OBS builds.
- [x] Finalize active Dual Capture outputs during application exit with an explicit timeout fallback.
- [x] Add a stable local macOS signing helper with pinned-identity verification.
- [x] Add protected fresh-user evidence handoff and a strict qualification finalization gate.
- [x] Add exhaustive finalization fixtures and register them with CTest.
- [x] Document signing, privacy repair, handoff, evidence entry, and final reporting.
