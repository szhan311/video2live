import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import AppKit
import UniformTypeIdentifiers

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
                try writeStill(asset: asset,
                               seconds: coverSeconds,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               to: stagedPhotoURL)
                try writeVideo(asset: asset,
                               startSeconds: startSeconds,
                               durationSeconds: durationSeconds,
                               coverSeconds: coverSeconds,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
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

                try writeStill(asset: collageAsset,
                               seconds: cover,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
                               to: stagedPhotoURL)
                try writeVideo(asset: collageAsset,
                               startSeconds: 0,
                               durationSeconds: actualDuration,
                               coverSeconds: cover,
                               assetID: assetID,
                               meta: meta,
                               colorGrade: colorGrade,
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
                                   to url: URL) throws {
        try loadAssetKeys(asset, keys: ["tracks"])

        let props = stillProperties(assetID: assetID, meta: meta)
        if #available(macOS 15.0, *) {
            if writeHDRGainMapStillIfPossible(asset: asset,
                                               seconds: seconds,
                                               props: props,
                                               colorGrade: colorGrade,
                                               to: url) {
                return
            }
        }

        let generatorImage = copyStillFrame(asset: asset, seconds: seconds)
        guard let cg = generatorImage ?? (try? fallbackStillImage(asset: asset, seconds: seconds)) else {
            throw GenError.stillExtract
        }

        try writeStandardStill(cgImage: cg, props: props, colorGrade: colorGrade, to: url)
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
                                           to url: URL) throws {
        let type = (UTType.heic.identifier as CFString)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw GenError.stillWrite
        }

        let outputImage = colorGrade.renderedCGImage(from: cgImage) ?? cgImage
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
                                     toneMapHDRToSDR: true)
            .settingProperties(ciProps)

        var hdrImage = gradedCIImage(from: hdrCG,
                                     colorGrade: colorGrade,
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
                                      toneMapHDRToSDR: Bool) -> CIImage {
        let source = CIImage(cgImage: cgImage, options: [.toneMapHDRtoSDR: toneMapHDRToSDR])
        guard !colorGrade.isNeutral else {
            return source.cropped(to: source.extent)
        }
        return colorGrade.makePipeline().apply(to: source).cropped(to: source.extent)
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

    private static func isHDRTransferFunction(_ value: Any?) -> Bool {
        guard let value else { return false }
        let transfer = String(describing: value)
        return transfer == String(describing: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
            || transfer == String(describing: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
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
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(w),
            AVVideoHeightKey: Int(h),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(w * h * 8)
            ]
        ])
        vIn.expectsMediaDataInRealTime = false
        vIn.transform = vTrack.preferredTransform
        guard writer.canAdd(vIn) else { throw GenError.writerInit("video input") }
        writer.add(vIn)

        let shouldApplyColorGrade = !colorGrade.isNeutral
        let colorPipeline = shouldApplyColorGrade ? colorGrade.makePipeline() : nil
        let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        let ciContext: CIContext?
        let renderColorSpace: CGColorSpace?
        if shouldApplyColorGrade {
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vIn,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(w),
                    kCVPixelBufferHeightKey as String: Int(h),
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
            )
            ciContext = CIContext()
            renderColorSpace = CGColorSpaceCreateDeviceRGB()
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

                if shouldApplyColorGrade {
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
                    let outputImage = (colorPipeline?.apply(to: sourceImage) ?? sourceImage)
                        .cropped(to: sourceImage.extent)
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
