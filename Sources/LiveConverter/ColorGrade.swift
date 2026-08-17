import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Lightweight, export-wide color adjustments shared by preview frames and final output.
struct ColorGrade: Equatable {
    var exposure: Double = 0       // EV, -1...1
    var contrast: Double = 1       // 0.5...1.8
    var saturation: Double = 1     // 0...2
    var warmth: Double = 0         // -1...1
    var tint: Double = 0           // -1...1
    var vignette: Double = 0       // 0...0.8

    static let neutral = ColorGrade()

    var isNeutral: Bool {
        abs(exposure) < 0.0001
            && abs(contrast - 1) < 0.0001
            && abs(saturation - 1) < 0.0001
            && abs(warmth) < 0.0001
            && abs(tint) < 0.0001
            && abs(vignette) < 0.0001
    }

    enum Preset: String, CaseIterable, Identifiable {
        case original
        case vivid
        case warm
        case cool
        case film
        case mono
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .original: return L.t("Original", "原片")
            case .vivid:    return L.t("Vivid", "鲜艳")
            case .warm:     return L.t("Warm", "暖色")
            case .cool:     return L.t("Cool", "冷色")
            case .film:     return L.t("Film", "胶片")
            case .mono:     return L.t("B&W", "黑白")
            case .custom:   return L.t("Custom", "自定义")
            }
        }

        var grade: ColorGrade {
            switch self {
            case .original:
                return .neutral
            case .vivid:
                return ColorGrade(exposure: 0.06, contrast: 1.14, saturation: 1.28,
                                  warmth: 0.04, tint: 0, vignette: 0.04)
            case .warm:
                return ColorGrade(exposure: 0.04, contrast: 1.08, saturation: 1.12,
                                  warmth: 0.36, tint: 0.03, vignette: 0.02)
            case .cool:
                return ColorGrade(exposure: 0.02, contrast: 1.08, saturation: 1.06,
                                  warmth: -0.36, tint: -0.04, vignette: 0.02)
            case .film:
                return ColorGrade(exposure: -0.04, contrast: 0.96, saturation: 0.86,
                                  warmth: 0.20, tint: 0.05, vignette: 0.22)
            case .mono:
                return ColorGrade(exposure: 0, contrast: 1.18, saturation: 0,
                                  warmth: 0, tint: 0, vignette: 0.16)
            case .custom:
                return .neutral
            }
        }
    }

    func applying(to image: CIImage) -> CIImage {
        var output = image

        if abs(exposure) > 0.0001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(exposure)
            output = filter.outputImage ?? output
        }

        if abs(contrast - 1) > 0.0001 || abs(saturation - 1) > 0.0001 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = Float(max(0.1, contrast))
            filter.saturation = Float(max(0, saturation))
            output = filter.outputImage ?? output
        }

        if abs(warmth) > 0.0001 || abs(tint) > 0.0001 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + warmth * 2200, y: tint * 120)
            output = filter.outputImage ?? output
        }

        if vignette > 0.0001 {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.intensity = Float(vignette * 1.8)
            filter.radius = Float(max(output.extent.width, output.extent.height) * 0.62)
            output = filter.outputImage ?? output
        }

        return output
    }

    func renderedCGImage(from cgImage: CGImage, context: CIContext = CIContext()) -> CGImage? {
        guard !isNeutral else { return cgImage }
        let source = CIImage(cgImage: cgImage)
        let output = applying(to: source).cropped(to: source.extent)
        return context.createCGImage(output, from: source.extent)
    }

    func videoComposition(for asset: AVAsset) -> AVVideoComposition? {
        guard !isNeutral else { return nil }
        return AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let output = applying(to: source).cropped(to: source.extent)
            request.finish(with: output, context: nil)
        }
    }
}
