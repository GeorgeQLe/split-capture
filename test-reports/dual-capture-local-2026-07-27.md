# Dual Capture Local Test — 2026-07-27

## Overall result

**FAIL — capture startup crashes.** The isolated build and focused-mode smoke tests completed, but the first attempted recording terminated OBS with `SIGSEGV`. Per the acceptance criteria, the audio matrix, long capture, forced-termination capture, waveform analysis, and cross-file synchronization checks were stopped because no valid dual-file capture could be produced.

## Isolated setup

- Recording root: `/tmp/split-obs-dual-capture-20260727-3pp4mU`
- Build: `build_dual_capture_test/frontend/Debug/OBS.app`
- Configuration: macOS Debug, warnings as errors, portable config enabled
- Launch arguments: `--portable --multi --only-bundled-plugins --disable-updater`
- OBS version: 32.2.0
- Custom/Sparkle updater: disabled

The root was created and its exact path recorded before OBS launched. The build completed with `** BUILD SUCCEEDED **`; compile invocations used `-Werror`. `CMAKE_COMPILE_WARNING_AS_ERROR=ON`, the portable-config define, and `SPLIT_OBS_ENABLE_CUSTOM_UPDATER=OFF` are present in the isolated build configuration. The binary reports `OBS Studio - 32.2.0`. Its `Info.plist` reports version 32.2.0 and contains no Sparkle feed or public-key entries.

### Portable startup

The initial launch reported “failed to create user directories.” The portable macOS build had no `OBS.app/Contents/config` directory, and a direct binary launch from the repository root also made the relative portable path resolve to `/Users/georgele/projects/tools/dev/config`. Creating the bundle-local `Contents/config` directory, ad-hoc re-signing the isolated test bundle, and launching with working directory `OBS.app/Contents/MacOS` resolved the startup failure.

The accidentally created sibling directory `/Users/georgele/projects/tools/dev/config` was not inspected or deleted. It is not a recording artifact.

The corrected run logged:

- `Portable mode: true`
- `Third-party plugins disabled.`
- `OBS 32.2.0 (mac)`

### Focused-mode smoke test

| Check | Result | Evidence |
|---|---|---|
| Focused dashboard available | PASS | Dashboard appeared after dismissing the permission review and cancelling the first-run wizard. |
| Opens directly into focused mode | FAIL | The permission review and Auto-Configuration Wizard appeared in front on the fresh portable profile. The permission review appeared again after a clean restart. |
| Desktop preview and selector | PASS | Live Built-in Retina Display preview; selector showed `Built-in Retina Display: 1470x956 @ 0,0`. |
| Desktop native capture and 30 fps | PASS | UI showed native display resolution at 30 fps; manifest recorded 2940×1912 at 30/1. |
| Camera preview and selector | PASS | Live MacBook Air Camera preview and selector. |
| Camera 1920×1080 at 30 fps | PASS | UI and manifest both reported 1920×1080 at 30/1. |
| Readiness/permissions | FAIL | Screen, camera, and input monitoring were granted; microphone access was denied. With microphone route `Both`, Start was nevertheless enabled and the dashboard reported Ready. |
| System-audio readiness | FAIL | The runtime log reported that CoreAudio could not find device UID `default`, but the dashboard still permitted capture. |
| Output estimate | PASS | Displayed approximately 16.2 GB/hour. |
| Meters and audio controls | FAIL | The audio-control region was vertically clipped; selectors, meters, and explanatory text overlapped or were not fully visible in the 760×672 window. |
| Advanced OBS available while idle | PASS | The control was visible and enabled. |
| Persisted settings after clean restart | PASS | Output root, microphone route `Off`, and system-audio enabled state persisted. |

macOS privacy state was not changed. Because microphone permission was already denied, microphone-dependent route cases could not be validly exercised within the test boundary.

### Capture case

Attempted case: microphone route `Off`, system audio enabled.

| Check | Result |
|---|---|
| Start/Stop and control locking | FAIL / blocked by crash |
| Standard OBS output concurrency | Blocked by crash |
| 10–15 second output | FAIL |
| Elapsed time and file growth | FAIL |
| Dropped-frame monitoring | Blocked after 141 ms |
| Valid Hybrid MP4 pair | FAIL |

OBS exited with code 139. The macOS diagnostic report records `EXC_BAD_ACCESS` / `SIGSEGV` at null address on the main thread. The symbolicated stack is:

1. `_platform_strlen`
2. `std::string::__assign_external(char const *)`
3. `DualCaptureRecorder::Start(...)` at `frontend/utility/DualCaptureRecorder.cpp:307`
4. `DualCaptureDashboard::ToggleRecording()` at `frontend/widgets/DualCaptureDashboard.cpp:363`

At line 307, the failed camera-output path assigns `obs_output_get_last_error(camera.output)` directly to `std::string`. The returned pointer was null, so the error-reporting path itself dereferenced null. The desktop output had begun writing before camera startup failed.

Crash report retained at `/Users/georgele/Library/Logs/DiagnosticReports/OBS-2026-07-27-144453.ips`.

### Manifest validation

Session directory:

`/tmp/split-obs-dual-capture-20260727-3pp4mU/2026-07-27_14-44-43`

| Field | Observed | Result |
|---|---|---|
| Schema / session ID | `1` / `39d9fa79-02be-4c60-b93e-730c0f1d4d52` | PASS |
| Start timestamp | `2026-07-27T18:44:43.194Z` | PASS |
| Completion / stop reason | `false` / `recording` | FAIL; correctly incomplete but stale reason |
| Desktop device | Built-in Retina Display, `screen_capture` | PASS |
| Camera device | MacBook Air Camera, `macos-avcapture` | PASS |
| Video | H.264, `obs_x264`, fallback false, 30/1 | PASS as configured only |
| Desktop dimensions/file | 2940×1912 / `desktop.mp4` | PASS as configured only |
| Camera dimensions/file | 1920×1080 / `camera.mp4` | PASS as configured only |
| Audio | AAC, 48 kHz, 192 kbps | PASS as configured only |
| Route / tracks | Off; desktop playback track 1, system isolated track 2; no camera tracks | PASS as configured |
| First packet timestamps | Both null | FAIL |
| Duration / drops | 141 ms; desktop 0, camera 0 | Not meaningful |
| Output errors | Empty string | FAIL; camera startup failed without a persisted error |

### `ffprobe` validation

- `desktop.mp4`: 0 bytes; `moov atom not found`; invalid data.
- `camera.mp4`: missing.
- Codec, dimensions, frame rate, AAC properties, track order, duration, waveform isolation, clap/tone timing, and one-frame cross-file alignment therefore cannot be validated.

### Cases not run after the blocker

- The remaining seven 10–15 second audio/system-audio combinations
- The 30-minute stability capture
- The additional intentional force-termination capture
- Flash, clap, and tone waveform analysis
- Packet-timestamp and final-duration comparison
- Advanced-mode and standard-output exclusion while actively recording

These remain blocked by the capture-start crash. Permission denial/reset, external-device disconnect, Windows behavior, forced storage exhaustion, and forced encoder fallback remain out of scope for this pass as planned.

## Retained artifacts and cleanup boundary

Exactly one recording session directory exists beneath the recorded temporary root:

`/tmp/split-obs-dual-capture-20260727-3pp4mU/2026-07-27_14-44-43`

It originally contained `session.json` and a zero-byte `desktop.mp4`; `camera.mp4` was never created. After explicit approval, only `session.json` and `desktop.mp4` were deleted. The now-empty session directory and recording root remain. The isolated build, portable configuration, logs, crash report, this test report, and source changes are preserved and were not recording-cleanup targets.
