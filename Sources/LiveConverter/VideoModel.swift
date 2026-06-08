import SwiftUI
import AVFoundation
import AppKit

/// Holds the loaded video and the user's segment selection.
@MainActor
final class VideoModel: ObservableObject {
    @Published var asset: AVURLAsset?
    @Published var sourceURL: URL?
    @Published var totalDuration: Double = 0          // seconds
    @Published var thumbnails: [NSImage] = []         // strip across the whole video
    @Published var selectionStart: Double = 0         // seconds, left edge of the window
    @Published var status: String = L.t("Open a video file to begin.", "请打开一个视频文件开始。")
    @Published var isBusy: Bool = false
    @Published var coverPreview: NSImage?             // still frame that becomes the key photo

    /// User-chosen Live Photo length (seconds), persisted. Clamped to 1…10.
    @Published var targetDuration: Double = VideoModel.loadDuration() {
        didSet { UserDefaults.standard.set(targetDuration, forKey: Self.durationKey) }
    }
    static let minDuration: Double = 1
    static let maxDuration: Double = 10
    private static let durationKey = "liveconverter.duration"
    static func loadDuration() -> Double {
        let v = UserDefaults.standard.object(forKey: durationKey) as? Double ?? kLivePhotoDuration
        return Swift.min(Swift.max(v, minDuration), maxDuration)
    }

    let player = AVPlayer()

    /// Length of the segment we extract. Clamped to the video length for short clips.
    var windowDuration: Double {
        min(targetDuration, max(0, totalDuration))
    }

    /// Largest valid value for `selectionStart`.
    var maxStart: Double {
        max(0, totalDuration - windowDuration)
    }

    /// The frame used as the Live Photo's key photo (middle of the window).
    var coverTime: Double {
        selectionStart + windowDuration / 2
    }

    func load(url: URL) {
        isBusy = true
        status = L.t("Loading video…", "正在载入视频…")
        thumbnails = []
        coverPreview = nil
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let duration = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard !tracks.isEmpty else {
                    await MainActor.run {
                        self.status = L.t("This file has no video track.", "该文件没有视频轨道，无法转换。")
                        self.isBusy = false
                    }
                    return
                }
                let seconds = CMTimeGetSeconds(duration)
                let thumbs = await Self.makeThumbnails(asset: asset, duration: seconds, count: 18)
                await MainActor.run {
                    self.asset = asset
                    self.sourceURL = url
                    self.totalDuration = seconds
                    self.selectionStart = 0
                    self.thumbnails = thumbs
                    self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                    self.isBusy = false
                    self.status = L.t(
                        String(format: "Loaded: %@ (%.1f s). Drag the window below to pick the %.1f s to capture.",
                               url.lastPathComponent, seconds, self.windowDuration),
                        String(format: "已载入：%@（时长 %.1f 秒）。拖动下方窗口选择要截取的 %.1f 秒。",
                               url.lastPathComponent, seconds, self.windowDuration))
                    self.refreshCover()
                    self.seekToCover()
                }
            } catch {
                await MainActor.run {
                    self.status = L.t("Failed to load: \(error.localizedDescription)",
                                      "载入失败：\(error.localizedDescription)")
                    self.isBusy = false
                }
            }
        }
    }

    /// Change the Live Photo length; keep the selection window inside the video.
    func setTargetDuration(_ value: Double) {
        targetDuration = min(max(value, Self.minDuration), Self.maxDuration)
        selectionStart = min(selectionStart, maxStart)
        seekToCover()
    }

    /// Clamp and store a new window start (called by the timeline while dragging).
    func setStart(_ value: Double) {
        selectionStart = min(max(0, value), maxStart)
        seekToCover()
    }

    func seekToCover() {
        let t = CMTime(seconds: coverTime, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Play just the selected window once, then pause.
    func previewSegment() {
        guard asset != nil else { return }
        let start = CMTime(seconds: selectionStart, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.player.play()
            let end = self.selectionStart + self.windowDuration
            let endTime = CMTime(seconds: end, preferredTimescale: 600)
            self.player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [weak self] in
                self?.player.pause()
                self?.seekToCover()
            }
        }
    }

    /// Refresh the still-frame preview shown next to the player.
    func refreshCover() {
        guard let asset else { return }
        let t = coverTime
        Task.detached {
            let img = await Self.copyFrame(asset: asset, seconds: t)
            await MainActor.run { self.coverPreview = img }
        }
    }

    // MARK: - Frame helpers

    nonisolated static func makeThumbnails(asset: AVURLAsset, duration: Double, count: Int) async -> [NSImage] {
        guard duration > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        gen.maximumSize = CGSize(width: 160, height: 160)
        var images: [NSImage] = []
        for i in 0..<count {
            let frac = (Double(i) + 0.5) / Double(count)
            let time = CMTime(seconds: duration * frac, preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
                images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
        }
        return images
    }

    nonisolated static func copyFrame(asset: AVURLAsset, seconds: Double) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
