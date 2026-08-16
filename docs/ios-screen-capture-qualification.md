# Split Capture iOS qualification runbook

Qualify the stable iOS 26 import workflow and optional iOS 27 direct-capture
workflow as separate tracks. Never upgrade the currently paired iOS 26 phone for
iOS 27 testing; use a second device.

## Track A: stable Xcode 26 and iOS 26 import workflow

Use stable Xcode 26 at `/Applications/Xcode.app`. No beta SDK or toolchain should
be selected.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
xcodebuild -project ios/SplitCapture.xcodeproj -scheme SplitCapture \
  -destination 'platform=iOS,id=<ios-26-device-identifier>' build
```

Confirm the build uses deployment target 26.0, `SplitCapture/Info.plist`, and does
not define `IOS27_DIRECT_CAPTURE`. Inspect the built plist and linked binary to
confirm it contains neither `UIBackgroundModes` nor ScreenCaptureKit references.
The Step 1 direct-recording action must not appear.

Run these scenarios:

1. **Picker privacy and cancellation.** Open **Import Screen Recording**, cancel,
   and confirm the app remains Ready with the previous project unchanged. Select
   a movie and confirm the app never requests full photo-library read access.
2. **Valid import and relaunch.** Import portrait and landscape screen recordings.
   Confirm each is copied into app-owned storage, labeled **Imported from Photos**,
   shareable after force-quit/relaunch, and not duplicated in Photos.
3. **Invalid input.** Exercise an unsupported/corrupt movie and interrupted item
   transfer. Confirm a recoverable import failure appears and the previous project
   and media remain intact.
4. **Atomic replacement.** Import a second valid source. Confirm replacement occurs
   only after validation and persistence, then the former source and composite are
   cleaned up.
5. **Presenter permissions.** Start Step 2, grant front-camera and microphone access,
   and confirm the mirrored preview overlays synchronized source playback.
6. **Composition and retake.** Complete a take, then use **Retake Presenter**. Confirm
   both takes use the retained original source; the second composite replaces only
   the first composite. Only each finished PiP output is newly saved to Photos.
7. **Cancellation and early stop.** Cancel before recording, then stop another take
   before playback ends. Confirm no busy state sticks and the export ends at the
   shorter presenter duration.
8. **Migration.** Install over a build with valid `latest-recording.json` metadata.
   Confirm it migrates into a screen-source-only project and remains shareable.
9. **Photos denial and retry.** Deny add-only access while saving a final PiP,
   confirm the local file remains shareable, then grant access and retry.

## Track B: Xcode 27 SDK and physical iOS 27 direct capture

Select Xcode 27 and confirm its iOS 27 platform support is installed:

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
```

Build the same iOS 26 deployment target for both an iOS 26 and an iOS 27 device.
Confirm `IOS27_DIRECT_CAPTURE` is defined and `Info-iOS27.plist` supplies the
`audio` and `screen-capture` background modes. On iOS 26, direct capture must remain
hidden at runtime. On a physical iOS 27 phone it must appear below import.

On iOS 27, run:

1. picker cancellation;
2. microphone-off capture with app switching and rotation;
3. microphone-on capture with non-DRM system audio and a unique spoken phrase;
4. app stop and Apple system-control stop;
5. background/foreground, Siri interruption, and graceful recovery;
6. screen-only Photos denial and retry;
7. sequential capture replacement and relaunch;
8. presenter composition and retake from the retained direct-capture source.

## Evidence and media verification

Start an append-only evidence run from the repository root:

```sh
scripts/ios-qualification.sh init
scripts/ios-qualification.sh build 'platform=iOS,id=<device-identifier>'
```

The default directory is
`/Users/Shared/split-capture-ios-qualification-<short-sha>-r1`. Use
`SPLIT_CAPTURE_QUALIFICATION_REVISION=r2` for a clean rerun. Save screenshots in
its `screenshots` directory, export each movie to the Mac, and inspect it:

```sh
scripts/ios-qualification.sh import imported-pip /path/to/export.mp4
scripts/ios-qualification.sh verify /Users/Shared/.../exports/imported-pip-....mp4
scripts/ios-qualification.sh result imported-pip PASS 'duration, orientation, PiP, and audio verified'
```

Every export must have a readable nonempty container, one video stream, correct
orientation, expected duration, and expected audio. Finished presenter exports
must additionally have a synchronized lower-right front-camera layer plus source
and presenter audio when both inputs contain audio.

Finish with `scripts/ios-qualification.sh report` and review the generated report
and all referenced evidence before calling either track qualified.
