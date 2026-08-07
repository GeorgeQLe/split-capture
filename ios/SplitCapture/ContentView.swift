import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: RecorderViewModel<ScreenCaptureController>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    recorderCard
                    if let recording = viewModel.latestRecording {
                        latestRecordingCard(recording)
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Split Capture")
        }
    }

    private var recorderCard: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        viewModel.state == .recording
                            ? Color.red.opacity(0.14)
                            : Color.accentColor.opacity(0.12)
                    )
                    .frame(width: 116, height: 116)
                Image(systemName: viewModel.state == .recording ? "stop.fill" : "record.circle")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(
                        viewModel.state == .recording ? Color.red : Color.accentColor
                    )
            }

            VStack(spacing: 6) {
                Text(viewModel.state.title)
                    .font(.title2.bold())
                if viewModel.state == .recording {
                    elapsedTime
                } else {
                    Text("Record your full display, system audio, and optional narration.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if case .failed(let failure) = viewModel.state {
                VStack(spacing: 4) {
                    Text(failure.message)
                        .foregroundStyle(.red)
                    if let suggestion = failure.recoverySuggestion {
                        Text(suggestion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
            }

            Button {
                Task { await viewModel.primaryAction() }
            } label: {
                Label(
                    viewModel.state == .recording ? "Stop" : "Record Demo",
                    systemImage: viewModel.state == .recording ? "stop.fill" : "record.circle"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.state == .recording ? .red : .accentColor)
            .disabled(viewModel.state.isBusy)

            if viewModel.state.isBusy {
                ProgressView()
                    .accessibilityLabel(viewModel.state.title)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsedString(at: context.date))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(.red)
                .contentTransition(.numericText())
        }
    }

    private func latestRecordingCard(_ recording: RecordingSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Latest Recording", systemImage: "video.fill")
                .font(.headline)

            HStack {
                metadata("Duration", durationString(recording.duration))
                Spacer()
                metadata(
                    "Size",
                    ByteCountFormatter.string(
                        fromByteCount: recording.fileSize,
                        countStyle: .file
                    ))
            }

            Label(
                recording.photosStatus.label,
                systemImage: recording.photosStatus == .saved
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(recording.photosStatus == .saved ? .green : .orange)

            HStack {
                ShareLink(item: recording.localURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                if recording.photosStatus.canRetry {
                    Button {
                        Task { await viewModel.retrySave() }
                    } label: {
                        Label("Retry Save", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.state.isBusy)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Recordings Yet",
            systemImage: "video.slash",
            description: Text("Your latest recording will remain here for sharing after relaunch.")
        )
        .frame(minHeight: 220)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
    }

    private func elapsedString(at date: Date) -> String {
        durationString(date.timeIntervalSince(viewModel.recordingStartedAt ?? date))
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
