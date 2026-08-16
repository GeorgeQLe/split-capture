# Session history

## 2026-08-16

- Lowered the iPhone app deployment target to iOS 26 and made selected Photos
  movie import the primary screen-source workflow without library read access.
- Added persisted source/composite projects, legacy metadata migration, atomic
  replacement, retained-source presenter retakes, and finished-video sharing.
- Moved full-display ScreenCaptureKit into an iOS 27 SDK-gated backend with a
  separate background-mode plist while stable Xcode 26 builds remain import-only.
- Added presenter/compositor integration, expanded persistence and view-model
  coverage to eleven passing tests, and split physical qualification into stable
  iOS 26 and optional iOS 27 tracks.
- Enabled Release product validation and Apple-generic versioning, added export
  compliance metadata and App Store export options, then verified stable and
  iOS 27 archives plus a distribution-signed IPA for version 1.0 build 2.

## 2026-08-14

- Fixed the save-to-Photos crash by making the PhotoKit change closure
  explicitly sendable, preventing it from inheriting main-actor isolation when
  PhotoKit invokes it on its own queue.
- Advanced Split Capture 1.0 to build 2 and rechecked its Release archive
  configuration, privacy description, and opaque 1024px App Store icon.

## 2026-08-07

- Added the native iPhone Split Capture app for full-display ScreenCaptureKit
  recording, optional microphone narration, Photos saving, retained local
  sharing, retry, and state restoration.
- Added the iOS 27 Xcode project, app artwork, automatic-signing metadata, ten
  state/persistence tests, an append-only qualification harness, and a
  physical-device runbook.
- Migrated the shared Split Capture application ID from
  `io.github.georgeqle.splitcapture` to `com.lexcorp.splitcapture` across
  desktop packaging, signing metadata, localized links, and branding checks.
- Removed the invalid `screen-capture` background mode and flattened the app
  icon alpha channel after App Store validation feedback; the corrected archive
  was uploaded.
- Xcode 27 beta 4 and the iOS 27 SDK were verified. The signing-disabled device
  build and all ten simulator unit tests passed; physical ScreenCaptureKit
  qualification remains pending on the dedicated iOS 27 test phone.

## 2026-08-01

- Added a coalesced device refresh action that preserves selected devices and waits for asynchronous camera release before rebuilding previews.
- Delayed post-recording preview recreation to prevent a disconnected DirectShow preview from blocking the next capture.
- Added native minimize, maximize, and close window controls plus fullscreen button, F11 toggle, and Escape exit behavior.
- Validation passed for the complete Windows Debug frontend compile target, the warnings-as-errors Dual Capture logic test, qualification finalization fixtures, and Git whitespace checks.
- Accepted WSL-mounted MSBuild warnings about case-normalized dependency and output paths; direct Qt resource generation and case-correct intermediate directories were used to verify compilation.
- The initialization-error fixture was skipped because its optional `ffprobe` prerequisite is unavailable in this environment.

## 2026-07-31

- Suppressed the upstream first-run setup wizard in Split OBS builds.
- Added idempotent Dual Capture shutdown that waits up to five seconds for active outputs to finalize.
- Marked successful application-exit finalization complete and retained incomplete manifests with `shutdown_timeout` when cleanup exceeds the deadline.
- Added shutdown lifecycle and manifest-completion logic coverage, and documented the application-exit behavior.
- Validation passed for the Debug `obs-studio` and `dual-capture-logic-test` build, all three Dual Capture CTests, and Git whitespace checks.
- Accepted cached-build warnings: bundled Qt frameworks target macOS 13 while the cache targets macOS 12, and generated Xcode copy/script phases report duplicate or always-run notices.
- Formatting validation was skipped because `clang-format` is not installed or available in the current environment.

## 2026-07-27

- Added the stable local macOS code-signing workflow for Dual Capture qualification.
- Hardened fresh-user handoff so evidence roots stay within an administrator-owned, non-writable staging directory under `/Users/Shared`.
- Added append-only manual checks, strict evidence finalization, and exhaustive positive/negative fixtures.
- Updated the qualification runbook and build-helper index.
- Validation passed for Bash syntax, ShellCheck, the targeted warnings-as-errors logic-test build, and all three Dual Capture CTests.
- Accepted an existing cached-build linker warning: bundled Qt frameworks target macOS 13 while the cached test configuration targets macOS 12. The changed Dual Capture target builds without warnings.
