# Dual Capture Qualification Runbook

This runbook completes the checks that cannot be safely automated: macOS
privacy prompts, device stimuli, UI inspection, a 30-minute capture, and Hybrid
MP4 recovery after forced termination. Never reset TCC, automate a privacy
grant, delete a recording, or reuse a run root containing unrelated evidence.
Retain the temporary user and all artifacts until cleanup is separately
approved.

## Stable local signing

The canonical macOS Debug application is
`build_macos/frontend/Debug/Split Capture.app`. Dual Capture qualification builds must be
created with `build-aux/split-capture-macos-dev.sh`; a default ad-hoc CMake build is
not eligible.

Run the one-time setup from the repository:

```sh
build-aux/split-capture-macos-dev.sh setup
build-aux/split-capture-macos-dev.sh build
```

Setup opens Keychain Access and guides creation of exactly one self-signed RSA
identity named `Split Capture Local Development` in the login Keychain, following
Apple's Certificate Assistant workflow. It is valid for five years and trusted
in the user domain only for code signing. The helper then pins the certificate's
SHA-256 fingerprint under the user's Application Support directory, configures
the existing `macos` preset with `CODESIGN_IDENT`, builds `build_macos`, and
verifies the complete app signature. The private key, certificate passwords,
and local fingerprint file must never be exported or committed.

Before the first build, narrow only this identity's private-key access in
Keychain Access. Select **login** > **My Certificates**, expand
`Split Capture Local Development`, open its private key, and use **Access Control**.
The final settings must be:

- **Confirm before allowing access** selected.
- **Ask for Keychain password** cleared.
- `/usr/bin/codesign` as the sole entry in **Always allow access by these
  applications**.
- **Allow all applications to access this item** not selected.

Remove only inherited entries for the two Certificate Assistant applications,
`racoon`, and `com.apple.ServerManagerDaemon`. Do not alter another key or
identity. Show the final pane to the operator and obtain action-time
confirmation before selecting **Save Changes**. The operator personally enters
the login password into macOS SecurityAgent; an agent must never see, type,
request, or receive it. Do not use `security set-key-partition-list`, export
the identity, or broaden access as a workaround.

Run the disposable one-signature check before starting a full build:

```sh
build-aux/split-capture-macos-dev.sh preflight
```

Approve at most this one `codesign` request. Stop if the request repeats or the
check fails. The helper accepts no password argument or password input and
must never be given a password through stdin, environment variables, a config
file, or a terminal command. A full `build` repeats the same preflight, holds a
local signing lock, and gives Xcode only one job so Keychain requests cannot
race. Its fingerprint directory and file remain outside the repository with
modes `0700` and `0600`; routine successful output does not print the
fingerprint.

For intentional certificate rotation, first quit Split Capture and preserve current
qualification evidence. In Keychain Access, remove only the old
`Split Capture Local Development` certificate and private key, then remove
`~/Library/Application Support/Split Capture Local Development/certificate.sha256`.
Run `setup` and `build` again. Never delete the pin merely to bypass an
unexpected `doctor` failure.

`qualification-runner.sh init` calls the helper's `verify` command before it
creates any evidence. It rejects ad-hoc signatures, CDHash requirements,
invalid nested signatures, wrong bundle identifiers, and certificates that do
not match the pin. A byte-for-byte copy of the verified canonical app may still
be staged for the fresh qualification user.

## Clean permission-flow evidence

Do not reset TCC. The new `io.github.georgeqle.splitcapture` bundle identifier
and `Split Capture Local Development` signing requirement provide a new
permission identity. Initialize the append-only evidence root before the
application's first launch, then use that exact first launch for the clean
Screen & System Audio Recording, Camera, and Microphone prompt sequence.
Record the pre-grant blockers before granting each service.

## Stage and create the fresh user

1. After committing and pushing the rebrand candidate, derive its short commit
   hash and create a new stage named
   `/Users/Shared/split-capture-qualification-<short-sha>-r1`. Never reuse or
   modify a `split-obs` stage or the preserved `724db97` candidate evidence.
