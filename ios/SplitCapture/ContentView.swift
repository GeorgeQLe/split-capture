import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: RecorderViewModel<ScreenCaptureController>
    @State private var selectedMovie: PhotosPickerItem?
    @State private var presenterRecording: RecordingAsset?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    sourceCard
                    if let project = viewModel.project {
                        projectCard(project)
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Split Capture")
        }
        .sheet(item: $presenterRecording) { source in
            PresenterTakeView(recording: source) { result in
                try await viewModel.adoptComposedRecording(result)
            }
        }
        .onChange(of: selectedMovie) { _, item in
            guard let item else { return }
            Task {
                defer { selectedMovie = nil }
                do {
                    guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                        return
                    }
                    await viewModel.importScreenRecording(from: movie.url)
                } catch {
                    viewModel.reportImportFailure(error)
                }
            }
        }
    }

    private var sourceCard: some View {
        VStack(spacing: 18) {
            Image(systemName: viewModel.state == .recording ? "stop.fill" : "rectangle.and.arrow.down")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(viewModel.state == .recording ? Color.red : Color.accentColor)

            VStack(spacing: 6) {
                Text("Step 1 · Add Screen Recording")
                    .font(.title2.bold())
                if viewModel.state == .recording {
                    elapsedTime
                } else {
                    Text("Choose an existing screen recording from Photos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if case .failed(let failure) = viewModel.state {
                VStack(spacing: 4) {
                    Text(failure.message).foregroundStyle(.red)
                    if let suggestion = failure.recoverySuggestion {
                        Text(suggestion).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
            }

            PhotosPicker(selection: $selectedMovie, matching: .videos) {
                Label("Import Screen Recording", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.state.isBusy || viewModel.state == .recording)

            if viewModel.isDirectCaptureAvailable {
                Button {
                    Task { await viewModel.directCaptureAction() }
                } label: {
                    Label(
                        viewModel.state == .recording ? "Stop Direct Recording" : "Record Screen Directly",
                        systemImage: viewModel.state == .recording ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(viewModel.state == .recording ? .red : .accentColor)
                .disabled(viewModel.state.isBusy)
            }

            if viewModel.state.isBusy {
                ProgressView(viewModel.state.title)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
    }

    private func projectCard(_ project: RecordingProject) -> some View {
        let active = project.activeShareAsset
        return VStack(alignment: .leading, spacing: 16) {
            Label(
                project.composite == nil ? project.origin.label : "Finished PiP video",
                systemImage: project.composite == nil ? "video.fill" : "rectangle.inset.filled.and.person.filled"
            )
            .font(.headline)

            HStack {
                metadata("Duration", durationString(active.duration))
                Spacer()
                metadata(
                    "Size",
                    ByteCountFormatter.string(fromByteCount: active.fileSize, countStyle: .file)
                )
            }

            statusLabel(active.photosStatus)

            HStack {
                ShareLink(item: active.localURL) {
                    Label(
                        project.composite == nil ? "Share" : "Share Finished Video",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.borderedProminent)

                if active.photosStatus.canRetry {
                    Button {
                        Task { await viewModel.retrySave() }
                    } label: {
                        Label("Retry Save", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.state.isBusy)
                }
            }

            Divider()
            Label(project.origin.label, systemImage: "rectangle.on.rectangle")
                .font(.subheadline.weight(.medium))
            Text("The original screen source is retained for presenter retakes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                presenterRecording = project.screenSource
            } label: {
                Label(
                    project.composite == nil ? "Step 2 · Add Presenter" : "Retake Presenter",
                    systemImage: "person.crop.rectangle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.state.isBusy)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func statusLabel(_ status: PhotosStatus) -> some View {
        Label(
            status.label,
            systemImage: status == .saved || status == .alreadyInPhotos
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill"
        )
        .font(.subheadline)
        .foregroundStyle(
            status == .saved || status == .alreadyInPhotos ? Color.green : Color.orange
        )
    }

    private var elapsedTime: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(durationString(context.date.timeIntervalSince(viewModel.recordingStartedAt ?? context.date)))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .foregroundStyle(.red)
                .contentTransition(.numericText())
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Screen Recording Yet",
            systemImage: "video.slash",
            description: Text("Import from Photos to begin, then add a presenter in Step 2.")
        )
        .frame(minHeight: 220)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.weight(.medium))
        }
    }

    private func durationString(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct ImportedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                "split-capture-import-\(UUID().uuidString).\(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)"
            )
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}
