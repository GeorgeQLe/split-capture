# Split Capture for iPhone

`SplitCapture.xcodeproj` is a native SwiftUI app with a minimum deployment target
of iOS 26. Its primary workflow works with stable Xcode 26:

1. Import an existing screen recording with the system Photos picker. The picker
   grants access only to the selected movie; the app does not request full Photos
   library access.
2. Record a synchronized front-camera presenter take while the source plays.
3. Compile and share the finished lower-right picture-in-picture MP4.

The imported movie is copied immediately into app-owned storage. Split Capture
retains that source separately from the finished video, so **Retake Presenter**
always starts from the original and never creates nested picture in picture. An
imported source is already in Photos and is not saved back; only its finished PiP
video is newly saved. Direct screen recordings retain their existing screen-only
save and retry behavior.

## Stable iOS 26 build

Open the project with stable Xcode 26, choose the signing team that owns
`com.lexcorp.splitcapture`, and run on an iOS 26 or later iPhone. This build uses
`Info.plist`, contains no ScreenCaptureKit iOS 27 backend, and has no screen-capture
background mode. Import, front-camera capture, playback, and AVFoundation
composition remain available.

## Optional iOS 27 direct capture

When built with the iOS 27 SDK, SDK-conditioned project settings define
`IOS27_DIRECT_CAPTURE`, compile `DirectCaptureBackend.swift`, and select
`Info-iOS27.plist` with the `audio` and `screen-capture` background modes. On a
physical iPhone running iOS 27 or later, **Record Screen Directly** then appears as
a secondary Step 1 action. The action stays hidden on iOS 26 even when the app was
built with the iOS 27 SDK.

Direct capture uses ScreenCaptureKit for the full display, system audio, and
optional narration. It is not supported by the simulator. ReplayKit and a
Broadcast Upload extension are intentionally not used.

The App Store name is managed in App Store Connect as **Split Capture: Record
Demos**. The installed display name is **Split Capture**. See
[the qualification runbook](../docs/ios-screen-capture-qualification.md) for the
stable import and optional direct-capture device matrices.

## Archive for App Store Connect

Before each upload, set `MARKETING_VERSION` to the release version and increment
`CURRENT_PROJECT_VERSION` to a build number that has not already been uploaded.
The project uses Apple-generic versioning, so the build number can also be bumped
with `agvtool next-version -all` from the `ios` directory.

For the stable product, select Xcode 26, choose **Any iOS Device (arm64)**, then
use **Product → Archive**. The shared scheme archives the Release configuration,
enables product validation, includes the App Store icon and dSYM, and declares
that the app does not use non-exempt encryption. In Organizer, select
**Distribute App → App Store Connect** and keep automatic signing enabled.

The equivalent command-line archive and local export are:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project SplitCapture.xcodeproj -scheme SplitCapture \
  -destination 'generic/platform=iOS' \
  -archivePath "$PWD/build/SplitCapture.xcarchive" archive
xcodebuild -exportArchive \
  -archivePath "$PWD/build/SplitCapture.xcarchive" \
  -exportPath "$PWD/build/AppStore" \
  -exportOptionsPlist ExportOptions-AppStore.plist
```

Use Xcode 27 for the same steps only when intentionally shipping the optional
direct-capture backend and its `audio` and `screen-capture` background modes.
