// Downloading is compiled out (App Store guideline 5.2.3). Define ENABLE_DOWNLOADS to build it.
#if ENABLE_DOWNLOADS
import SwiftUI

/// Which download picker to present: video quality or audio format.
enum DownloadPickerKind: String, Identifiable {
    case video
    case audio

    var id: String { rawValue }
}

/// Sheet listing the downloadable qualities (video) or formats (audio) for
/// one video, resolved live from the InnerTube clients. Tapping a row starts
/// the download on the shared service and dismisses; progress and completion
/// are surfaced by the existing root/player download alerts.
struct DownloadOptionsView: View {
    let video: Video
    let kind: DownloadPickerKind
    let service: VideoDownloadService

    @Environment(\.dismiss) private var dismiss
    @State private var videoOptions: [VideoDownloadService.VideoDownloadOption]?
    @State private var audioOptions: [VideoDownloadService.AudioDownloadOption]?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(kind == .video ? "Download Video" : "Download Audio")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .video:
            if let videoOptions {
                if videoOptions.isEmpty {
                    emptyState
                } else {
                    List(videoOptions) { option in
                        Button {
                            service.download(video: video, option: option)
                            dismiss()
                        } label: {
                            optionRow(title: option.title, detail: option.detail)
                        }
                    }
                }
            } else {
                loadingState
            }
        case .audio:
            if let audioOptions {
                if audioOptions.isEmpty {
                    emptyState
                } else {
                    List(audioOptions) { option in
                        Button {
                            service.downloadAudio(video: video, option: option)
                            dismiss()
                        } label: {
                            optionRow(title: option.title, detail: option.detail)
                        }
                    }
                }
            } else {
                loadingState
            }
        }
    }

    private func optionRow(title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: AppSymbol.download)
                .foregroundStyle(.primary)
        }
        .contentShape(Rectangle())
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Finding downloadable streams…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Downloadable Streams",
            systemImage: AppSymbol.warning,
            description: Text(
                "YouTube did not offer any directly downloadable streams for this video. "
                    + "This can happen on some music or restricted videos — try another video."
            ))
    }

    private func load() async {
        switch kind {
        case .video:
            videoOptions = await service.fetchVideoOptions(video: video)
        case .audio:
            audioOptions = await service.fetchAudioOptions(video: video)
        }
    }
}
#endif
