import AVKit
import SwiftUI

struct PresenterTakeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PresenterTakeController

    init(
        recording: RecordingSummary,
        onFinished: @escaping @MainActor (CompositionResult) async throws -> Void
    ) {
        _controller = StateObject(
            wrappedValue: PresenterTakeController(
                screenRecording: recording,
                onFinished: onFinished
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack(alignment: .bottomTrailing) {
                    VideoPlayer(player: controller.player)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    CameraPreview(session: controller.captureSession)
                        .frame(width: 118, height: 166)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.white.opacity(0.8), lineWidth: 2)
                        }
                        .shadow(radius: 8)
                        .padding(14)
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(maxHeight: 560)

                status
                controls
            }
            .padding()
            .navigationTitle("Step 2 · Add Presenter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                    .disabled(
                        controller.phase == .recording
                            || controller.phase == .finishing
                            || controller.phase == .exporting
                    )
                }
            }
        }
        .task { await controller.prepare() }
        .onDisappear { controller.cancel() }
        .interactiveDismissDisabled(
            controller.phase == .recording
                || controller.phase == .finishing
                || controller.phase == .exporting
        )
    }

    @ViewBuilder
    private var status: some View {
        switch controller.phase {
        case .preparing:
            Label("Preparing front camera…", systemImage: "camera")
        case .ready:
            Text(
                "Use headphones if the screen recording contains audio, then record your presenter take in sync with playback."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        case .recording:
            Label("Recording presenter", systemImage: "record.circle")
                .foregroundStyle(.red)
        case .finishing:
            Label("Finishing camera take…", systemImage: "hourglass")
        case .exporting:
            Label("Compositing picture in picture…", systemImage: "rectangle.inset.filled.and.person.filled")
        case .complete:
            Label("Loom-style video is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }

        if controller.phase.isBusy {
            ProgressView()
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.phase {
        case .ready:
            Button {
                controller.startTake()
            } label: {
                Label("Start Presenter Take", systemImage: "video.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
        case .recording:
            Button {
                controller.stopTake()
            } label: {
                Label("Stop and Compile", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .complete:
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        default:
            EmptyView()
        }
    }
}
