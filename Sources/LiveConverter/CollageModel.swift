import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class CollageModel: ObservableObject {
    struct Clip: Identifiable {
        let id = UUID()
        let url: URL
        let asset: AVURLAsset
        let duration: Double
        let thumbnail: NSImage?
        var startSeconds: Double = 0
        var audioEnabled: Bool = true
    }

    @Published private(set) var clips: [Clip] = []
    @Published var selectedClipID: Clip.ID?
    @Published var keyPhotoFraction: Double = 0.5
    @Published var status: String = L.t("Choose three videos to build a three-up Live Photo.",
                                        "选择三个视频，生成三拼 Live Photo。")
    @Published var isBusy = false

    let player = AVPlayer()
    private var colorGrade: ColorGrade = .neutral
    private var playerClipID: Clip.ID?
    private var boundaryObserver: Any?

    var canGenerate: Bool {
        clips.count == 3 && !isBusy
    }

    var shortestDuration: Double {
        clips.map(\.duration).filter { $0.isFinite && $0 > 0 }.min() ?? 0
    }

    var startSeconds: [Double] {
        clips.map(\.startSeconds)
    }

    var audioEnabled: [Bool] {
        clips.map(\.audioEnabled)
    }

    var selectedIndex: Int? {
        guard let selectedClipID else { return clips.isEmpty ? nil : 0 }
        return clips.firstIndex { $0.id == selectedClipID } ?? (clips.isEmpty ? nil : 0)
    }

    var selectedClip: Clip? {
        guard let selectedIndex else { return nil }
        return clips[selectedIndex]
    }

    func outputDuration(targetDuration: Double) -> Double {
        let target = VideoModel.clampedDuration(targetDuration)
        let available = clips.compactMap { clip -> Double? in
            guard clip.duration.isFinite, clip.startSeconds.isFinite else { return nil }
            return max(0, clip.duration - clip.startSeconds)
        }.min() ?? 0
        return min(target, max(0, available))
    }

    func keyPhotoSeconds(outputDuration: Double) -> Double {
        guard outputDuration.isFinite else { return 0 }
        return min(max(0, keyPhotoFraction * outputDuration), outputDuration)
    }

    func maxStart(for index: Int, targetDuration: Double) -> Double {
        guard clips.indices.contains(index) else { return 0 }
        let clip = clips[index]
        guard clip.duration.isFinite else { return 0 }
        let target = VideoModel.clampedDuration(targetDuration)
        return max(0, clip.duration - min(target, clip.duration))
    }

    func setStart(_ value: Double, for index: Int, targetDuration: Double) {
        guard clips.indices.contains(index) else { return }
        clips[index].startSeconds = clampedStart(value, for: index, targetDuration: targetDuration)
        if selectedIndex == index {
            seekSelectedToStart()
        }
    }

    func clampStarts(targetDuration: Double) {
        for index in clips.indices {
            clips[index].startSeconds = clampedStart(clips[index].startSeconds,
                                                     for: index,
                                                     targetDuration: targetDuration)
        }
        seekSelectedToStart()
    }

    func setKeyPhotoFraction(_ value: Double) {
        keyPhotoFraction = min(max(0, value), 1)
    }

    func setAudioEnabled(_ enabled: Bool, for index: Int) {
        guard clips.indices.contains(index) else { return }
        clips[index].audioEnabled = enabled
    }

    func setColorGrade(_ grade: ColorGrade) {
        guard colorGrade != grade else { return }
        colorGrade = grade
        applyColorGradeToPlayer()
    }

    func select(index: Int) {
        guard clips.indices.contains(index) else { return }
        selectedClipID = clips[index].id
        loadSelectedPlayerIfNeeded()
    }

    func select(_ clip: Clip) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        select(index: index)
    }

    func previewSelected(targetDuration: Double) {
        guard let index = selectedIndex, clips.indices.contains(index) else { return }
        let durationSeconds = outputDuration(targetDuration: targetDuration)
        guard durationSeconds > 0 else { return }

        loadSelectedPlayerIfNeeded()
        clearBoundaryObserver()

        let previewClipID = clips[index].id
        let startSeconds = clips[index].startSeconds
        let start = CMTime(seconds: startSeconds, preferredTimescale: 600)
        let end = CMTime(seconds: startSeconds + durationSeconds, preferredTimescale: 600)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedClipID == previewClipID else { return }
                self.player.play()
                self.boundaryObserver = self.player.addBoundaryTimeObserver(
                    forTimes: [NSValue(time: end)],
                    queue: .main
                ) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.player.pause()
                        self.clearBoundaryObserver()
                        self.seekSelectedToStart()
                    }
                }
            }
        }
    }

    func replace(with urls: [URL]) {
        load(urls: urls, replacing: true)
    }

    func add(urls: [URL]) {
        load(urls: urls, replacing: false)
    }

    func remove(_ clip: Clip) {
        let removedIndex = clips.firstIndex { $0.id == clip.id }
        let wasSelected = selectedClipID == clip.id
        clips.removeAll { $0.id == clip.id }
        if clips.isEmpty {
            selectedClipID = nil
            playerClipID = nil
            clearBoundaryObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
        } else if wasSelected {
            let fallbackIndex = min(removedIndex ?? 0, clips.count - 1)
            selectedClipID = clips[fallbackIndex].id
            loadSelectedPlayerIfNeeded()
        }
        updateReadyStatus()
    }

    func clear() {
        clips = []
        selectedClipID = nil
        keyPhotoFraction = 0.5
        playerClipID = nil
        clearBoundaryObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        status = L.t("Choose three videos to build a three-up Live Photo.",
                     "选择三个视频，生成三拼 Live Photo。")
    }

    private func clampedStart(_ value: Double, for index: Int, targetDuration: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(0, value), maxStart(for: index, targetDuration: targetDuration))
    }

    private func load(urls: [URL], replacing: Bool) {
        let remaining = replacing ? 3 : max(0, 3 - clips.count)
        let picked = Array(urls.prefix(remaining))
        guard !picked.isEmpty else { return }

        isBusy = true
        status = L.t("Loading three-up clips…", "正在载入三拼素材…")

        Task {
            var loaded: [Clip] = []
            for url in picked {
                let asset = AVURLAsset(url: url)
                do {
                    let duration = try await asset.load(.duration)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    guard !tracks.isEmpty else { continue }
                    let seconds = CMTimeGetSeconds(duration)
                    guard seconds.isFinite, seconds > 0 else { continue }
                    let thumbTime = min(max(seconds / 2, 0), 1.5)
                    let thumbnail = await VideoModel.copyFrame(asset: asset,
                                                               seconds: thumbTime,
                                                               colorGrade: colorGrade)
                    loaded.append(Clip(url: url, asset: asset, duration: seconds, thumbnail: thumbnail))
                } catch {
                    status = L.t("Skipped \(url.lastPathComponent): \(error.localizedDescription)",
                                 "已跳过 \(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            if replacing {
                clips = loaded
                keyPhotoFraction = 0.5
                selectedClipID = clips.first?.id
            } else {
                clips = Array((clips + loaded).prefix(3))
                if selectedClipID == nil || !clips.contains(where: { $0.id == selectedClipID }) {
                    selectedClipID = loaded.first?.id ?? clips.first?.id
                }
            }
            isBusy = false
            loadSelectedPlayerIfNeeded()
            updateReadyStatus()
        }
    }

    private func loadSelectedPlayerIfNeeded() {
        guard let index = selectedIndex, clips.indices.contains(index) else {
            playerClipID = nil
            player.replaceCurrentItem(with: nil)
            return
        }

        let clip = clips[index]
        if playerClipID != clip.id {
            clearBoundaryObserver()
            player.pause()
            player.replaceCurrentItem(with: playerItem(for: clip.asset))
            playerClipID = clip.id
        }
        seekSelectedToStart()
    }

    private func playerItem(for asset: AVURLAsset) -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = colorGrade.videoComposition(for: asset)
        return item
    }

    private func applyColorGradeToPlayer() {
        guard let index = selectedIndex,
              clips.indices.contains(index),
              let item = player.currentItem else { return }
        item.videoComposition = colorGrade.videoComposition(for: clips[index].asset)
    }

    private func seekSelectedToStart() {
        guard let index = selectedIndex, clips.indices.contains(index) else { return }
        clearBoundaryObserver()
        player.pause()
        let time = CMTime(seconds: clips[index].startSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func clearBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
    }

    private func updateReadyStatus() {
        if clips.count == 3 {
            status = L.t(String(format: "Ready: 3 clips loaded. Max output length is %.1f s.",
                               shortestDuration),
                         String(format: "已就绪：已载入 3 个素材。最长可生成 %.1f 秒。",
                                shortestDuration))
        } else {
            status = L.t("Choose \(3 - clips.count) more video(s) for three-up.",
                         "还需选择 \(3 - clips.count) 个视频用于三拼。")
        }
    }
}