2. From the administrator account, use the signing helper to build and verify
   the canonical app. Copy that `Split Capture.app`, `test/dual-capture` scripts, the
   signing helper, and this runbook into a uniquely named directory under
   `/Users/Shared`. Place `split-capture-macos-dev.sh` beside
   `qualification-runner.sh`. Do not modify any prior staging directory.
3. In System Settings, manually create a temporary **standard** user and sign
   into it once, then return to the signing administrator. This supplies fresh
   per-user TCC state without changing a privacy database.
4. Still as the signing administrator, create a unique staging directory below
   `/Users/Shared` that is owned by that administrator and is not group- or
   world-writable. Copy `Split Capture.app` to a unique portable directory below that
   stage. Run the signature-gated protected handoff. Both roots must be new and
   absent, and their immediate parent directories must already exist:

   ```sh
   qualification-runner.sh handoff \
     --user TEMPORARY_SHORT_NAME \
     --app /Users/Shared/.../Split Capture.app \
     --output-root /Users/Shared/.../captures \
     --run-root /Users/Shared/.../run
   ```

   `handoff` verifies the app against the administrator's pinned certificate
   before creating either root, initializes only the empty evidence structure,
   and uses macOS `sudo` to transfer those exact roots to the standard user.
   The administrator personally enters any protected password prompt. The
   identity, private key, password, and fingerprint pin remain in the
   administrator account.
5. Return to the temporary account and initialize the local run-root pointer
   without rerunning the signature gate:

   ```sh
   export DUAL_CAPTURE_QUALIFICATION_RUN_ROOT=/Users/Shared/.../run
   qualification-runner.sh launch
   ```

6. Confirm the launch log says portable mode is active, configuration exists
   only below `Split Capture.app/Contents/config`, the Dual Capture dashboard is
   frontmost, and neither the permissions review nor Auto-Configuration Wizard
   appears.

Record manual observations through the append-only runner command:

```sh
qualification-runner.sh manual-check \
  --check portable_startup --result pass \
  --note "No setup wizard or permissions review appeared."
```

Do not edit or remove prior lines.

The strict gate requires exactly one passing result for each of these IDs:

`canonical_pregrant_blockers`, `canonical_viewport_720x600`,
`signed_rebuild_permission_persistence`, `portable_startup`,
`portable_config_containment`, `fresh_pregrant_blockers`,
`microphone_denied_routes`, `output_path_missing`,
`output_path_regular_file`, `output_path_unwritable`, `blocker_recording`,
`blocker_stream`, `blocker_replay_buffer`, `blocker_virtual_camera`,
`controls_locked`, `viewport_720x600`, `settings_persistence`,
`manifest_ordering`, `camera_release`, `advanced_obs_handoff`,
`stability_responsive`, `stability_no_errors`,
`forced_termination_media_readable`, `forced_relaunch_recovery`, and
`windows_workflow`.

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
Record the workflow URL and result with:

```sh
qualification-runner.sh manual-check \
  --check windows_workflow --result pass \
  --url https://github.com/OWNER/REPOSITORY/actions/runs/RUN_ID \
  --note "Windows x64 warnings-as-errors build and Dual Capture CTests passed."
```

It configures
`windows-ci-x64` with warnings as errors and tests enabled, builds `obs-studio`
and `dual-capture-logic-test` in Debug, and runs the Dual Capture CTest target.
Windows runtime capture is out of scope.

Finally run:

```sh
qualification-runner.sh finalize
qualification-runner.sh validate
qualification-runner.sh report
```

`finalize` rejects duplicates and incomplete or nonpassing evidence. It requires
exactly 13 named cases (the eight short routes, three failpoints, stability,
and forced termination), exact passing listening results for every expected
short-case audio track, 31 passing stability samples, one exact-PID SIGKILL,
all required manual checks, and a passing GitHub Actions run URL.
Qualification passes only if the generated report contains passing evidence for
every permission/readiness/UI/lifecycle/persistence check, all eight short
cases, three failpoints, the 30-minute case, forced-termination recovery, and
the Windows x64 workflow. Preserve both the generated inventory and every older
bundle, session, report, log, and temporary-user artifact.
