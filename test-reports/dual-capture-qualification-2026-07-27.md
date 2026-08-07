# Dual Capture Qualification Checkpoint — 2026-07-27

## Result

**INCOMPLETE — automated macOS gates pass; interactive capture and Windows gates remain.**

This checkpoint covers the qualification-harness implementation, a fresh macOS
warnings-as-errors build, automated tests, and portable/readiness smoke checks.
It does not claim the full acceptance result described in `docs/dual-capture.md`.

The reusable operator harness and dedicated Windows x64 gate are now
implemented. They have been locally syntax/fixture tested, but no fresh-user
interactive result or Windows workflow URL exists yet, so this checkpoint
remains incomplete.

## Fresh build and automated gates

- Build directory: `build_dual_capture_qualification`
- Product: OBS Studio 32.2.0, Debug, Xcode, arm64, macOS 12 deployment target
- `CMAKE_COMPILE_WARNING_AS_ERROR=ON`
- `ENABLE_PORTABLE_CONFIG=ON`
- `ENABLE_DUAL_CAPTURE_TEST_HOOKS=ON`
- `ENABLE_TESTS=ON`
- `ENABLE_UPDATER=OFF`
- `ENABLE_VIRTUALCAM=OFF` because the legacy DAL virtual-camera target produces
  SDK deprecation diagnostics under warnings-as-errors and is unrelated to Dual
  Capture

The `obs-studio` and `dual-capture-logic-test` targets built successfully.
CTest passed 2/2:

1. `dual-capture-logic`
2. `dual-capture-validator-initialization-error`

`git diff --check`, `bash -n test/dual-capture/validate-session.sh`, and
`shellcheck test/dual-capture/validate-session.sh` also passed.

The generated Xcode project includes `ENABLE_DUAL_CAPTURE_TEST_HOOKS` in the
Debug configuration and omits it from non-Debug configurations. Invalid
failpoint CLI input exits 2; a valid `preflight` input is accepted.

## Portable startup and current readiness

Fresh copied bundle:

`/private/tmp/dual-capture-qualification-portable.hEOL1U/OBS.app`

The rebuilt app reached `Startup complete` and logged `Portable mode: true`.
The only configuration directory found below the copied qualification root was:

`OBS.app/Contents/config`

The focused `Dual Capture` dashboard was the frontmost window. No permissions
review dialog or Auto-Configuration Wizard appeared.

The machine's existing permission state was not changed:

- Screen Recording: granted; Desktop showed Ready at native 1470×956 logical
  display resolution and 30 fps.
- Camera: granted; Camera showed Ready at 1920×1080 and 30 fps.
- Microphone: denied; the dashboard displayed
  `Microphone permission is required for the selected route. Choose Off to
  record without it.` and `Start dual capture` was disabled for the persisted
  Both route.

No privacy database reset or automated permission change was performed.

## Test harness delivered

- Debug-only, one-shot `preflight`, `desktop-start`, and `camera-start`
  failpoints at the recorder transaction boundaries
- Role-prefixed injected errors and existing transactional cleanup path
- Release configurations with no active failpoint parser or behavior
- A `jq`/`ffprobe` session validator covering manifests, streams, codecs,
  dimensions, frame rate, named audio tracks, media size, timestamps, duration,
  alignment, and dropped frames
- CTest coverage for failpoint parsing and an initialization-error fixture
- `qualification-runner.sh` commands for initialization, exact-PID launch,
  new-session association, case capture, 31-sample resource monitoring,
  exact-PID `SIGKILL`, aggregate validation, and immutable report generation
- an append-only JSONL case ledger with timestamps, session path, expected
  routing, artifact sizes, duration bounds, manifest summary, validator log, and
  result
- case-labelled AAC-to-WAV extraction with append-only operator listening
  results
- validator expectations for completed, initialization-error, and interrupted
  recordings, with optional duration bounds and the original directory-only
  interface preserved
- a manually dispatched Windows x64 workflow that enables warnings-as-errors
  and Dual Capture tests, builds `obs-studio` and
  `dual-capture-logic-test` in Debug, and runs the Dual Capture CTest target

All three live injected failures were then exercised with the microphone route
Off and desktop audio On. The validator passed the retained `session.json` for:

- `2026-07-27_16-45-40` — `Desktop: injected preflight failure.`
- `2026-07-27_16-46-39` — `Desktop: injected start failure.`
- `2026-07-27_16-54-31` — `Camera: injected start failure.`

Each directory contains only `session.json`. The camera-start run verified that
the already-started Desktop output is forced to completion asynchronously,
released, and removed before the dashboard controls unlock.

Live testing also found and fixed three lifecycle issues:

- profile settings were updated in memory but not saved atomically
- a forced Hybrid MP4 stop could wait forever for a packet when its synchronized
  partner encoder had not started
- ScreenCaptureKit streams were released before their asynchronous stop
  completion, allowing a late audio callback during shutdown

The rebuilt app subsequently shut down cleanly, and the profile file contains
the persisted qualification output root and microphone route Off.

## Remaining qualification gates

The following require interactive permission/device access, long-running media
stimuli, or a Windows builder and were not run in this checkpoint:

- the pre-grant Screen Recording and Camera blocker states
- Microphone Off-route readiness and post-grant focus refresh
- missing/non-directory/unwritable output paths and active standard-output
  blockers
- minimum-window scrolling and overlap inspection
- all eight 12–15 second routing cases and audio-stimulus isolation checks
- active-session control locking, finalization ordering, and settings persistence
- 30-minute maximum-track stability capture with per-minute RSS/CPU sampling
- live `SIGKILL` Hybrid MP4 recovery
- dispatch and pass the new Windows x64 workflow; record its URL and result

The exact fresh-user, routing, failpoint, stability, recovery, and evidence
procedure is now recorded in `docs/dual-capture-qualification.md`. None of its
interactive results have been inferred from automation.

## Artifacts

The qualification root contains five retained session directories:

- `2026-07-27_16-45-40` — validated preflight failure; only `session.json`
- `2026-07-27_16-46-39` — validated Desktop-start failure; only `session.json`
- `2026-07-27_16-54-31` — validated Camera-start failure; only `session.json`
- `2026-07-27_16-48-59` — interrupted investigation run; `session.json` and
  `desktop.mp4`
- `2026-07-27_16-52-07` — interrupted investigation run; `session.json` and
  `desktop.mp4`

All are retained under:

`/private/tmp/dual-capture-qualification-portable.hEOL1U/captures`

The two interrupted runs exposed the synchronized-output forced-stop deadlock
before it was fixed. They are intentionally retained and are not acceptance
artifacts. The copied app, bundle-local portable configuration, logs, build
directory, and this report are also retained. No files were deleted.

New source artifacts retained in the worktree:

- `test/dual-capture/qualification-runner.sh`
- `test/dual-capture/stimulus-check.sh`
- extended `test/dual-capture/validate-session.sh`
- `docs/dual-capture-qualification.md`
- `.github/workflows/dual-capture-windows-qualification.yaml`

Fresh-user staging artifacts are retained under:

- `/Users/Shared/dual-capture-qualification-20260727T2138Z` — verified
  456 MiB bundle, current runner/validator hashes, and valid app signature
- `/Users/Shared/dual-capture-qualification-20260727T2136Z` — earlier staging
  copy with an extra nested `OBS.app`; retained rather than deleted

Two isolated runner smoke-test roots are also retained under
`/private/tmp/dual-capture-runner-test.ofblRc` and
`/private/tmp/dual-capture-runner-test.PepxLf`. The first records the
event-serialization defect found during smoke testing; the second records the
passing corrected initialization/report test.
