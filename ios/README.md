# Split Capture for iPhone

`SplitCapture.xcodeproj` is a native SwiftUI app that requires iOS 27 and Xcode
27. It records full-display demos with ScreenCaptureKit, optionally includes
microphone narration selected in Apple’s picker, retains the latest MP4 for
sharing, and saves a copy with Photos add-only permission.

Open the project with Xcode 27, choose the signing team that owns
`com.lexcorp.splitcapture`, and run on a physical iOS 27 iPhone. ScreenCaptureKit
full-display capture is not supported by the simulator; the simulator is useful
for unit tests and non-capture UI checks only.

The App Store name is managed in App Store Connect as
**Split Capture: Record Demos**. The installed display name is **Split Capture**.
See [the physical qualification runbook](../docs/ios-screen-capture-qualification.md)
for the required device matrix and evidence procedure.
