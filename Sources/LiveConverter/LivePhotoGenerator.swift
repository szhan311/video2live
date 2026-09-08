import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers
import Vision

/// Produces a paired still image (HEIC) + movie (MOV) that together form a Live Photo.
/// Both files share a content identifier; the movie carries a "still-image-time" marker.
enum LivePhotoGenerator {

    /// What kind of artifact to leave on disk.
    enum Format {
        case pair       // loose HEIC + MOV — AirDrop both together to an iPhone
        case pvt        // a .pvt package (single Finder item) — drag into macOS Photos
    }

    struct Output {
        let photoURL: URL       // HEIC, with Apple maker-note asset identifier
        let videoURL: URL       // MOV, with content-identifier + still-image-time metadata
        let assetID: String
        let revealURLs: [URL]   // what to select in Finder for the user
    }

    enum GenError: LocalizedError {
        case noVideoTrack
        case readerInit(String)
        case writerInit(String)
        case stillExtract
        case stillWrite
        case collageInput(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:        return L.t("The video has no usable video track.", "视频没有可用的视频轨道。")
            case .readerInit(let m):   return L.t("Can't read the video: \(m)", "无法读取视频：\(m)")
            case .writerInit(let m):   return L.t("Can't create the output video: \(m)", "无法创建输出视频：\(m)")
            case .stillExtract:        return L.t("Can't extract the key frame.", "无法提取封面帧。")
            case .stillWrite:          return L.t("Can't write the key photo.", "无法写入封面图片。")
            case .collageInput(let m): return L.t("Can't build the three-up video: \(m)", "无法生成三拼视频：\(m)")
            case .writerFailed(let m): return L.t("Write failed: \(m)", "写入失败：\(m)")
            }
        }
    }

    // QuickTime metadata identifiers used by Live Photos.
    private static let stillTimeID = AVMetadataIdentifier("mdta/com.apple.quicktime.still-image-time")
    private static let contentID   = AVMetadataIdentifier("mdta/com.apple.quicktime.content.identifier")
    private static let int8Type    = "com.apple.metadata.datatype.int8"
    private static let utf8Type    = "com.apple.metadata.datatype.UTF-8"
    private static let fallbackHDRHeadroom: Float = 2.5

    private struct VideoColorProfile {
        let colorProperties: [String: String]
        let renderColorSpace: CGColorSpace
        let allowsWideColor: Bool

        static let rec709 = VideoColorProfile(
            colorProperties: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            renderColorSpace: CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB(),
            allowsWideColor: false
        )

        static let displayP3 = VideoColorProfile(
            colorProperties: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            renderColorSpace: CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB(),
            allowsWideColor: true
        )
    }

    private struct StabilizationTransform {
        let time: Double
        let x: CGFloat
        let y: CGFloat
    }

    private struct StabilizationPlan {
        let transforms: [StabilizationTransform]
        let cropScale: CGFloat
        let rawSize: CGSize
        let orientation: CGImagePropertyOrientation

        static let off = StabilizationPlan(transforms: [],
                                           cropScale: 1,
                                           rawSize: .zero,
                                           orientation: .up)

        var isActive: Bool {
            !transforms.isEmpty && cropScale > 1
        }

        func videoTransform(at seconds: Double, extent: CGRect) -> CGAffineTransform {
            let correction = correction(at: seconds)
            return cropTransform(correction: correction, extent: extent)
        }

        func stillTransform(at seconds: Double, extent: CGRect) -> CGAffineTransform {
            let correction = displayCorrection(fromRaw: correction(at: seconds),
                                               displaySize: extent.size)
            return cropTransform(correction: correction, extent: extent)
        }

        private func correction(at seconds: Double) -> CGPoint {
            guard isActive else { return .zero }
            guard let first = transforms.first else { return .zero }
            if seconds <= first.time { return CGPoint(x: first.x, y: first.y) }
            guard let last = transforms.last else { return .zero }
            if seconds >= last.time { return CGPoint(x: last.x, y: last.y) }

            var lower = 0
            var upper = transforms.count - 1
            while upper - lower > 1 {
                let mid = (lower + upper) / 2
                if transforms[mid].time <= seconds {
                    lower = mid
                } else {
                    upper = mid
                }
            }

            let a = transforms[lower]
            let b = transforms[upper]
            let span = max(0.0001, b.time - a.time)
            let t = CGFloat((seconds - a.time) / span)
            return CGPoint(x: a.x + (b.x - a.x) * t,
                           y: a.y + (b.y - a.y) * t)
        }

        private func cropTransform(correction: CGPoint, extent: CGRect) -> CGAffineTransform {
            guard isActive else { return .identity }
            let center = CGPoint(x: extent.midX, y: extent.midY)
            return CGAffineTransform(a: cropScale,
                                     b: 0,
                                     c: 0,
                                     d: cropScale,
                                     tx: correction.x + center.x * (1 - cropScale),
                                     ty: correction.y + center.y * (1 - cropScale))
        }

        private func displayCorrection(fromRaw correction: CGPoint, displaySize: CGSize) -> CGPoint {
            guard rawSize.width > 0, rawSize.height > 0 else { return correction }
            switch orientation {
            case .right:
                return CGPoint(x: -correction.y * displaySize.width / rawSize.height,
                               y: correction.x * displaySize.height / rawSize.width)
            case .left:
                return CGPoint(x: correction.y * displaySize.width / rawSize.height,
                               y: -correction.x * displaySize.height / rawSize.width)
            case .down:
                return CGPoint(x: -correction.x * displaySize.width / rawSize.width,
                               y: -correction.y * displaySize.height / rawSize.height)
            default:
                return CGPoint(x: correction.x * displaySize.width / rawSize.width,
                               y: correction.y * displaySize.height / rawSize.height)
            }
        }
    }

    private final class WriteFailureBox {
        private let lock = NSLock()
        private var message: String?

        func record(_ newMessage: String) {
            lock.lock()
            if message == nil { message = newMessage }
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return message
        }
    }

    // MARK: - Source metadata (date / location / camera) carried into the Live Photo

    struct SourceMeta {
        var creationDate: Date?
        var isoLocation: String?   // ISO 6709, e.g. "+37.7749-122.4194/"
        var make: String?
        var model: String?
        var software: String?
    }

    private static func extractMeta(from asset: AVAsset) -> SourceMeta {
        var m = SourceMeta()

        // Gather metadata from every source the asset exposes: top-level, common,
        // each container format, and the video track — real-world files scatter
        // date/location across different keyspaces.
        var all = asset.metadata + asset.commonMetadata
        for fmt in asset.availableMetadataFormats {
            all += asset.metadata(forFormat: fmt)
        }
        if let vTrack = asset.tracks(withMediaType: .video).first {
            all += vTrack.metadata
            for fmt in vTrack.availableMetadataFormats {
                all += vTrack.metadata(forFormat: fmt)
            }
        }

        func firstString(_ ids: [AVMetadataIdentifier]) -> String? {
            for id in ids {
                if let s = AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id)
                    .first?.stringValue, !s.isEmpty { return s }
            }
            return nil
        }
        func firstDate(_ ids: [AVMetadataIdentifier]) -> Date? {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let d = item.dateValue { return d }
                    if let s = item.stringValue {
                        if let d = iso8601In.date(from: s) { return d }
                        if let d = iso8601InFrac.date(from: s) { return d }
                    }
                }
            }
            return nil
        }

        m.creationDate = firstDate([.quickTimeMetadataCreationDate,
                                    .quickTimeUserDataCreationDate,
                                    .commonIdentifierCreationDate])
            ?? asset.creationDate?.dateValue
        m.isoLocation = firstString([.quickTimeMetadataLocationISO6709,
                                     .quickTimeUserDataLocationISO6709,
                                     .commonIdentifierLocation])
        m.make = firstString([.quickTimeMetadataMake, .quickTimeUserDataMake, .commonIdentifierMake])
        m.model = firstString([.quickTimeMetadataModel, .quickTimeUserDataModel, .commonIdentifierModel])
        m.software = firstString([.quickTimeMetadataSoftware, .quickTimeUserDataSoftware,
                                  .commonIdentifierSoftware])
        return m
    }

    private static func qtItem(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let it = AVMutableMetadataItem()
        it.identifier = id
        it.dataType = utf8Type
        it.value = value as NSString
        return it
    }

    /// Parse an ISO 6709 string into a CGImage GPS dictionary.
    private static func gpsDictionary(fromISO6709 s: String) -> [CFString: Any]? {
        let cleaned = s.replacingOccurrences(of: "/", with: "")
        var nums: [Double] = []
        var cur = ""
        for (i, ch) in cleaned.enumerated() {
            if (ch == "+" || ch == "-") && i != 0 {
                if let v = Double(cur) { nums.append(v) }
                cur = String(ch)
            } else {
                cur.append(ch)
            }
        }
        if let v = Double(cur) { nums.append(v) }
        guard nums.count >= 2 else { return nil }
        let lat = nums[0], lon = nums[1]
        var gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: abs(lat),
            kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(lon),
            kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"
        ]
        if nums.count >= 3 {
            gps[kCGImagePropertyGPSAltitude] = abs(nums[2])
            gps[kCGImagePropertyGPSAltitudeRef] = nums[2] >= 0 ? 0 : 1
        }
        return gps
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
    private static let iso8601In: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let iso8601InFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso8601Out: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    private static func loadAssetKeys(_ asset: AVAsset, keys: [String]) throws {
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: keys) {
            sem.signal()
        }
        sem.wait()

        for key in keys {
            var error: NSError?
            let status = asset.statusOfValue(forKey: key, error: &error)
            if status == .failed || status == .cancelled {
                throw GenError.readerInit(error?.localizedDescription ?? key)
            }
        }
    }

    /// Generate the pair. Runs on a background queue; calls completion on the main queue.
    static func generate(asset: AVURLAsset,
                         startSeconds: Double,
                         durationSeconds: Double,
                         coverSeconds: Double,
                         colorGrade: ColorGrade = .neutral,
                         stabilization: VideoStabilization = .off,
                         outputDirectory: URL,
                         format: Format,
                         completion: @escaping (Result<Output, Error>) -> Void) {

        let queue = DispatchQueue(label: "live.generator", qos: .userInitiated)
        queue.async {
            let fileManager = FileManager.default
            let assetID = UUID().uuidString
            let base = "LivePhoto_\(Int(Date().timeIntervalSince1970))_\(assetID.prefix(8))"
            let workDir = outputDirectory.appendingPathComponent(".\(base).tmp", isDirectory: true)
            let stagedPhotoURL = workDir.appendingPathComponent(base + ".heic")
            let stagedVideoURL = workDir.appendingPathComponent(base + ".mov")

            do {
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: workDir)
                try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: workDir) }

                let meta = extractMeta(from: asset)
                let stabilizationPlan = makeStabilizationPlan(asset: asset,
                                                              startSeconds: startSeconds,
                                                              durationSeconds: durationSeconds,
                                                              settings: stabilization)
                try writeStill(asset: asset,
                               seconds: coverSeconds,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               stabilizationPlan: stabilizationPlan,
                               to: stagedPhotoURL)
                try writeVideo(asset: asset,
                               startSeconds: startSeconds,
                               durationSeconds: durationSeconds,
                               coverSeconds: coverSeconds,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               stabilizationPlan: stabilizationPlan,
                               to: stagedVideoURL)

                let out: Output
                switch format {
                case .pair:
                    let photoURL = outputDirectory.appendingPathComponent(base + ".heic")
                    let videoURL = outputDirectory.appendingPathComponent(base + ".mov")
                    try? fileManager.removeItem(at: photoURL)
                    try? fileManager.removeItem(at: videoURL)
                    try fileManager.moveItem(at: stagedPhotoURL, to: photoURL)
                    try fileManager.moveItem(at: stagedVideoURL, to: videoURL)
                    out = Output(photoURL: photoURL, videoURL: videoURL,
                                 assetID: assetID, revealURLs: [photoURL, videoURL])
                case .pvt:
                    let stagedPVTURL = try packagePVT(base: base, photoURL: stagedPhotoURL,
                                                      videoURL: stagedVideoURL, in: workDir)
                    let pvtURL = outputDirectory.appendingPathComponent(base + ".pvt", isDirectory: true)
                    try? fileManager.removeItem(at: pvtURL)
                    try fileManager.moveItem(at: stagedPVTURL, to: pvtURL)
                    out = Output(photoURL: pvtURL.appendingPathComponent(base + ".heic"),
                                 videoURL: pvtURL.appendingPathComponent(base + ".mov"),
                                 assetID: assetID, revealURLs: [pvtURL])
                }
                DispatchQueue.main.async { completion(.success(out)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Generate one Live Photo from three videos stacked vertically.
    static func generateThreeUp(assets: [AVURLAsset],
                                startSeconds: [Double],
                                durationSeconds: Double,
                                coverSeconds: Double,
                                audioEnabled: [Bool],
                                colorGrade: ColorGrade = .neutral,
                                stabilization: VideoStabilization = .off,
                                outputDirectory: URL,
                                format: Format,
                                completion: @escaping (Result<Output, Error>) -> Void) {

        let queue = DispatchQueue(label: "live.generator.threeup", qos: .userInitiated)
        queue.async {
            let fileManager = FileManager.default
            let assetID = UUID().uuidString
            let base = "ThreeUpLivePhoto_\(Int(Date().timeIntervalSince1970))_\(assetID.prefix(8))"
            let workDir = outputDirectory.appendingPathComponent(".\(base).tmp", isDirectory: true)
            let collageURL = workDir.appendingPathComponent(base + "_source.mov")
            let stagedPhotoURL = workDir.appendingPathComponent(base + ".heic")
            let stagedVideoURL = workDir.appendingPathComponent(base + ".mov")

            do {
                try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try? fileManager.removeItem(at: workDir)
                try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
                defer { try? fileManager.removeItem(at: workDir) }

                let actualDuration = try writeThreeUpSourceVideo(assets: assets,
                                                                 startSeconds: startSeconds,
                                                                 durationSeconds: durationSeconds,
                                                                 audioEnabled: audioEnabled,
                                                                 to: collageURL)
                let collageAsset = AVURLAsset(url: collageURL)
                let meta = assets.first.map { extractMeta(from: $0) } ?? SourceMeta()
                let cover = min(max(coverSeconds, 0), actualDuration)
                let stabilizationPlan = makeStabilizationPlan(asset: collageAsset,
                                                              startSeconds: 0,
                                                              durationSeconds: actualDuration,
                                                              settings: stabilization)

                try writeStill(asset: collageAsset,
                               seconds: cover,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               stabilizationPlan: stabilizationPlan,
                               to: stagedPhotoURL)
                try writeVideo(asset: collageAsset,
                               startSeconds: 0,
                               durationSeconds: actualDuration,
                               coverSeconds: cover,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               stabilizationPlan: stabilizationPlan,
                               to: stagedVideoURL)

                let out: Output
                switch format {
                case .pair:
                    let photoURL = outputDirectory.appendingPathComponent(base + ".heic")
                    let videoURL = outputDirectory.appendingPathComponent(base + ".mov")
                    try? fileManager.removeItem(at: photoURL)
                    try? fileManager.removeItem(at: videoURL)
                    try fileManager.moveItem(at: stagedPhotoURL, to: photoURL)
                    try fileManager.moveItem(at: stagedVideoURL, to: videoURL)
                    out = Output(photoURL: photoURL, videoURL: videoURL,
                                 assetID: assetID, revealURLs: [photoURL, videoURL])
                case .pvt:
                    let stagedPVTURL = try packagePVT(base: base, photoURL: stagedPhotoURL,
                                                      videoURL: stagedVideoURL, in: workDir)
                    let pvtURL = outputDirectory.appendingPathComponent(base + ".pvt", isDirectory: true)
                    try? fileManager.removeItem(at: pvtURL)
                    try fileManager.moveItem(at: stagedPVTURL, to: pvtURL)
                    out = Output(photoURL: pvtURL.appendingPathComponent(base + ".heic"),
                                 videoURL: pvtURL.appendingPathComponent(base + ".mov"),
                                 assetID: assetID, revealURLs: [pvtURL])
                }
                DispatchQueue.main.async { completion(.success(out)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - .pvt package (macOS Photos import format)

    /// Bundle the pair into a `.pvt` package (a directory Finder shows as one item).
    /// Layout matches RhetTbull/makelive: image + video + metadata.plist.
    private static func packagePVT(base: String, photoURL: URL, videoURL: URL,
                                   in dir: URL) throws -> URL {
        let pvtURL = dir.appendingPathComponent(base + ".pvt", isDirectory: true)
        try? FileManager.default.removeItem(at: pvtURL)
        try FileManager.default.createDirectory(at: pvtURL, withIntermediateDirectories: true)

        let imgInside = pvtURL.appendingPathComponent(base + ".heic")
        let vidInside = pvtURL.appendingPathComponent(base + ".mov")
        try FileManager.default.moveItem(at: photoURL, to: imgInside)
        try FileManager.default.moveItem(at: videoURL, to: vidInside)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>PFVideoComplementMetadataVersionKey</key><string>1</string></dict></plist>
        """
        try plist.write(to: pvtURL.appendingPathComponent("metadata.plist"),
                        atomically: true, encoding: .utf8)
        markAsPackage(pvtURL)
        return pvtURL
    }

    private static func markAsPackage(_ url: URL) {
        var packageURL = url
        var values = URLResourceValues()
        values.isPackage = true
        try? packageURL.setResourceValues(values)
    }

    // MARK: - Still image (key photo)

    private static func writeStill(asset: AVURLAsset,
                                   seconds: Double,
                                   assetID: String,
                                   meta: SourceMeta,
                                   colorGrade: ColorGrade,
                                   stabilizationPlan: StabilizationPlan,
                                   to url: URL) throws {
        try loadAssetKeys(asset, keys: ["tracks"])

        let props = stillProperties(assetID: assetID, meta: meta)
        if #available(macOS 15.0, *) {
            if writeHDRGainMapStillIfPossible(asset: asset,
                                               seconds: seconds,
                                               props: props,
                                               colorGrade: colorGrade,
                                               stabilizationPlan: stabilizationPlan,
                                               to: url) {
                return
            }
        }

        let generatorImage = copyStillFrame(asset: asset, seconds: seconds)
        guard let cg = generatorImage ?? (try? fallbackStillImage(asset: asset, seconds: seconds)) else {
            throw GenError.stillExtract
        }

        let outputColorSpace = sourceContainsHDR(asset)
            ? VideoColorProfile.rec709.renderColorSpace
            : rgbColorSpace(for: cg)
        try writeStandardStill(cgImage: cg,
                               props: props,
                               colorGrade: colorGrade,
                               stabilizationPlan: stabilizationPlan,
                               outputColorSpace: outputColorSpace,
                               seconds: seconds,
                               to: url)
    }

    private static func copyStillFrame(asset: AVURLAsset,
                                       seconds: Double,
                                       configure: ((AVAssetImageGenerator) -> Void)? = nil) -> CGImage? {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        configure?(gen)

        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        let exact = try? gen.copyCGImage(at: time, actualTime: nil)
        if exact != nil { return exact }

        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        return try? gen.copyCGImage(at: time, actualTime: nil)
    }

    private static func stillProperties(assetID: String, meta: SourceMeta) -> [CFString: Any] {
        // Embed the asset identifier into the Apple maker note (key "17").
        var props: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": assetID]
        ]

        // Carry over date / camera / GPS from the source video.
        var tiff: [CFString: Any] = [:]
        if let make = meta.make { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = meta.model { tiff[kCGImagePropertyTIFFModel] = model }
        if let software = meta.software { tiff[kCGImagePropertyTIFFSoftware] = software }
        if let date = meta.creationDate {
            let s = exifDateFormatter.string(from: date)
            tiff[kCGImagePropertyTIFFDateTime] = s
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: s,
                kCGImagePropertyExifDateTimeDigitized: s
            ]
        }
        if !tiff.isEmpty { props[kCGImagePropertyTIFFDictionary] = tiff }
        if let loc = meta.isoLocation, let gps = gpsDictionary(fromISO6709: loc) {
            props[kCGImagePropertyGPSDictionary] = gps
        }

        return props
    }

    private static func writeStandardStill(cgImage: CGImage,
                                           props: [CFString: Any],
                                           colorGrade: ColorGrade,
                                           stabilizationPlan: StabilizationPlan,
                                           outputColorSpace: CGColorSpace,
                                           seconds: Double,
                                           to url: URL) throws {
        let type = (UTType.heic.identifier as CFString)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw GenError.stillWrite
        }

        let outputImage = renderedStillCGImage(from: cgImage,
                                               colorGrade: colorGrade,
                                               stabilizationPlan: stabilizationPlan,
                                               outputColorSpace: outputColorSpace,
                                               seconds: seconds,
                                               toneMapHDRToSDR: true) ?? cgImage
        CGImageDestinationAddImage(dest, outputImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw GenError.stillWrite
        }
    }

    @available(macOS 15.0, *)
    private static func writeHDRGainMapStillIfPossible(asset: AVURLAsset,
                                                       seconds: Double,
                                                       props: [CFString: Any],
                                                       colorGrade: ColorGrade,
                                                       stabilizationPlan: StabilizationPlan,
                                                       to url: URL) -> Bool {
        guard sourceContainsHDR(asset) else { return false }
        guard let sdrCG = copyStillFrame(asset: asset, seconds: seconds, configure: { generator in
            generator.dynamicRangePolicy = .forceSDR
        }) ?? (try? fallbackStillImage(asset: asset, seconds: seconds)),
              let hdrCG = copyStillFrame(asset: asset, seconds: seconds, configure: { generator in
                  generator.dynamicRangePolicy = .matchSource
              }) else {
            return false
        }

        let context = CIContext()
        let colorSpace = rgbColorSpace(for: sdrCG)
        let ciProps = props as [AnyHashable: Any]
        let sdrImage = gradedCIImage(from: sdrCG,
                                     colorGrade: colorGrade,
                                     stabilizationPlan: stabilizationPlan,
                                     seconds: seconds,
                                     toneMapHDRToSDR: true)
            .settingProperties(ciProps)

        var hdrImage = gradedCIImage(from: hdrCG,
                                     colorGrade: colorGrade,
                                     stabilizationPlan: stabilizationPlan,
                                     seconds: seconds,
                                     toneMapHDRToSDR: false)
        if #available(macOS 16.0, *) {
            let headroom = max(hdrCG.contentHeadroom, fallbackHDRHeadroom)
            hdrImage = hdrImage.settingContentHeadroom(headroom)
        }

        do {
            try context.writeHEIFRepresentation(of: sdrImage,
                                                to: url,
                                                format: .RGBA8,
                                                colorSpace: colorSpace,
                                                options: [
                                                    .hdrImage: hdrImage,
                                                    .hdrGainMapAsRGB: false
                                                ])
            guard heicContainsHDRGainMap(url) else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    private static func gradedCIImage(from cgImage: CGImage,
                                      colorGrade: ColorGrade,
                                      stabilizationPlan: StabilizationPlan,
                                      seconds: Double,
                                      toneMapHDRToSDR: Bool) -> CIImage {
        var output = CIImage(cgImage: cgImage, options: [.toneMapHDRtoSDR: toneMapHDRToSDR])
        if !colorGrade.isNeutral {
            output = colorGrade.makePipeline().apply(to: output).cropped(to: output.extent)
        }
        if stabilizationPlan.isActive {
            output = output.transformed(by: stabilizationPlan.stillTransform(at: seconds,
                                                                             extent: output.extent))
                .cropped(to: output.extent)
        }
        return output
    }

    private static func rgbColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func heicContainsHDRGainMap(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if #available(macOS 15.0, *),
           CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    private static func sourceContainsHDR(_ asset: AVURLAsset) -> Bool {
        guard let track = asset.tracks(withMediaType: .video).first else { return false }
        if track.hasMediaCharacteristic(.containsHDRVideo) {
            return true
        }

        for case let formatDescription as CMFormatDescription in track.formatDescriptions {
            guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
                  isHDRTransferFunction(extensions[kCVImageBufferTransferFunctionKey]) else {
                continue
            }
            return true
        }
        return false
    }

    private static func outputVideoColorProfile(for track: AVAssetTrack) -> VideoColorProfile {
        let primaries = firstFormatExtension(kCVImageBufferColorPrimariesKey, from: track)
        let transfer = firstFormatExtension(kCVImageBufferTransferFunctionKey, from: track)

        if isHDRTransferFunction(transfer) {
            return .rec709
        }

        if matches(primaries, kCVImageBufferColorPrimaries_P3_D65) {
            return .displayP3
        }

        return .rec709
    }

    private static func firstFormatExtension(_ key: CFString, from track: AVAssetTrack) -> String? {
        for case let formatDescription as CMFormatDescription in track.formatDescriptions {
            guard let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any],
                  let value = extensions[key] else {
                continue
            }
            return String(describing: value)
        }
        return nil
    }

    private static func isHDRTransferFunction(_ value: Any?) -> Bool {
        guard let value else { return false }
        let transfer = String(describing: value)
        return transfer == String(describing: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            || transfer == String(describing: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
    }

    private static func matches(_ value: String?, _ constant: CFString) -> Bool {
        value == String(describing: constant)
    }

    private static func renderedStillCGImage(from cgImage: CGImage,
                                             colorGrade: ColorGrade,
                                             stabilizationPlan: StabilizationPlan,
                                             outputColorSpace: CGColorSpace,
                                             seconds: Double,
                                             toneMapHDRToSDR: Bool) -> CGImage? {
        let image = gradedCIImage(from: cgImage,
                                  colorGrade: colorGrade,
                                  stabilizationPlan: stabilizationPlan,
                                  seconds: seconds,
                                  toneMapHDRToSDR: toneMapHDRToSDR)
        let context = CIContext(options: [
            .workingColorSpace: outputColorSpace,
            .outputColorSpace: outputColorSpace
        ])
        return context.createCGImage(image,
                                     from: image.extent.integral,
                                     format: .RGBA8,
                                     colorSpace: outputColorSpace)
    }

    // MARK: - Digital stabilization

    private struct RegistrationFrame {
        let image: CGImage
        let luma: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat
        let rawSize: CGSize
    }

    private static func makeStabilizationPlan(asset: AVURLAsset,
                                              startSeconds: Double,
                                              durationSeconds: Double,
                                              settings: VideoStabilization) -> StabilizationPlan {
        guard settings.isActive else { return .off }
        do {
            return try analyzeStabilization(asset: asset,
                                            startSeconds: startSeconds,
                                            durationSeconds: durationSeconds,
                                            settings: settings)
        } catch {
            return .off
        }
    }

    private static func analyzeStabilization(asset: AVURLAsset,
                                             startSeconds: Double,
                                             durationSeconds: Double,
                                             settings: VideoStabilization) throws -> StabilizationPlan {
        try loadAssetKeys(asset, keys: ["tracks", "duration"])
        guard let track = asset.tracks(withMediaType: .video).first else { return .off }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { return .off }

        let timescale: CMTimeScale = 600
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: timescale),
                                       duration: CMTime(seconds: durationSeconds, preferredTimescale: timescale))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return .off }
        reader.add(output)
        guard reader.startReading() else { return .off }

        let context = CIContext()
        var previousFrame: RegistrationFrame?
        var rawSize = CGSize(width: abs(track.naturalSize.width), height: abs(track.naturalSize.height))
        var times: [Double] = []
        var path: [CGPoint] = []
        var currentPath = CGPoint.zero
        var acceptedMeasurements = 0
        var rejectedMeasurements = 0

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  let frame = registrationFrame(from: buffer, context: context) else {
                continue
            }

            rawSize = frame.rawSize
            let sampleSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard sampleSeconds.isFinite else { continue }

            if let previousFrame,
               let alignment = translationFromCurrentFrame(frame, toPreviousFrame: previousFrame) {
                currentPath.x -= alignment.x / max(frame.scale, 0.0001)
                currentPath.y -= alignment.y / max(frame.scale, 0.0001)
                acceptedMeasurements += 1
            } else if previousFrame != nil {
                rejectedMeasurements += 1
            }

            times.append(sampleSeconds)
            path.append(currentPath)
            previousFrame = frame
        }

        guard reader.status != .failed, times.count > 2, path.count == times.count else {
            return .off
        }
        let measuredFrames = acceptedMeasurements + rejectedMeasurements
        guard measuredFrames > 0,
              Double(acceptedMeasurements) / Double(measuredFrames) >= 0.45 else {
            return .off
        }

        let smoothingRadius = settings.strength.smoothingRadius
        let smoothed = triangularMovingAverage(path, radius: smoothingRadius)
        let motionLimit = min(rawSize.width, rawSize.height) * settings.strength.maxCorrectionRatio
        let cropLimitX = rawSize.width * (settings.strength.cropScale - 1) * 0.46
        let cropLimitY = rawSize.height * (settings.strength.cropScale - 1) * 0.46
        let maxCorrectionX = min(motionLimit, cropLimitX)
        let maxCorrectionY = min(motionLimit, cropLimitY)
        let deadband = max(1.0, min(rawSize.width, rawSize.height) * 0.001)
        let correctionRadius = max(2, smoothingRadius / 3)
        var transforms: [StabilizationTransform] = []
        var largestCorrection: CGFloat = 0
        var corrections: [CGPoint] = []

        for index in path.indices {
            var correction = CGPoint(x: (smoothed[index].x - path[index].x) * settings.strength.correctionScale,
                                     y: (smoothed[index].y - path[index].y) * settings.strength.correctionScale)
            correction = limited(correction, maxX: maxCorrectionX, maxY: maxCorrectionY)
            if hypot(correction.x, correction.y) < deadband {
                correction = .zero
            }
            corrections.append(correction)
        }

        corrections = triangularMovingAverage(corrections, radius: correctionRadius)
        for index in corrections.indices {
            let correction = limited(corrections[index], maxX: maxCorrectionX, maxY: maxCorrectionY)
            largestCorrection = max(largestCorrection, hypot(correction.x, correction.y))
            transforms.append(StabilizationTransform(time: times[index],
                                                     x: correction.x,
                                                     y: correction.y))
        }

        guard largestCorrection >= deadband else { return .off }
        return StabilizationPlan(transforms: transforms,
                                 cropScale: settings.strength.cropScale,
                                 rawSize: rawSize,
                                 orientation: imageOrientation(for: track.preferredTransform))
    }

    private static func registrationFrame(from pixelBuffer: CVPixelBuffer,
                                          context: CIContext) -> RegistrationFrame? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let maxDimension: CGFloat = 320
        let rawSize = CGSize(width: width, height: height)
        let scale = min(1, maxDimension / max(rawSize.width, rawSize.height))
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let image = scale < 1
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source
        guard let cgImage = context.createCGImage(image, from: image.extent.integral) else {
            return nil
        }
        guard let luma = lumaPixels(from: cgImage) else { return nil }
        return RegistrationFrame(image: cgImage,
                                 luma: luma,
                                 width: cgImage.width,
                                 height: cgImage.height,
                                 scale: scale,
                                 rawSize: rawSize)
    }

    private static func translationFromCurrentFrame(_ current: RegistrationFrame,
                                                    toPreviousFrame previous: RegistrationFrame) -> CGPoint? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current.image,
                                                              options: [:])
        let handler = VNImageRequestHandler(cgImage: previous.image, options: [:])
        do {
            try handler.perform([request])
            guard let transform = request.results?.first?.alignmentTransform,
                  transform.tx.isFinite,
                  transform.ty.isFinite else {
                return nil
            }
            let shift = CGPoint(x: transform.tx, y: transform.ty)
            let maxShift = CGFloat(min(current.width, current.height)) * 0.07
            guard abs(shift.x) <= maxShift, abs(shift.y) <= maxShift else {
                return nil
            }

            let stillDifference = frameDifference(current, previous: previous, applying: .zero)
            let alignedDifference = frameDifference(current, previous: previous, applying: shift)
            guard alignedDifference.isFinite,
                  stillDifference.isFinite,
                  alignedDifference <= stillDifference * 0.96 || hypot(shift.x, shift.y) < 0.75 else {
                return nil
            }

            return shift
        } catch {
            return nil
        }
    }

    private static func lumaPixels(from image: CGImage) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        let drew = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drew ? pixels : nil
    }

    private static func frameDifference(_ current: RegistrationFrame,
                                        previous: RegistrationFrame,
                                        applying translation: CGPoint) -> CGFloat {
        let width = min(current.width, previous.width)
        let height = min(current.height, previous.height)
        guard width > 12, height > 12 else { return .greatestFiniteMagnitude }

        let dx = Int(round(translation.x))
        let dy = Int(round(translation.y))
        let step = 3
        let minX = max(0, dx)
        let maxX = min(width - 1, width - 1 + dx)
        let minY = max(0, dy)
        let maxY = min(height - 1, height - 1 + dy)
        guard maxX > minX + step, maxY > minY + step else {
            return .greatestFiniteMagnitude
        }

        var total = 0
        var count = 0
        for y in stride(from: minY, through: maxY, by: step) {
            let currentY = y - dy
            guard currentY >= 0, currentY < current.height, y < previous.height else { continue }
            for x in stride(from: minX, through: maxX, by: step) {
                let currentX = x - dx
                guard currentX >= 0, currentX < current.width, x < previous.width else { continue }
                let prevValue = Int(previous.luma[y * previous.width + x])
                let currentValue = Int(current.luma[currentY * current.width + currentX])
                total += abs(prevValue - currentValue)
                count += 1
            }
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return CGFloat(total) / CGFloat(count)
    }

    private static func triangularMovingAverage(_ points: [CGPoint], radius: Int) -> [CGPoint] {
        guard !points.isEmpty, radius > 0 else { return points }
        return points.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(points.count - 1, index + radius)
            var totalWeight: CGFloat = 0
            var sum = CGPoint.zero
            for sampleIndex in lower...upper {
                let weight = CGFloat(radius + 1 - abs(sampleIndex - index))
                totalWeight += weight
                sum.x += points[sampleIndex].x * weight
                sum.y += points[sampleIndex].y * weight
            }
            return CGPoint(x: sum.x / max(totalWeight, 0.0001),
                           y: sum.y / max(totalWeight, 0.0001))
        }
    }

    private static func limited(_ point: CGPoint, maxX: CGFloat, maxY: CGFloat) -> CGPoint {
        CGPoint(x: min(max(point.x, -maxX), maxX),
                y: min(max(point.y, -maxY), maxY))
    }

    private static func fallbackStillImage(asset: AVURLAsset, seconds: Double) throws -> CGImage {
        try loadAssetKeys(asset, keys: ["tracks", "duration"])
        guard let track = asset.tracks(withMediaType: .video).first else { throw GenError.noVideoTrack }

        let assetDuration = CMTimeGetSeconds(asset.duration)
        let safeDuration = assetDuration.isFinite && assetDuration > 0 ? assetDuration : max(seconds + 1, 1)
        let windowSeconds = min(2.0, max(0.1, safeDuration))
        let requestedStart = min(max(0, seconds - windowSeconds / 2), max(0, safeDuration - windowSeconds))
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw GenError.readerInit(error.localizedDescription) }

        reader.timeRange = CMTimeRange(start: CMTime(seconds: requestedStart, preferredTimescale: 600),
                                       duration: CMTime(seconds: windowSeconds, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw GenError.readerInit("still fallback output") }
        reader.add(output)
        guard reader.startReading() else {
            throw GenError.readerInit(reader.error?.localizedDescription ?? "still fallback startReading")
        }

        let context = CIContext()
        let orientation = imageOrientation(for: track.preferredTransform)
        var bestImage: CGImage?
        var bestDelta = Double.greatestFiniteMagnitude

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let sampleSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            let delta = sampleSeconds.isFinite ? abs(sampleSeconds - seconds) : bestDelta
            guard delta <= bestDelta else { continue }

            let source = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let normalizedExtent = source.extent
            let normalized = source.transformed(by: CGAffineTransform(translationX: -normalizedExtent.minX,
                                                                      y: -normalizedExtent.minY))
            bestImage = context.createCGImage(normalized, from: normalized.extent.integral)
            bestDelta = delta
            if sampleSeconds >= seconds { break }
        }

        if reader.status == .failed {
            throw GenError.readerInit(reader.error?.localizedDescription ?? "still fallback reader failed")
        }
        guard let bestImage else { throw GenError.stillExtract }
        return bestImage
    }

    private static func imageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = roundedTransformValue(transform.a)
        let b = roundedTransformValue(transform.b)
        let c = roundedTransformValue(transform.c)
        let d = roundedTransformValue(transform.d)

        if a == 0, b == 1, c == -1, d == 0 { return .right }
        if a == 0, b == -1, c == 1, d == 0 { return .left }
        if a == -1, b == 0, c == 0, d == -1 { return .down }
        return .up
    }

    private static func roundedTransformValue(_ value: CGFloat) -> Int {
        Int(round(value))
    }

    // MARK: - Paired movie

    private static func writeThreeUpSourceVideo(assets: [AVURLAsset],
                                                startSeconds: [Double],
                                                durationSeconds: Double,
                                                audioEnabled: [Bool],
                                                to url: URL) throws -> Double {
        guard assets.count == 3 else {
            throw GenError.collageInput("three videos are required")
        }
        guard startSeconds.count == 3 else {
            throw GenError.collageInput("three start times are required")
        }
        guard audioEnabled.count == 3 else {
            throw GenError.collageInput("three audio options are required")
        }

        var sourceTracks: [AVAssetTrack] = []
        var sourceStarts: [CMTime] = []
        var availableDurations: [Double] = []
        for (index, asset) in assets.enumerated() {
            try loadAssetKeys(asset, keys: ["tracks", "duration"])
            guard let track = asset.tracks(withMediaType: .video).first else {
                throw GenError.collageInput("clip \(index + 1) has no video track")
            }
            let trackDuration = CMTimeGetSeconds(track.timeRange.duration)
            let requestedStart = min(max(0, startSeconds[index]), max(0, trackDuration))
            let sourceStart = CMTimeAdd(track.timeRange.start,
                                        CMTime(seconds: requestedStart, preferredTimescale: 600))
            sourceTracks.append(track)
            sourceStarts.append(sourceStart)
            availableDurations.append(max(0, trackDuration - requestedStart))
        }

        let shortestTrackDuration = availableDurations
            .filter { $0.isFinite && $0 > 0 }
            .min() ?? 0
        let actualDuration = min(durationSeconds, shortestTrackDuration)
        guard actualDuration > 0 else {
            throw GenError.collageInput("the selected clips are too short")
        }

        let timescale: CMTimeScale = 600
        let duration = CMTime(seconds: actualDuration, preferredTimescale: timescale)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        let renderSize = CGSize(width: 1080, height: 1920)
        let rowHeight = renderSize.height / 3

        let composition = AVMutableComposition()
        var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

        for (index, track) in sourceTracks.enumerated() {
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .video,
                                                                     preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw GenError.collageInput("can't create video track \(index + 1)")
            }
            let sourceRange = CMTimeRange(start: sourceStarts[index], duration: duration)
            try compositionTrack.insertTimeRange(sourceRange, of: track, at: .zero)

            let row = CGRect(x: 0, y: CGFloat(index) * rowHeight,
                             width: renderSize.width, height: rowHeight)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
            layer.setTransform(fillTransform(for: track, into: row), at: .zero)
            layerInstructions.append(layer)
        }

        var audioTracksForMix: [AVMutableCompositionTrack] = []
        for index in assets.indices where audioEnabled[index] {
            try addAudio(from: assets[index],
                         sourceOffsetSeconds: startSeconds[index],
                         duration: duration,
                         to: composition,
                         audioTracksForMix: &audioTracksForMix)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.layerInstructions = layerInstructions

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw GenError.collageInput("can't create exporter")
        }
        exporter.outputURL = url
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        if audioTracksForMix.count > 1 {
            let mix = AVMutableAudioMix()
            let volume = 1.0 / Float(audioTracksForMix.count)
            mix.inputParameters = audioTracksForMix.map { track in
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(volume, at: .zero)
                return params
            }
            exporter.audioMix = mix
        }

        let exportSem = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { exportSem.signal() }
        exportSem.wait()

        if exporter.status != .completed {
            throw GenError.writerFailed(exporter.error?.localizedDescription
                                        ?? "three-up export status \(exporter.status.rawValue)")
        }

        return actualDuration
    }

    private static func addAudio(from asset: AVURLAsset,
                                 sourceOffsetSeconds: Double,
                                 duration: CMTime,
                                 to composition: AVMutableComposition,
                                 audioTracksForMix: inout [AVMutableCompositionTrack]) throws {
        guard let audioTrack = asset.tracks(withMediaType: .audio).first,
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                 preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return
        }
        let audioDurationSeconds = CMTimeGetSeconds(audioTrack.timeRange.duration)
        let requestedStart = min(max(0, sourceOffsetSeconds), max(0, audioDurationSeconds))
        let availableSeconds = max(0, audioDurationSeconds - requestedStart)
        let actualDuration = CMTimeMinimum(duration, CMTime(seconds: availableSeconds, preferredTimescale: 600))
        guard actualDuration > .zero else { return }

        let audioStart = CMTimeAdd(audioTrack.timeRange.start,
                                   CMTime(seconds: requestedStart, preferredTimescale: 600))
        try compositionAudio.insertTimeRange(CMTimeRange(start: audioStart, duration: actualDuration),
                                             of: audioTrack,
                                             at: .zero)
        audioTracksForMix.append(compositionAudio)
    }

    private static func fillTransform(for track: AVAssetTrack, into target: CGRect) -> CGAffineTransform {
        let natural = track.naturalSize
        let preferred = track.preferredTransform
        let sourceRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let normalized = preferred.concatenating(
            CGAffineTransform(translationX: -sourceRect.minX, y: -sourceRect.minY)
        )
        let displayRect = CGRect(origin: .zero, size: natural).applying(normalized)
        guard displayRect.width > 0, displayRect.height > 0 else { return .identity }

        let scale = max(target.width / displayRect.width, target.height / displayRect.height)
        let scaledSize = CGSize(width: displayRect.width * scale, height: displayRect.height * scale)
        let tx = target.minX + (target.width - scaledSize.width) / 2
        let ty = target.minY + (target.height - scaledSize.height) / 2

        return normalized
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private static func writeVideo(asset: AVURLAsset,
                                   startSeconds: Double,
                                   durationSeconds: Double,
                                   coverSeconds: Double,
                                   assetID: String,
                                   meta: SourceMeta,
                                   colorGrade: ColorGrade,
                                   stabilizationPlan: StabilizationPlan,
                                   to url: URL) throws {

        try loadAssetKeys(asset, keys: ["tracks", "duration"])

        let videoTracks = asset.tracks(withMediaType: .video)
        guard let vTrack = videoTracks.first else { throw GenError.noVideoTrack }
        let aTrack = asset.tracks(withMediaType: .audio).first

        let timescale: CMTimeScale = 600
        let start = CMTime(seconds: startSeconds, preferredTimescale: timescale)
        let dur = CMTime(seconds: durationSeconds, preferredTimescale: timescale)
        let timeRange = CMTimeRange(start: start, duration: dur)

        // --- Reader ---
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw GenError.readerInit(error.localizedDescription) }
        reader.timeRange = timeRange

        let vOut = AVAssetReaderTrackOutput(
            track: vTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw GenError.readerInit("video output") }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack {
            let out = AVAssetReaderTrackOutput(
                track: aTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); aOut = out }
        }

        // --- Writer ---
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mov) }
        catch { throw GenError.writerInit(error.localizedDescription) }

        // Movie-level metadata: content identifier (ties to the still) + carried-over
        // creation date / location / camera info from the source.
        let cidItem = AVMutableMetadataItem()
        cidItem.identifier = contentID
        cidItem.dataType = utf8Type
        cidItem.value = assetID as NSString

        var movieMeta: [AVMetadataItem] = [cidItem]
        if let date = meta.creationDate {
            movieMeta.append(qtItem(.quickTimeMetadataCreationDate, iso8601Out.string(from: date)))
        }
        if let loc = meta.isoLocation {
            movieMeta.append(qtItem(.quickTimeMetadataLocationISO6709, loc))
        }
        if let make = meta.make { movieMeta.append(qtItem(.quickTimeMetadataMake, make)) }
        if let model = meta.model { movieMeta.append(qtItem(.quickTimeMetadataModel, model)) }
        if let software = meta.software { movieMeta.append(qtItem(.quickTimeMetadataSoftware, software)) }
        writer.metadata = movieMeta

        // Video input (re-encode so output is GOP-independent and trims cleanly).
        // Use the NATIVE encoded size and carry the rotation via the track transform —
        // setting the rotated (display) size here would stretch portrait video.
        let natural = vTrack.naturalSize
        let w = abs(natural.width), h = abs(natural.height)
        let colorProfile = outputVideoColorProfile(for: vTrack)
        let videoOutputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(w),
            AVVideoHeightKey: Int(h),
            AVVideoColorPropertiesKey: colorProfile.colorProperties,
            AVVideoAllowWideColorKey: colorProfile.allowsWideColor,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(w * h * 8)
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoOutputSettings)
        vIn.expectsMediaDataInRealTime = false
        vIn.transform = vTrack.preferredTransform
        guard writer.canAdd(vIn) else { throw GenError.writerInit("video input") }
        writer.add(vIn)

        let shouldRenderVideoFrames = !colorGrade.isNeutral || stabilizationPlan.isActive
        let colorPipeline = !colorGrade.isNeutral ? colorGrade.makePipeline() : nil
        let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        let ciContext: CIContext?
        let renderColorSpace: CGColorSpace?
        if shouldRenderVideoFrames {
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vIn,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(w),
                    kCVPixelBufferHeightKey as String: Int(h),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            ciContext = CIContext(options: [
                .workingColorSpace: colorProfile.renderColorSpace,
                .outputColorSpace: colorProfile.renderColorSpace
            ])
            renderColorSpace = colorProfile.renderColorSpace
        } else {
            pixelAdaptor = nil
            ciContext = nil
            renderColorSpace = nil
        }

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
                AVEncoderBitRateKey: 128000
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }

        // Metadata input carrying the still-image-time marker.
        let metaIn = AVAssetWriterInput(mediaType: .metadata,
                                        outputSettings: nil,
                                        sourceFormatHint: stillImageFormatDescription())
        let metaAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metaIn)
        if writer.canAdd(metaIn) { writer.add(metaIn) }

        // --- Run ---
        guard reader.startReading() else {
            throw GenError.readerInit(reader.error?.localizedDescription ?? "startReading")
        }
        guard writer.startWriting() else {
            throw GenError.writerInit(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: start)

        // Mark the key-photo time.
        let stillItem = AVMutableMetadataItem()
        stillItem.identifier = stillTimeID
        stillItem.dataType = int8Type
        stillItem.value = 0 as NSNumber
        let coverTime = CMTime(seconds: coverSeconds, preferredTimescale: timescale)
        let markerRange = CMTimeRange(start: coverTime, duration: CMTime(value: 200, timescale: 3000))
        metaAdaptor.append(AVTimedMetadataGroup(items: [stillItem], timeRange: markerRange))
        metaIn.markAsFinished()

        // Drain video and audio CONCURRENTLY. Reading one track to completion
        // before the other can deadlock AVAssetReader, so each input pulls on
        // its own queue and we wait for both via a dispatch group.
        let group = DispatchGroup()
        let writeFailure = WriteFailureBox()
        let vQueue = DispatchQueue(label: "live.write.video")

        group.enter()
        var videoFinished = false
        vIn.requestMediaDataWhenReady(on: vQueue) {
            guard !videoFinished else { return }
            while vIn.isReadyForMoreMediaData {
                guard let sample = vOut.copyNextSampleBuffer() else {
                    videoFinished = true
                    vIn.markAsFinished()
                    group.leave()
                    return
                }

                if shouldRenderVideoFrames {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sample),
                          let pixelAdaptor,
                          let pixelBufferPool = pixelAdaptor.pixelBufferPool,
                          let ciContext,
                          let renderColorSpace else {
                        writeFailure.record("color pipeline is not ready")
                        videoFinished = true
                        vIn.markAsFinished()
                        group.leave()
                        return
                    }

                    var outputBuffer: CVPixelBuffer?
                    let pixelStatus = CVPixelBufferPoolCreatePixelBuffer(nil,
                                                                         pixelBufferPool,
                                                                         &outputBuffer)
                    guard pixelStatus == kCVReturnSuccess, let outputBuffer else {
                        writeFailure.record("can't allocate color frame buffer (\(pixelStatus))")
                        videoFinished = true
                        vIn.markAsFinished()
                        group.leave()
                        return
                    }

                    let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
                    var outputImage = (colorPipeline?.apply(to: sourceImage) ?? sourceImage)
                        .cropped(to: sourceImage.extent)
                    if stabilizationPlan.isActive {
                        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                        outputImage = outputImage
                            .transformed(by: stabilizationPlan.videoTransform(at: seconds,
                                                                              extent: sourceImage.extent))
                            .cropped(to: sourceImage.extent)
                    }
                    ciContext.render(outputImage,
                                     to: outputBuffer,
                                     bounds: sourceImage.extent,
                                     colorSpace: renderColorSpace)

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard pixelAdaptor.append(outputBuffer, withPresentationTime: presentationTime) else {
                        writeFailure.record(writer.error?.localizedDescription ?? "video append failed")
                        videoFinished = true
                        vIn.markAsFinished()
                        group.leave()
                        return
                    }
                } else if !vIn.append(sample) {
                    writeFailure.record(writer.error?.localizedDescription ?? "video append failed")
                    videoFinished = true
                    vIn.markAsFinished()
                    group.leave()
                    return
                }
            }
        }

        if let aOut, let aIn {
            let aQueue = DispatchQueue(label: "live.write.audio")
            group.enter()
            var audioFinished = false
            aIn.requestMediaDataWhenReady(on: aQueue) {
                guard !audioFinished else { return }
                while aIn.isReadyForMoreMediaData {
                    guard let sample = aOut.copyNextSampleBuffer() else {
                        audioFinished = true
                        aIn.markAsFinished()
                        group.leave()
                        return
                    }
                    if !aIn.append(sample) {
                        writeFailure.record(writer.error?.localizedDescription ?? "audio append failed")
                        audioFinished = true
                        aIn.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }

        let waitSem = DispatchSemaphore(value: 0)
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { waitSem.signal() }
        waitSem.wait()

        if reader.status == .failed {
            throw GenError.writerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        if let failure = writeFailure.value {
            writer.cancelWriting()
            throw GenError.writerFailed(failure)
        }

        let finishSem = DispatchSemaphore(value: 0)
        writer.finishWriting { finishSem.signal() }
        finishSem.wait()

        if writer.status != .completed {
            throw GenError.writerFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
    }

    /// Format description describing the still-image-time metadata, required by the writer input.
    private static func stillImageFormatDescription() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                int8Type
        ]
        var desc: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &desc)
        return desc
    }
}
