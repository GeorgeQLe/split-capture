# Dual Capture Qualification Runbook

This runbook completes the checks that cannot be safely automated: macOS
privacy prompts, device stimuli, UI inspection, a 30-minute capture, and Hybrid
MP4 recovery after forced termination. Never reset TCC, automate a privacy
grant, delete a recording, or reuse a run root containing unrelated evidence.
Retain the temporary user and all artifacts until cleanup is separately
approved.

## Stage and create the fresh user

1. From the administrator account, copy the built `OBS.app`, `test/dual-capture`
   scripts, and this runbook into a uniquely named directory under
   `/Users/Shared`. Do not modify any prior staging directory.
2. In System Settings, manually create a temporary **standard** user and sign
   into it. This supplies fresh per-user TCC state without changing a privacy
   database.
3. As the temporary user, create the output and run roots under the shared
   staging directory so that user owns them. Copy `OBS.app` to a unique
   `/private/tmp/dual-capture-qualification-portable.XXXXXX` directory.
4. Initialize from a working directory that may retain
   `.qualification-run-root`:

   ```sh
   qualification-runner.sh init \
     --app /private/tmp/.../OBS.app \
     --output-root /Users/Shared/.../captures \
     --run-root /Users/Shared/.../run
   qualification-runner.sh launch
   ```

5. Confirm the launch log says portable mode is active, configuration exists
   only below `OBS.app/Contents/config`, the Dual Capture dashboard is
   frontmost, and neither the permissions review nor Auto-Configuration Wizard
   appears.

Append manual observations as one JSON object per line to the run root's
`manual-checks.jsonl`, using fields `timestamp`, `check`, `result`, and `note`.
Do not edit or remove prior lines.

## Permission and readiness sequence

Before granting anything, record the specific Screen Recording, Camera, and
Microphone blockers and confirm Start is disabled. Manually grant Screen
Recording and Camera, restarting only when macOS requires it. With Microphone
still denied, confirm Both, Desktop, and Camera are blocked and Off is ready.
Then grant Microphone, return focus to OBS, and confirm readiness refreshes
without restarting.

Also record the exact blockers for a missing output path, a regular-file path,
an unwritable directory, and an active standard OBS recording/stream/replay
buffer/virtual-camera output. At the dashboard minimum of 720×600, scroll from
top to bottom and verify every device selector, permission action, meter,
warning, estimate, statistic, and button is reachable without clipping or
overlap.

## Short routing matrix

Play a continuous distinctive system tone and make recognizable spoken/clap
microphone markers. For each row, run `capture` before starting the dashboard
capture, record for 12–15 seconds, then stop it:

| Case | Microphone route | Desktop audio | Expected Desktop tracks | Expected Camera tracks |
|---|---|---:|---:|---:|
| `both_on` | Both | On | 3 | 1 |
| `both_off` | Both | Off | 2 | 1 |
| `desktop_on` | Desktop | On | 3 | 0 |
| `desktop_off` | Desktop | Off | 2 | 0 |
| `camera_on` | Camera | On | 2 | 1 |
| `camera_off` | Camera | Off | 1 | 1 |
| `off_on` | Off | On | 2 | 0 |
| `off_off` | Off | Off | 1 | 0 |

Example:

```sh
qualification-runner.sh capture \
  --case both_on --min-seconds 12 --max-seconds 15
stimulus-check.sh \
  --case both_on \
  --session /Users/Shared/.../captures/YYYY-MM-DD_HH-mm-ss \
  --output-dir /Users/Shared/.../run/stimulus
```

Every case must have a completed user-stop manifest with no output errors,
H.264/30 fps at native Desktop and 1920×1080 Camera dimensions, the exact named
AAC streams, increasing video packet timestamps, nonzero media, zero drops, and
cross-file start and duration differences no greater than 33.33 ms. Listening
must confirm requested isolated stimuli and the absence of excluded streams.

During one case, verify every mutable Dual Capture control, permission action,
Advanced OBS access, and standard output control stays locked through
finalization. Confirm both MP4 modification times precede or equal the completed
manifest. Change device, route, Desktop-audio, and output settings, restart
cleanly, and record that all settings persist.

## Injected initialization failures

Retain all earlier failure evidence. For each failpoint, cleanly exit OBS,
launch with the named one-shot failpoint, and run `capture` while attempting one
capture:

```sh
qualification-runner.sh launch --failpoint preflight
qualification-runner.sh capture --case failpoint_preflight
```

Repeat for `desktop-start` and `camera-start`. Each directory must contain only
`session.json`. For camera-start, also record that the Desktop partner is
released and standard outputs become available again.

## Thirty-minute stability

Select Both with Desktop audio enabled. Start a case with a 1,800-second lower
bound and run the monitor in another terminal against the exact PID printed by
`launch`:

```sh
qualification-runner.sh capture --case stability_30m --min-seconds 1800
qualification-runner.sh monitor --pid PID --minutes 30 --interval 60
```

The resource gate requires exactly 31 samples. After the five-sample warmup it
fails on ten consecutive RSS increases or a fitted RSS slope above
1,024 KiB/minute. Also record responsive UI, no crash/hang/output errors, zero
drops, valid streams, and one-frame alignment.

## Forced termination and recovery

Launch cleanly and start `capture --case forced_termination --min-seconds 30`.
In another terminal, run:

```sh
qualification-runner.sh kill-capture --pid PID --after 30
```

The command verifies the PID against the current launch record before sending
`SIGKILL`. The case passes only if both Hybrid MP4 files remain readable with
their exact streams and one-frame alignment, while `session.json` remains
incomplete with stop reason `recording`. Relaunch the same portable
installation, verify normal dashboard recovery and persisted settings, and
append that observation.

## Windows and final report

Manually dispatch `.github/workflows/dual-capture-windows-qualification.yaml`.
Record the workflow URL and result in `manual-checks.jsonl`. It configures
`windows-ci-x64` with warnings as errors and tests enabled, builds `obs-studio`
and `dual-capture-logic-test` in Debug, and runs the Dual Capture CTest target.
Windows runtime capture is out of scope.

Finally run:

```sh
qualification-runner.sh validate
qualification-runner.sh report
```

Qualification passes only if the generated report contains passing evidence for
every permission/readiness/UI/lifecycle/persistence check, all eight short
cases, three failpoints, the 30-minute case, forced-termination recovery, and
the Windows x64 workflow. Preserve both the generated inventory and every older
bundle, session, report, log, and temporary-user artifact.
