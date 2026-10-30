// Downloading is compiled out (App Store guideline 5.2.3). Define ENABLE_DOWNLOADS to build it.
#if ENABLE_DOWNLOADS
import AVFoundation
import Foundation
import Observation
import SmartTubeIOSCore
import os

#if os(iOS)
import Photos
#endif
#if os(iOS)
@preconcurrency import ActivityKit
#endif

private let downloadLog = CrashlyticsLogger(category: "Download")

// MARK: - VideoDownloadService
//
// Downloads a YouTube video stream to the device's Photos library.
// Uses InnerTubeAPI to resolve the best stream URL, then downloads the
// file to a temp location before saving it via PHPhotoLibrary.

@MainActor
@Observable
public final class VideoDownloadService {

    // MARK: - State

    public enum DownloadState: Equatable {
        case idle
        case fetching
        case downloading(progress: Double)
        case saving
        case done
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .fetching, .downloading, .saving: return true
            default: return false
            }
        }
    }

    public private(set) var state: DownloadState = .idle

    /// What the most recent download was, so callers can phrase their
    /// completion alert correctly (video → Photos library, audio → in-app
    /// Downloads list).
    public enum CompletedDownloadKind {
        case video
        case audio
    }

    public private(set) var lastCompletedKind: CompletedDownloadKind = .video

    // MARK: - Private

    private let api: InnerTubeAPI
    private var downloadTask: Task<Void, Never>?

    #if os(iOS)
    @available(iOS 16.1, *)
    @ObservationIgnored
    private var liveActivity: Activity<DownloadActivityAttributes>?
    #endif

    /// URLSession used for all YouTube CDN downloads.
    /// httpAdditionalHeaders cannot override User-Agent on iOS — must use URLRequest.setValue.
    private static let cdnSession = URLSession(configuration: .default)

    /// Builds a URLRequest for a YouTube CDN URL.
    /// - `alr=yes` signals the CDN to respond with the full stream rather than an
    ///   initial probe chunk. Without it, adaptive-stream URLs often return 403.
    /// - `userAgent` must match the client that signed the URL (`c=` parameter):
    ///   Web → desktop Chrome, TV-auth → Cobalt, iOS → native iOS app UA.
    nonisolated private static func cdnRequest(
        for url: URL, userAgent: String = InnerTubeClients.iOS.userAgent
    ) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "alr" }) {
            queryItems.append(URLQueryItem(name: "alr", value: "yes"))
        }
        components?.queryItems = queryItems
        let finalURL = components?.url ?? url
        var req = URLRequest(url: finalURL)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - Init

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    // MARK: - Public

    public func download(video: Video) {
        guard !state.isActive else { return }
        lastCompletedKind = .video
        state = .fetching
        #if os(iOS)
        if #available(iOS 16.1, *) {
            startLiveActivity(video: video)
        }
        #endif
        downloadTask = Task { await performDownload(video: video) }
    }

    public func reset() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    // MARK: - Private implementation

    // MARK: Live Activity helpers

    #if os(iOS)
    @available(iOS 16.1, *)
    private func startLiveActivity(video: Video) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = DownloadActivityAttributes(videoTitle: video.title)
        let state = DownloadActivityAttributes.DownloadContentState(progress: 0, phase: .fetching)
        do {
            liveActivity = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            downloadLog.notice("[download] Live Activity unavailable: \(error.localizedDescription)")
        }
    }

    @available(iOS 16.1, *)
    private func updateLiveActivity(
        phase: DownloadActivityAttributes.DownloadContentState.Phase,
        progress: Double = 0
    ) async {
        guard let activity = liveActivity else { return }
        let newState = DownloadActivityAttributes.DownloadContentState(progress: progress, phase: phase)
        // Activity<T> is a Sendable struct; dispatch the await via a nonisolated helper to
        // satisfy Swift 6 region isolation — the value is safely copied out of the @MainActor region.
        await Self.sendActivityUpdate(activity, state: newState)
    }

    @available(iOS 16.1, *)
    private func endLiveActivity(phase: DownloadActivityAttributes.DownloadContentState.Phase) async {
        guard let activity = liveActivity else { return }
        let finalState = DownloadActivityAttributes.DownloadContentState(progress: 1, phase: phase)
        liveActivity = nil  // nil out on @MainActor before sending the value across the boundary
        await Self.sendActivityEnd(activity, state: finalState)
    }

    /// Dispatches `Activity.update` from a nonisolated context.
    /// `Activity<T>` is a `Sendable` struct so transferring it via `sending` is safe.
    @available(iOS 16.1, *)
    nonisolated private static func sendActivityUpdate(
        _ activity: sending Activity<DownloadActivityAttributes>,
        state: DownloadActivityAttributes.DownloadContentState
    ) async {
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Dispatches `Activity.end` from a nonisolated context. See `sendActivityUpdate` for rationale.
    @available(iOS 16.1, *)
    nonisolated private static func sendActivityEnd(
        _ activity: sending Activity<DownloadActivityAttributes>,
        state: DownloadActivityAttributes.DownloadContentState
    ) async {
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4))
    }
    #endif

    // MARK: Download orchestration

    private func performDownload(video: Video) async {
        do {
            guard await requestPhotoAddAccess() else {
                state = .failed("Photo library access is required to save the video")
                #if os(iOS)
                if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
                #endif
                return
            }

            if let tempURL = await tryDirectDownload(videoId: video.id) {
                downloadLog.notice("[download] remuxing for Photos compatibility")
                #if os(iOS)
                if #available(iOS 16.1, *) { await updateLiveActivity(phase: .saving, progress: 1) }
                #endif
                let photosURL = try await passthroughRemux(inputURL: tempURL, videoId: video.id, suffix: "muxed")
                try? FileManager.default.removeItem(at: tempURL)
                state = .saving
                try await saveToPhotoLibrary(fileURL: photosURL)
                storeInDownloadStore(video: video, mergedFileURL: photosURL)
                try? FileManager.default.removeItem(at: photosURL)
                downloadLog.notice("[download] ✅ saved to Photos \(video.id)")
                state = .done
                #if os(iOS)
                if #available(iOS 16.1, *) { await endLiveActivity(phase: .done) }
                #endif
                return
            }

            downloadLog.notice("[download] direct download failed, trying adaptive merge fallback")
            #if os(iOS)
            if #available(iOS 16.1, *) { await updateLiveActivity(phase: .downloading, progress: 0.1) }
            #endif
            let androidInfo = try await api.fetchPlayerInfoAndroid(videoId: video.id)
            downloadLog.notice("[download] adaptive fallback formats=\(androidInfo.formats.count)")
            for (i, fmt) in androidInfo.formats.enumerated() {
                downloadLog.notice(
                    "[download]   [\(i)] mime=\(fmt.mimeType) label=\(fmt.label) hasURL=\(fmt.url != nil) bitrate=\(fmt.bitrate ?? 0)"
                )
            }
            guard let videoURL = androidInfo.bestAdaptiveVideoURL,
                let audioURL = androidInfo.bestAdaptiveAudioURL
            else {
                downloadLog.error("[download] ❌ no adaptive video/audio streams found")
                state = .failed("No downloadable stream found for this video")
                #if os(iOS)
                if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
                #endif
                return
            }
            downloadLog.notice("[download] merging adaptive videoURL prefix=\(videoURL.absoluteString.prefix(60))")
            downloadLog.notice("[download] merging adaptive audioURL prefix=\(audioURL.absoluteString.prefix(60))")
            state = .downloading(progress: 0)
            let mergedURL = try await mergeAdaptiveStreams(
                videoURL: videoURL, audioURL: audioURL, videoId: video.id,
                videoUserAgent: InnerTubeClients.Android.userAgent,
                audioUserAgent: InnerTubeClients.Android.userAgent)
            state = .saving
            #if os(iOS)
            if #available(iOS 16.1, *) { await updateLiveActivity(phase: .saving, progress: 1) }
            #endif
            try await saveToPhotoLibrary(fileURL: mergedURL)
            storeInDownloadStore(video: video, mergedFileURL: mergedURL)
            try? FileManager.default.removeItem(at: mergedURL)
            downloadLog.notice("[download] ✅ adaptive merge saved to Photos \(video.id)")
            state = .done
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .done) }
            #endif
        } catch is CancellationError {
            state = .idle
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
            #endif
        } catch {
            let nsErr = error as NSError
            downloadLog.error(
                "[download] ❌ failed: domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription)")
            let userMessage: String
            if nsErr.domain == "PHPhotosErrorDomain" {
                userMessage =
                    "Could not save to Photos. Please check Settings → Privacy & Security → Photos and allow SmartTube to add photos."
            } else if let urlErr = error as? URLError, urlErr.code == .fileDoesNotExist {
                userMessage = "Download failed — the video file was removed before saving. Please try again."
            } else {
                userMessage = error.localizedDescription
            }
            state = .failed(userMessage)
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
            #endif
        }
    }

    /// Tries Web client then Android client for a direct muxed MP4 download.
    /// Returns the temp file URL on success, nil if no muxed stream could be found.
    /// Note: TVHTML5-signed CDN URLs always return 403 when fetched without session cookies,
    /// so the Android client (c=ANDROID URLs) is used as the reliable fallback.
    private func tryDirectDownload(videoId: String) async -> URL? {
        let candidates: [(String, String, () async throws -> PlayerInfo)] = [
            (
                "Web", InnerTubeClients.Web.userAgent,
                { [self] in try await api.fetchPlayerInfoForDownload(videoId: videoId) }
            ),
            (
                "Android", InnerTubeClients.Android.userAgent,
                { [self] in try await api.fetchPlayerInfoAndroid(videoId: videoId) }
            ),
        ]
        for (label, clientUA, fetch) in candidates {
            guard let info = try? await fetch() else {
                downloadLog.notice("[download] \(label) client failed or UNPLAYABLE, trying next")
                continue
            }
            downloadLog.notice("[download] \(label) formats=\(info.formats.count) hlsURL=\(info.hlsURL != nil)")
            for (i, fmt) in info.formats.enumerated() {
                downloadLog.notice(
                    "[download]   [\(i)] mime=\(fmt.mimeType) label=\(fmt.label) hasURL=\(fmt.url != nil) bitrate=\(fmt.bitrate ?? 0)"
                )
            }
            guard let muxedURL = info.bestMuxedDownloadURL else {
                downloadLog.notice("[download] \(label) — no muxed MP4, trying next")
                continue
            }
            downloadLog.notice("[download] \(label) ✅ muxed URL found, downloading")
            state = .downloading(progress: 0)
            #if os(iOS)
            if #available(iOS 16.1, *) { await updateLiveActivity(phase: .downloading, progress: 0) }
            #endif
            if let tempURL = try? await downloadToTemp(url: muxedURL, videoId: videoId, userAgent: clientUA) {
                let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
                downloadLog.notice("[download] \(label) download complete bytes=\(size)")
                guard size > 0 else {
                    downloadLog.notice("[download] \(label) — 0 bytes, YouTube rejected URL, trying next")
                    try? FileManager.default.removeItem(at: tempURL)
                    continue
                }
                return tempURL
            }
        }
        return nil
    }

    /// Remuxes an MP4 file into a new container using passthrough (no re-encoding).
    /// Fixes PHPhotosErrorDomain 3302 caused by moov-at-end MP4 containers from YouTube.
    private nonisolated func passthroughRemux(inputURL: URL, videoId: String, suffix: String) async throws -> URL {
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId)-\(suffix)-remux.mp4")
        try? FileManager.default.removeItem(at: destURL)
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw URLError(.badServerResponse)
        }
        session.outputURL = destURL
        session.outputFileType = .mp4
        await session.export()
        if let error = session.error {
            downloadLog.error("[download] passthrough remux error: \(error.localizedDescription)")
            throw error
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] passthrough remux done bytes=\(size)")
        return destURL
    }

    /// Downloads best adaptive video-only and audio-only MP4 streams concurrently,
    /// then merges them into a single MP4 using AVAssetWriter for true passthrough
    /// (sample-level copy, no re-encode of codec data).
    private nonisolated func mergeAdaptiveStreams(
        videoURL: URL, audioURL: URL, videoId: String,
        videoUserAgent: String = InnerTubeClients.iOS.userAgent,
        audioUserAgent: String = InnerTubeClients.iOS.userAgent
    ) async throws -> URL {
        // Download both streams concurrently with explicit UA per-request
        let videoReq = VideoDownloadService.cdnRequest(for: videoURL, userAgent: videoUserAgent)
        let audioReq = VideoDownloadService.cdnRequest(for: audioURL, userAgent: audioUserAgent)
        async let videoTemp = VideoDownloadService.cdnSession.download(for: videoReq)
        async let audioTemp = VideoDownloadService.cdnSession.download(for: audioReq)
        let (videoResult, audioResult) = try await (videoTemp, audioTemp)

        let videoStatus = (videoResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let audioStatus = (audioResult.1 as? HTTPURLResponse)?.statusCode ?? 0
        let videoFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-vid.mp4")
        let audioFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-aud.mp4")
        try? FileManager.default.removeItem(at: videoFile)
        try? FileManager.default.removeItem(at: audioFile)
        try FileManager.default.moveItem(at: videoResult.0, to: videoFile)
        try FileManager.default.moveItem(at: audioResult.0, to: audioFile)

        let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int) ?? 0
        let audioSize = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? 0
        downloadLog.notice(
            "[download] adaptive downloaded videoStatus=\(videoStatus) video=\(videoSize)B audioStatus=\(audioStatus) audio=\(audioSize)B"
        )

        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }

        guard videoSize > 0, audioSize > 0 else {
            throw URLError(.zeroByteResource)
        }

        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(videoId)-merged.mp4")
        try? FileManager.default.removeItem(at: destURL)

        // Use AVAssetWriter for true passthrough mux — reads compressed samples directly
        // from the source tracks and writes them to the new container without decoding.
        let videoAsset = AVURLAsset(url: videoFile)
        let audioAsset = AVURLAsset(url: audioFile)

        let videoTrackSrc = try await videoAsset.loadTracks(withMediaType: .video).first
        let audioTrackSrc = try await audioAsset.loadTracks(withMediaType: .audio).first
        guard let videoTrackSrc, let audioTrackSrc else {
            throw URLError(.badServerResponse)
        }

        let videoFmt = try await videoTrackSrc.load(.formatDescriptions).first!
        let audioFmt = try await audioTrackSrc.load(.formatDescriptions).first!
        let duration = try await videoAsset.load(.duration)

        let writer = try AVAssetWriter(outputURL: destURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFmt)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFmt)
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        writer.add(audioInput)

        let videoReader = try AVAssetReader(asset: videoAsset)
        let audioReader = try AVAssetReader(asset: audioAsset)
        let videoOut = AVAssetReaderTrackOutput(track: videoTrackSrc, outputSettings: nil)
        let audioOut = AVAssetReaderTrackOutput(track: audioTrackSrc, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        audioOut.alwaysCopiesSampleData = false
        videoReader.add(videoOut)
        audioReader.add(audioOut)

        writer.startWriting()
        videoReader.startReading()
        audioReader.startReading()
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "com.smarttube.merge", qos: .userInitiated)
            nonisolated(unsafe) let videoInput = videoInput
            nonisolated(unsafe) let videoOut = videoOut
            nonisolated(unsafe) let audioInput = audioInput
            nonisolated(unsafe) let audioOut = audioOut
            nonisolated(unsafe) let writer = writer

            group.enter()
            videoInput.requestMediaDataWhenReady(on: queue) {
                while videoInput.isReadyForMoreMediaData {
                    if let buf = videoOut.copyNextSampleBuffer() {
                        videoInput.append(buf)
                    } else {
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.enter()
            audioInput.requestMediaDataWhenReady(on: queue) {
                while audioInput.isReadyForMoreMediaData {
                    if let buf = audioOut.copyNextSampleBuffer() {
                        audioInput.append(buf)
                    } else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            group.notify(queue: queue) {
                writer.finishWriting {
                    if let err = writer.error {
                        cont.resume(throwing: err)
                    } else {
                        cont.resume()
                    }
                }
            }
        }

        let mergedSize = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] adaptive merge done bytes=\(mergedSize)")
        _ = duration  // suppress unused warning
        return destURL
    }

    private func requestPhotoAddAccess() async -> Bool {
        #if os(iOS)
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            downloadLog.notice("[download] Photos access already authorized")
            return true
        case .notDetermined:
            downloadLog.notice("[download] Requesting Photos add-only permission")
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            let result = granted == .authorized || granted == .limited
            downloadLog.notice("[download] Photos permission result: \(result ? "granted" : "denied")")
            return result
        case .denied:
            downloadLog.error(
                "[download] ❌ Photos access denied — user must enable in Settings → Privacy & Security → Photos")
            return false
        case .restricted:
            downloadLog.error("[download] ❌ Photos access restricted by device policy")
            return false
        @unknown default:
            downloadLog.error("[download] ❌ Unknown Photos authorization status")
            return false
        }
        #else
        return false
        #endif
    }

    /// Copies `mergedFileURL` to the DownloadStore destination and registers the download.
    /// If the copy fails (e.g. disk full) the Photos save is unaffected — this is best-effort.
    // MARK: - Download options (quality / format picker)

    /// A format paired with the User-Agent of the InnerTube client that
    /// produced its URL. CDN URLs are signed per client (`c=` parameter), so
    /// downloads must present the same UA or the CDN answers 403.
    public struct ResolvedFormat: Sendable {
        public let format: VideoFormat
        public let userAgent: String
    }

    /// One selectable video quality for the download picker.
    public struct VideoDownloadOption: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let detail: String
        /// Adaptive H.264 video + separate audio, merged locally. Nil otherwise.
        public let video: ResolvedFormat?
        public let audio: ResolvedFormat?
        /// Pre-muxed MP4 (itag 18/22 style). Nil otherwise.
        public let muxed: ResolvedFormat?
        /// The player's own HLS stream, exported to MP4 by AVFoundation.
        /// Nil otherwise. This is the primary path since v5: direct adaptive
        /// URLs are rejected by the CDN on device (the app has no on-device
        /// n-parameter descrambler), while the HLS path is the exact stream
        /// the player already plays successfully.
        public let hlsURL: URL?
    }

    /// Audio output formats offered by the picker. MP3 is intentionally not
    /// listed: iOS has no MP3 encoder in AVFoundation.
    public enum AudioFormatKind: String, CaseIterable, Sendable {
        case original
        case aac256
        case aac128
        case aac64
        case wav
        case m4r

        public var fileExtension: String {
            switch self {
            case .original, .aac256, .aac128, .aac64: return "m4a"
            case .wav: return "wav"
            case .m4r: return "m4r"
            }
        }

        /// Target bitrate for transcoded AAC outputs; nil = keep source / PCM.
        public var aacBitrate: Int? {
            switch self {
            case .aac256: return 256_000
            case .aac128, .m4r: return 128_000
            case .aac64: return 64_000
            case .original, .wav: return nil
            }
        }
    }

    /// One selectable audio output for the download picker.
    public struct AudioDownloadOption: Identifiable, Sendable {
        public let kind: AudioFormatKind
        public var id: String { kind.rawValue }
        public let title: String
        public let detail: String
        /// Best available audio stream, downloaded first, then converted.
        public let source: ResolvedFormat
        /// True when `source` is a muxed video file whose audio track is
        /// extracted locally (fallback when no direct audio stream works).
        public let sourceIsMuxedVideo: Bool
        /// Optional muxed-video source to try if the primary audio stream is
        /// rejected or returns an empty response.
        public let fallbackSource: ResolvedFormat?
    }

    private struct ClientSource {
        let label: String
        let userAgent: String
        let fetch: () async throws -> PlayerInfo
    }

    /// Clients tried when resolving downloadable streams, in order. The iOS
    /// client comes first: it is the only one guaranteed to return adaptive
    /// formats with plain URLs for most videos (Web returns cipher-protected
    /// adaptive URLs; Android has started doing the same on many videos,
    /// which is why v1 audio downloads found no stream at all).
    private func clientSources(videoId: String) -> [ClientSource] {
        [
            ClientSource(
                label: "iOS", userAgent: InnerTubeClients.iOS.userAgent,
                fetch: { [self] in try await api.fetchPlayerInfo(videoId: videoId) }),
            ClientSource(
                label: "Android", userAgent: InnerTubeClients.Android.userAgent,
                fetch: { [self] in try await api.fetchPlayerInfoAndroid(videoId: videoId) }),
            ClientSource(
                label: "AndroidVR", userAgent: InnerTubeClients.AndroidVR.userAgent,
                fetch: { [self] in try await api.fetchPlayerInfoAndroidVR(videoId: videoId) }),
            ClientSource(
                label: "Web", userAgent: InnerTubeClients.Web.userAgent,
                fetch: { [self] in try await api.fetchPlayerInfoForDownload(videoId: videoId) }),
        ]
    }

    /// Fetches player info from every client that answers and pairs each
    /// format with its client's UA. TV-authenticated (SABR) fetches are
    /// deliberately not used — their URLs are not directly downloadable.
    /// Also captures the first HLS manifest URL any client offers.
    private func resolveAllFormats(videoId: String) async -> (
        formats: [ResolvedFormat], hlsURL: URL?
    ) {
        var resolved: [ResolvedFormat] = []
        var hlsURL: URL?
        for source in clientSources(videoId: videoId) {
            guard let info = try? await source.fetch() else {
                downloadLog.notice("[download] resolve: \(source.label) client failed, skipping")
                continue
            }
            if hlsURL == nil { hlsURL = info.hlsURL }
            let withURL = info.formats.filter { $0.url != nil }
            downloadLog.notice(
                "[download] resolve: \(source.label) formats=\(info.formats.count) withURL=\(withURL.count)"
            )
            resolved += withURL.map { ResolvedFormat(format: $0, userAgent: source.userAgent) }
        }
        return (resolved, hlsURL)
    }

    private static func formatSize(_ bytes: Double) -> String {
        if bytes >= 1_000_000 {
            return String(format: "~%.0f MB", bytes / 1_000_000)
        }
        return String(format: "~%.0f KB", bytes / 1_000)
    }

    private static func isAdaptiveAVC(_ f: VideoFormat) -> Bool {
        f.mimeType.hasPrefix("video/mp4") && !f.mimeType.contains(", ")
            && f.mimeType.contains("avc1")
    }

    private static func isMuxed(_ f: VideoFormat) -> Bool {
        f.mimeType.hasPrefix("video/mp4") && f.mimeType.contains(", ")
    }

    private static func isAudioMP4(_ f: VideoFormat) -> Bool {
        f.mimeType.hasPrefix("audio/mp4")
    }

    /// Builds the download list for the video picker.
    ///
    /// The HLS option is intentionally first: it exports the same playback
    /// stream AVPlayer is already able to play, instead of asking the CDN for
    /// a raw adaptive file whose signed URL may be rejected. The pre-muxed
    /// file is the proven fallback. Direct adaptive heights remain last and
    /// are labelled experimental because YouTube may return an empty file.
    public func fetchVideoOptions(video: Video) async -> [VideoDownloadOption] {
        let resolved = await resolveAllFormats(videoId: video.id)
        let all = resolved.formats
        let duration = video.duration ?? 0
        let bestAudio = all.filter { Self.isAudioMP4($0.format) }
            .max { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) }

        var options: [VideoDownloadOption] = []

        if let hlsURL = resolved.hlsURL {
            options.append(
                VideoDownloadOption(
                    id: "hls",
                    title: "Best quality • Player stream",
                    detail: "Recommended • exports the HLS stream the player uses • MP4 up to 1080p",
                    video: nil,
                    audio: nil,
                    muxed: nil,
                    hlsURL: hlsURL))
        }

        if let muxed = all.filter({ Self.isMuxed($0.format) })
            .max(by: { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) })
        {
            let h = muxed.format.height
            let est = duration > 0 ? Double(muxed.format.bitrate ?? 0) * duration / 8 : 0
            options.append(
                VideoDownloadOption(
                    id: "muxed",
                    title: h > 0 ? "\(h)p (pre-muxed)" : "Pre-muxed MP4",
                    detail: est > 0
                        ? "\(Self.formatSize(est)) • single file, fastest"
                        : "Single file, fastest",
                    video: nil,
                    audio: nil,
                    muxed: muxed,
                    hlsURL: nil))
        }

        // Keep direct adaptive choices available as a last resort, but do not
        // let them displace the two reliable paths above.
        var seenHeights = Set<Int>()
        let avc = all.filter { Self.isAdaptiveAVC($0.format) }
            .sorted { ($0.format.bitrate ?? 0) > ($1.format.bitrate ?? 0) }
        var adaptiveOptions: [VideoDownloadOption] = []
        for candidate in avc {
            let h = candidate.format.height
            guard h > 0, !seenHeights.contains(h) else { continue }
            seenHeights.insert(h)
            let vBitrate = Double(candidate.format.bitrate ?? 0)
            let aBitrate = Double(bestAudio?.format.bitrate ?? 0)
            let est = duration > 0 ? (vBitrate + aBitrate) * duration / 8 : 0
            adaptiveOptions.append(
                VideoDownloadOption(
                    id: "avc\(h)",
                    title: "\(h)p • Direct stream",
                    detail: est > 0
                        ? "\(Self.formatSize(est)) • experimental — YouTube may block direct downloads"
                        : "Experimental — YouTube may block direct downloads",
                    video: candidate,
                    audio: bestAudio,
                    muxed: nil,
                    hlsURL: nil))
        }
        adaptiveOptions.sort { lhs, rhs in
            (Int(lhs.id.dropFirst(3)) ?? 0) > (Int(rhs.id.dropFirst(3)) ?? 0)
        }
        options += adaptiveOptions
        return options
    }

    /// Builds the format list for the audio download picker, from the best
    /// audio stream any client offers. When no separately downloadable audio
    /// stream is available, it falls back to the audio track inside the
    /// pre-muxed MP4 — the file path that already worked in v3.
    public func fetchAudioOptions(video: Video) async -> [AudioDownloadOption] {
        let resolved = await resolveAllFormats(videoId: video.id)
        let all = resolved.formats
        let duration = video.duration ?? 0

        let adaptiveSource = all.filter({ Self.isAudioMP4($0.format) })
            .max(by: { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) })
        let muxedSource = all.filter({ Self.isMuxed($0.format) })
            .max(by: { ($0.format.bitrate ?? 0) < ($1.format.bitrate ?? 0) })

        let source: ResolvedFormat
        let srcBitrate: Double
        let sourceIsMuxedVideo: Bool
        if let adaptiveSource {
            source = adaptiveSource
            srcBitrate = Double(adaptiveSource.format.bitrate ?? 128_000)
            sourceIsMuxedVideo = false
        } else if let muxedSource {
            source = muxedSource
            // itag 18's combined bitrate is mostly video; its AAC track is
            // typically around 96 kbps. Use that conservative value for both
            // estimates and the available conversion choices.
            srcBitrate = 96_000
            sourceIsMuxedVideo = true
        } else {
            return []
        }

        let fallbackSource = sourceIsMuxedVideo ? nil : muxedSource

        func est(_ bitrate: Double) -> String {
            duration > 0 ? Self.formatSize(bitrate * duration / 8) : ""
        }
        var options: [AudioDownloadOption] = [
            AudioDownloadOption(
                kind: .original,
                title: sourceIsMuxedVideo
                    ? "Extract audio from video"
                    : "Original (AAC, no conversion)",
                detail: sourceIsMuxedVideo
                    ? "\(est(srcBitrate)) • AAC ~96 kbps • extracted locally • .m4a"
                    : "\(est(srcBitrate)) • \(Int(srcBitrate / 1000)) kbps • .m4a",
                source: source,
                sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource)
        ]
        if srcBitrate > 200_000 {
            options.append(
                AudioDownloadOption(
                    kind: .aac256, title: "AAC 256 kbps",
                    detail: "\(est(256_000)) • .m4a", source: source,
                    sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource))
        }
        options.append(
            AudioDownloadOption(
                kind: .aac128, title: "AAC 128 kbps",
                detail: "\(est(128_000)) • .m4a", source: source,
                sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource))
        options.append(
            AudioDownloadOption(
                kind: .aac64, title: "AAC 64 kbps (smallest)",
                detail: "\(est(64_000)) • .m4a", source: source,
                sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource))
        options.append(
            AudioDownloadOption(
                kind: .m4r, title: "M4R ringtone (AAC 128 kbps)",
                detail: "\(est(128_000)) • .m4r", source: source,
                sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource))
        // WAV = 16-bit stereo PCM at 48 kHz ≈ 192 KB/s.
        options.append(
            AudioDownloadOption(
                kind: .wav, title: "WAV (lossless, large)",
                detail: "\(est(1_536_000)) • .wav", source: source,
                sourceIsMuxedVideo: sourceIsMuxedVideo, fallbackSource: fallbackSource))
        return options
    }

    /// Downloads a video at the quality chosen in the picker.
    public func download(video: Video, option: VideoDownloadOption) {
        guard !state.isActive else { return }
        lastCompletedKind = .video
        state = .fetching
        #if os(iOS)
        if #available(iOS 16.1, *) {
            startLiveActivity(video: video)
        }
        #endif
        downloadTask = Task { await performDownload(video: video, option: option) }
    }

    private func performDownload(video: Video, option: VideoDownloadOption) async {
        do {
            guard await requestPhotoAddAccess() else {
                state = .failed("Photo library access is required to save the video")
                #if os(iOS)
                if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
                #endif
                return
            }
            state = .downloading(progress: 0)
            let finalURL: URL
            if let hlsURL = option.hlsURL {
                finalURL = try await exportHLSToMP4(hlsURL: hlsURL, videoId: video.id)
            } else if let muxed = option.muxed, let muxedURL = muxed.format.url {
                let tempURL = try await downloadToTempChecked(
                    url: muxedURL, videoId: video.id + "-dl", userAgent: muxed.userAgent)
                state = .saving
                #if os(iOS)
                if #available(iOS 16.1, *) { await updateLiveActivity(phase: .saving, progress: 1) }
                #endif
                finalURL = try await passthroughRemux(
                    inputURL: tempURL, videoId: video.id, suffix: "muxed")
                try? FileManager.default.removeItem(at: tempURL)
            } else if let videoStream = option.video, let audioStream = option.audio,
                let videoURL = videoStream.format.url, let audioURL = audioStream.format.url
            {
                finalURL = try await mergeAdaptiveStreams(
                    videoURL: videoURL, audioURL: audioURL, videoId: video.id,
                    videoUserAgent: videoStream.userAgent,
                    audioUserAgent: audioStream.userAgent)
            } else {
                state = .failed("No downloadable stream found for this video")
                #if os(iOS)
                if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
                #endif
                return
            }
            state = .saving
            try await saveToPhotoLibrary(fileURL: finalURL)
            storeInDownloadStore(video: video, mergedFileURL: finalURL)
            try? FileManager.default.removeItem(at: finalURL)
            downloadLog.notice("[download] ✅ saved chosen-quality video \(video.id) option=\(option.id)")
            state = .done
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .done) }
            #endif
        } catch is CancellationError {
            state = .idle
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
            #endif
        } catch {
            state = .failed(error.localizedDescription)
            #if os(iOS)
            if #available(iOS 16.1, *) { await endLiveActivity(phase: .failed) }
            #endif
        }
    }

    /// Downloads the audio track in the format chosen in the picker.
    public func downloadAudio(video: Video, option: AudioDownloadOption) {
        guard !state.isActive else { return }
        lastCompletedKind = .audio
        state = .fetching
        downloadTask = Task { await performAudioDownload(video: video, option: option) }
    }

    private func performAudioDownload(video: Video, option: AudioDownloadOption) async {
        do {
            state = .downloading(progress: 0)
            let ext = option.kind.fileExtension
            let destURL = DownloadStore.shared.destinationURL(
                for: video.id + "__audio_" + option.kind.rawValue)
                .deletingPathExtension().appendingPathExtension(ext)
            try? FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            do {
                try await writeAudioFile(
                    video: video, option: option, source: option.source,
                    sourceIsMuxedVideo: option.sourceIsMuxedVideo, destURL: destURL)
            } catch {
                guard let fallbackSource = option.fallbackSource else { throw error }
                downloadLog.error(
                    "[download-audio] primary stream failed (\(error.localizedDescription)); retrying from muxed video"
                )
                try? FileManager.default.removeItem(at: destURL)
                state = .downloading(progress: 0)
                try await writeAudioFile(
                    video: video, option: option, source: fallbackSource,
                    sourceIsMuxedVideo: true, destURL: destURL)
            }

            storeAudioInDownloadStore(video: video, audioFileURL: destURL, option: option)
            downloadLog.notice(
                "[download-audio] ✅ saved \(video.id) kind=\(option.kind.rawValue) -> \(destURL.lastPathComponent)"
            )
            state = .done
        } catch is CancellationError {
            state = .idle
        } catch {
            downloadLog.error("[download-audio] ❌ failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Downloads one audio source and writes the requested output file.
    /// A muxed MP4 source is decoded and only its audio track is written.
    private func writeAudioFile(
        video: Video, option: AudioDownloadOption, source: ResolvedFormat,
        sourceIsMuxedVideo: Bool, destURL: URL
    ) async throws {
        guard let sourceURL = source.format.url else {
            throw URLError(.badURL)
        }
        let tempURL = try await downloadToTempChecked(
            url: sourceURL, videoId: video.id + "-aud", userAgent: source.userAgent)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        state = .saving
        try? FileManager.default.removeItem(at: destURL)
        if option.kind == .original && !sourceIsMuxedVideo {
            try FileManager.default.copyItem(at: tempURL, to: destURL)
        } else {
            // For the muxed fallback this extracts only the audio track;
            // the `.original` kind uses the writer's default AAC setting.
            try await transcodeAudio(inputURL: tempURL, outputURL: destURL, kind: option.kind)
        }
    }

    private func storeAudioInDownloadStore(
        video: Video, audioFileURL: URL, option: AudioDownloadOption
    ) {
        let audioId = video.id + "__audio_" + option.kind.rawValue
        DownloadStore.shared.add(
            DownloadedVideo(
                videoId: audioId,
                title: video.title + " (Audio \(option.kind.rawValue.uppercased()))",
                channelTitle: video.channelTitle,
                thumbnailURL: video.thumbnailURL,
                duration: video.duration ?? 0,
                fileURL: audioFileURL,
                downloadedAt: Date()
            ))
    }

    /// Exports the player's HLS stream to a Photos-compatible MP4.
    ///
    /// This deliberately reuses the playback route rather than downloading a
    /// raw googlevideo file. AVFoundation follows the signed HLS manifest and
    /// its segment requests just as it does during playback, then the export
    /// preset caps the result at 1920×1080 H.264/AAC for Photos.
    private func exportHLSToMP4(hlsURL: URL, videoId: String) async throws -> URL {
        let asset = AVURLAsset(url: hlsURL)
        // Force the manifest/tracks to load before creating the export
        // session so an unavailable HLS stream fails here with a real error.
        _ = try await asset.load(.tracks)
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPreset1920x1080)
        else {
            throw URLError(.cannotDecodeContentData)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId)-hls.mp4")
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let session = session
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    cont.resume()
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                default:
                    cont.resume(
                        throwing: session.error ?? URLError(.cannotDecodeContentData))
                }
            }
        }

        let size =
            (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int)
            ?? 0
        downloadLog.notice("[download] HLS export completed bytes=\(size)")
        guard size > 0 else { throw URLError(.zeroByteResource) }
        return outputURL
    }

    /// Downloads to a temp file, verifying the HTTP status is 200 — plain
    /// `URLSession.download` happily saves a 403 error page as the "file".
    private func downloadToTempChecked(
        url: URL, videoId: String, userAgent: String
    ) async throws -> URL {
        let req = VideoDownloadService.cdnRequest(for: url, userAgent: userAgent)
        let (tempURL, response) = try await VideoDownloadService.cdnSession.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size =
            (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] checked download status=\(status) bytes=\(size)")
        guard status == 200, size > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.badServerResponse)
        }
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId).mp4")
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    /// Transcodes a downloaded audio file to AAC (.m4a/.m4r at the kind's
    /// bitrate) or WAV (16-bit LPCM), decoding through AVAssetReader and
    /// re-encoding with AVAssetWriter.
    private nonisolated func transcodeAudio(
        inputURL: URL, outputURL: URL, kind: AudioFormatKind
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let srcTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw URLError(.cannotDecodeContentData)
        }
        // Source sample rate / channel count from the format description so
        // the writer matches the decoded stream.
        var sampleRate: Double = 48_000
        var channels: Int = 2
        if let formatDesc = try await srcTrack.load(.formatDescriptions).first,
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        {
            if asbd.pointee.mSampleRate > 0 { sampleRate = asbd.pointee.mSampleRate }
            if asbd.pointee.mChannelsPerFrame > 0 { channels = Int(asbd.pointee.mChannelsPerFrame) }
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: srcTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw URLError(.cannotDecodeContentData) }
        reader.add(readerOutput)

        let fileType: AVFileType = kind == .wav ? .wav : .m4a
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let outputSettings: [String: Any]
        if kind == .wav {
            outputSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ]
        } else {
            outputSettings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: kind.aacBitrate ?? 128_000,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
            ]
        }
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw URLError(.fileDoesNotExist) }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw reader.error ?? URLError(.cannotDecodeContentData)
        }
        guard writer.startWriting() else {
            throw writer.error ?? URLError(.cannotCreateFile)
        }
        writer.startSession(atSourceTime: .zero)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.smarttube.audio-transcode", qos: .userInitiated)
            nonisolated(unsafe) let writerInput = writerInput
            nonisolated(unsafe) let readerOutput = readerOutput
            nonisolated(unsafe) let reader = reader
            nonisolated(unsafe) let writer = writer
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                cont.resume()
                            } else {
                                cont.resume(
                                    throwing: writer.error ?? URLError(.fileDoesNotExist))
                            }
                        }
                        return
                    }
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? URLError(.cannotDecodeContentData)
        }
    }

    private func storeInDownloadStore(video: Video, mergedFileURL: URL) {
        let destURL = DownloadStore.shared.destinationURL(for: video.id)
        let fm = FileManager.default
        try? fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            // Remove a stale file from a previous download of the same video.
            try? fm.removeItem(at: destURL)
            try fm.copyItem(at: mergedFileURL, to: destURL)
        } catch {
            downloadLog.notice("[download] DownloadStore copy failed for \(video.id): \(error.localizedDescription)")
            return
        }
        DownloadStore.shared.add(
            DownloadedVideo(
                videoId: video.id,
                title: video.title,
                channelTitle: video.channelTitle,
                thumbnailURL: video.thumbnailURL,
                duration: video.duration ?? 0,
                fileURL: destURL,
                downloadedAt: Date()
            ))
        downloadLog.notice("[download] registered in DownloadStore \(video.id)")
    }

    private func downloadToTemp(
        url: URL, videoId: String, userAgent: String = InnerTubeClients.iOS.userAgent
    ) async throws -> URL {
        let req = VideoDownloadService.cdnRequest(for: url, userAgent: userAgent)
        let (tempURL, response) = try await VideoDownloadService.cdnSession.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let size = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        downloadLog.notice("[download] downloadToTemp status=\(status) bytes=\(size)")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(videoId).mp4")
        try? FileManager.default.removeItem(at: destURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }

    // nonisolated so the closures passed to performChanges carry no @MainActor
    // isolation — Photos calls them on its own serial queue and would crash if
    // the closures were actor-isolated (libdispatch queue assertion).
    private nonisolated func saveToPhotoLibrary(fileURL: URL) async throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let desc = "Video file was removed before saving to Photos: \(fileURL.lastPathComponent)"
            downloadLog.error("[download] ❌ \(desc)")
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: desc])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(
                {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
                },
                completionHandler: { success, error in
                    if let error {
                        let nsErr = error as NSError
                        downloadLog.error(
                            "[download] ❌ PHPhotoLibrary save error: domain=\(nsErr.domain) code=\(nsErr.code) desc=\(nsErr.localizedDescription)"
                        )
                        continuation.resume(throwing: error)
                    } else if success {
                        continuation.resume()
                    } else {
                        // success=false, error=nil means permission was denied or restricted at save time
                        let desc =
                            "Could not save to Photos. Please check Settings → Privacy & Security → Photos and allow SmartTube to add photos."
                        downloadLog.error(
                            "[download] ❌ PHPhotoLibrary performChanges returned success=false with no error — likely permission denied"
                        )
                        let permissionError = NSError(
                            domain: "PHPhotosErrorDomain",
                            code: PHPhotosError.accessRestricted.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: desc]
                        )
                        continuation.resume(throwing: permissionError)
                    }
                })
        }
        #else
        throw URLError(.unsupportedURL)
        #endif
    }
}
#endif  // ENABLE_DOWNLOADS
