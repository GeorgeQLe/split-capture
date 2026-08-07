import SwiftUI

@main
struct SplitCaptureApp: App {
    @StateObject private var controller: ScreenCaptureController
    @StateObject private var viewModel: RecorderViewModel<ScreenCaptureController>

    init() {
        let controller = ScreenCaptureController()
        _controller = StateObject(wrappedValue: controller)
        _viewModel = StateObject(
            wrappedValue: RecorderViewModel(controller: controller)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
