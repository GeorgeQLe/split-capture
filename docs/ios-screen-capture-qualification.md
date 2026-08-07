# Split Capture iOS 27 qualification runbook

This qualification is physical-device-only. Never upgrade the currently paired
iOS 26.5.2 phone for this work. Use a separate iPhone running the same iOS 27
beta, release candidate, or final build as the selected Xcode 27 SDK.

## Prerequisites

1. Keep Xcode 26.6 at `/Applications/Xcode.app`.
2. Install Xcode 27 beta 4 (`27A5228h`) as `/Applications/Xcode-beta.app`, then
   install its iOS 27 platform support. Recheck Apple Releases before installing;
   repeat this qualification on the release candidate or final SDK.
3. Select the beta for this shell:

   ```sh
   export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
   xcodebuild -version
   xcrun --sdk iphoneos --show-sdk-version
   ```

4. On the separate iOS 27 iPhone, enable Developer Mode, pair it with Xcode,
   trust the Mac, and confirm it appears in `xcrun devicectl list devices`.
5. In the SplitCapture target, select the Apple Developer team that owns the
   explicit `com.lexcorp.splitcapture` App ID. Do not change the bundle ID.
6. Install `ffmpeg` so the harness can run `ffprobe`.

## Start an append-only evidence run

From the repository root:

```sh
scripts/ios-qualification.sh init
scripts/ios-qualification.sh build 'platform=iOS,id=<device-identifier>'
```

The default evidence directory is
`/Users/Shared/split-capture-ios-qualification-<short-sha>-r1`. The harness only
appends logs and uniquely named artifacts. It refuses to overwrite a report.
Use `SPLIT_CAPTURE_QUALIFICATION_REVISION=r2` for a clean rerun.

Save screenshots into the run’s `screenshots` directory. Export every MP4 to
the Mac, then import and inspect it:

```sh
scripts/ios-qualification.sh import mic-off /path/to/export.mp4
scripts/ios-qualification.sh verify /Users/Shared/.../exports/mic-off-....mp4
scripts/ios-qualification.sh result mic-off PASS '15.1 s; orientation and audio verified'
```

Record failures and blockers too. Never replace evidence from an earlier
attempt.

## Manual scenarios

Run each scenario from a clean install where the scenario says first-run.

1. **First run and permissions.** Verify the initial screen is usable. Start a
   capture with narration enabled and allow microphone access. Finish it and
   allow add-only Photos access. Confirm the app never requests read access to
   the library.
2. **Picker cancellation.** Tap Record Demo, cancel Apple’s picker, and confirm
   the app returns to Ready with no MP4 and no latest-recording replacement.
3. **Microphone off.** Record for 15 seconds with the picker microphone toggle
   off. Switch apps, rotate portrait → landscape → portrait, return, and stop
   in the app.
4. **Microphone on.** Record for 15 seconds with narration and audible,
   non-DRM system audio. Speak a unique phrase. Stop in the app.
5. **System stop.** Start another recording, switch apps, then stop from
   Apple’s system capture control. Return to Split Capture and verify it
   finalized.
6. **Lifecycle and interruption.** Background and foreground during capture.
   Trigger Siri once. Continued capture or graceful finalization is acceptable;
   a stuck Starting, Recording, or Finishing state is not.
7. **Photos denial and retry.** Deny Photos add access. Confirm the local MP4
   remains shareable and Retry Save appears. Grant access in Settings, return,
   retry, and confirm the saved asset.
8. **Replacement and relaunch.** Make two sequential recordings. Confirm the
   second replaces the first only after finalization. Force-quit, relaunch, and
   share the restored latest recording.

For each exported MP4, require:

- a readable, nonempty container;
- duration near the measured capture interval;
- correct rotation/orientation throughout;
- exactly one video stream;
- expected audible system content;
- microphone narration present only when enabled.

Finish with:

```sh
scripts/ios-qualification.sh report
```

Review the generated `test-reports/ios-screen-capture-qualification-YYYY-MM-DD.md`
and all referenced evidence before calling the device qualification complete.
