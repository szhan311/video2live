import Foundation
import AVFoundation
import CoreMedia
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
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:        return L.t("The video has no usable video track.", "视频没有可用的视频轨道。")
            case .readerInit(let m):   return L.t("Can't read the video: \(m)", "无法读取视频：\(m)")
            case .writerInit(let m):   return L.t("Can't create the output video: \(m)", "无法创建输出视频：\(m)")
            case .stillExtract:        return L.t("Can't extract the key frame.", "无法提取封面帧。")
            case .stillWrite:          return L.t("Can't write the key photo.", "无法写入封面图片。")
            case .writerFailed(let m): return L.t("Write failed: \(m)", "写入失败：\(m)")
            }
        }
    }

    // QuickTime metadata identifiers used by Live Photos.
    private static let stillTimeID = AVMetadataIdentifier("mdta/com.apple.quicktime.still-image-time")
    private static let contentID   = AVMetadataIdentifier("mdta/com.apple.quicktime.content.identifier")
    private static let int8Type    = "com.apple.metadata.datatype.int8"
    private static let utf8Type    = "com.apple.metadata.datatype.UTF-8"

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

    /// Generate the pair. Runs on a background queue; calls completion on the main queue.
    static func generate(asset: AVURLAsset,
                         startSeconds: Double,
                         durationSeconds: Double,
                         coverSeconds: Double,
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
                try writeStill(asset: asset, seconds: coverSeconds, assetID: assetID, meta: meta, to: stagedPhotoURL)
                try writeVideo(asset: asset,
                               startSeconds: startSeconds,
                               durationSeconds: durationSeconds,
                               coverSeconds: coverSeconds,
                               assetID: assetID,
                               meta: meta,
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

    private static func writeStill(asset: AVURLAsset, seconds: Double, assetID: String,
                                   meta: SourceMeta, to url: URL) throws {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? gen.copyCGImage(at: time, actualTime: nil) else {
            throw GenError.stillExtract
        }

        let type = (UTType.heic.identifier as CFString)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw GenError.stillWrite
        }

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

        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw GenError.stillWrite
        }
    }

    // MARK: - Paired movie

    private static func writeVideo(asset: AVURLAsset,
                                   startSeconds: Double,
                                   durationSeconds: Double,
                                   coverSeconds: Double,
                                   assetID: String,
                                   meta: SourceMeta,
                                   to url: URL) throws {

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
        let vQueue = DispatchQueue(label: "live.write.video")

        group.enter()
        vIn.requestMediaDataWhenReady(on: vQueue) {
            while vIn.isReadyForMoreMediaData {
                guard let sample = vOut.copyNextSampleBuffer() else {
                    vIn.markAsFinished()
                    group.leave()
                    return
                }
                vIn.append(sample)
            }
        }

        if let aOut, let aIn {
            let aQueue = DispatchQueue(label: "live.write.audio")
            group.enter()
            aIn.requestMediaDataWhenReady(on: aQueue) {
                while aIn.isReadyForMoreMediaData {
                    guard let sample = aOut.copyNextSampleBuffer() else {
                        aIn.markAsFinished()
                        group.leave()
                        return
                    }
                    aIn.append(sample)
                }
            }
        }

        let waitSem = DispatchSemaphore(value: 0)
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { waitSem.signal() }
        waitSem.wait()

        if reader.status == .failed {
            throw GenError.writerFailed(reader.error?.localizedDescription ?? "reader failed")
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
