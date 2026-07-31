# Dual Capture

This fork launches into a purpose-built Desktop + Camera recorder. Stock OBS
remains available through **Advanced OBS** while Dual Capture is idle.

Each recording creates:

```text
YYYY-MM-DD_HH-mm-ss/
├── desktop.mp4
├── camera.mp4
└── session.json
```

Both files are recoverable Hybrid MP4. Their H.264 encoders share an OBS encoder
group, use a fixed 30 fps timebase, and start as one transaction. If either
output stops unexpectedly, its partner is stopped and the manifest records a
partial session.

## Audio tracks

Dual Capture reserves four OBS mixer buses:

1. Desktop playback mix
2. Camera playback mix
3. Isolated microphone
4. Isolated system audio

`desktop.mp4` always has its playable mix on Track 1. When applicable, Track 2
is the isolated microphone and the next track is isolated system audio.
`camera.mp4` has the routed microphone on Track 1 when its route includes the
Camera. Desktop-only and Off routes produce a genuinely video-only camera file.
Camera-embedded audio is disabled.

The microphone route can be Both, Desktop, Camera, or Off. Desktop/system audio
can be enabled independently. All AAC tracks are configured for 48 kHz audio at
192 kbps.

## Session safety

`session.json` is written atomically with `completed: false` before capture
starts. A clean user stop or successfully finalized application exit atomically
replaces it with duration, dropped-frame, track, codec, device, and error data.
Application exit uses the `application_exit` stop reason. If shutdown cleanup
exceeds five seconds, the manifest remains incomplete with `shutdown_timeout`.
A crash therefore leaves recoverable Hybrid MP4 files next to an explicitly
incomplete manifest.

An initialization failure retains the session directory and diagnostic
`session.json`, but removes only the newly created `desktop.mp4` and
`camera.mp4` artifacts.

Standard OBS outputs and switching to Advanced OBS are disabled during Dual
Capture. Managed sources and private scenes never modify the user's scene
collections.

## Qualification hooks

Configure with `-DENABLE_DUAL_CAPTURE_TEST_HOOKS=ON` to make these options
available in Debug builds:

```text
--dual-capture-failpoint=preflight
--dual-capture-failpoint=desktop-start
--dual-capture-failpoint=camera-start
```

Each option injects one failure at the named transaction boundary and is
consumed after the first recording attempt. The first two failures are reported
with a `Desktop:` prefix. The last is injected after Desktop starts and is
reported with a `Camera:` prefix. Non-Debug builds do not compile the option
parser or active failure behavior.

Validate one or more session directories with:

```sh
test/dual-capture/validate-session.sh /path/to/session [...]
test/dual-capture/validate-session.sh \
  --expect completed --min-seconds 12 --max-seconds 15 /path/to/session
```

The validator requires `jq` and `ffprobe`. It prints a result for every session
and returns a nonzero status if any manifest, stream layout, packet timeline,
duration, or dropped-frame check fails. `--expect` also accepts
`initialization-error` and `interrupted`; initialization errors are required to
contain only `session.json`, while interrupted recordings must retain an
incomplete recording-state manifest and two readable Hybrid MP4 files.

The reusable macOS qualification harness is
`test/dual-capture/qualification-runner.sh`. It keeps an append-only JSONL case
ledger, launch logs, validator output, manual-check results, and resource
samples under a caller-owned run root. Its commands are:

```text
init --app APP --output-root DIR --run-root DIR
launch [--failpoint NAME]
capture --case NAME [--min-seconds N --max-seconds N]
monitor --pid PID --minutes 30 --interval 60
kill-capture --pid PID --after 30
validate
report
```

`capture` waits for the operator to start and stop a new session in the
dashboard. `kill-capture` refuses to signal any PID other than the exact OBS PID
recorded by `launch`. No command removes a recording or replaces a prior log,
validator result, resource sample, or generated report.

Use `test/dual-capture/stimulus-check.sh` after each matrix case to extract
case-labelled WAV files and append the operator's tone/voice/clap listening
results. The complete fresh-user procedure and acceptance matrix are in
`docs/dual-capture-qualification.md`.
