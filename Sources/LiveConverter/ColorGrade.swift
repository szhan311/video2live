import AVFoundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Export-wide color adjustments shared by preview frames and final output.
struct ColorGrade: Equatable {
    var exposure: Double = 0       // EV, -1...1
    var contrast: Double = 1       // 0.5...1.8
    var saturation: Double = 1     // 0...2
    var warmth: Double = 0         // -1...1
    var tint: Double = 0           // -1...1
    var vignette: Double = 0       // 0...0.8

    var shadows = ColorWheel()
    var midtones = ColorWheel()
    var highlights = ColorWheel()
    var warper = ColorWarper()

    static let neutral = ColorGrade()

    var isNeutral: Bool {
        abs(exposure) < 0.0001
            && abs(contrast - 1) < 0.0001
            && abs(saturation - 1) < 0.0001
            && abs(warmth) < 0.0001
            && abs(tint) < 0.0001
            && abs(vignette) < 0.0001
            && !needsColorCube
    }

    var needsColorCube: Bool {
        !shadows.isNeutral
            || !midtones.isNeutral
            || !highlights.isNeutral
            || !warper.isNeutral
    }

    struct ColorWheel: Equatable {
        var x: Double = 0          // -1...1
        var y: Double = 0          // -1...1
        var level: Double = 0      // -1...1

        var isNeutral: Bool {
            abs(x) < 0.0001 && abs(y) < 0.0001 && abs(level) < 0.0001
        }
    }

    struct WarpPoint: Equatable {
        var hueShift: Double = 0   // -1...1, maps to roughly -30...30 degrees
        var saturation: Double = 0 // -1...1

        var isNeutral: Bool {
            abs(hueShift) < 0.0001 && abs(saturation) < 0.0001
        }
    }

    enum WarpZone: String, CaseIterable, Identifiable {
        case red
        case yellow
        case green
        case cyan
        case blue
        case magenta

        var id: String { rawValue }

        var title: String {
            switch self {
            case .red:     return L.t("Red", "红")
            case .yellow:  return L.t("Yellow", "黄")
            case .green:   return L.t("Green", "绿")
            case .cyan:    return L.t("Cyan", "青")
            case .blue:    return L.t("Blue", "蓝")
            case .magenta: return L.t("Magenta", "品红")
            }
        }

        var hueDegrees: Double {
            switch self {
            case .red:     return 0
            case .yellow:  return 60
            case .green:   return 120
            case .cyan:    return 180
            case .blue:    return 240
            case .magenta: return 300
            }
        }
    }

    struct ColorWarper: Equatable {
        var red = WarpPoint()
        var yellow = WarpPoint()
        var green = WarpPoint()
        var cyan = WarpPoint()
        var blue = WarpPoint()
        var magenta = WarpPoint()

        var isNeutral: Bool {
            red.isNeutral && yellow.isNeutral && green.isNeutral
                && cyan.isNeutral && blue.isNeutral && magenta.isNeutral
        }

        func point(for zone: WarpZone) -> WarpPoint {
            switch zone {
            case .red:     return red
            case .yellow:  return yellow
            case .green:   return green
            case .cyan:    return cyan
            case .blue:    return blue
            case .magenta: return magenta
            }
        }

        mutating func set(_ point: WarpPoint, for zone: WarpZone) {
            switch zone {
            case .red:     red = point
            case .yellow:  yellow = point
            case .green:   green = point
            case .cyan:    cyan = point
            case .blue:    blue = point
            case .magenta: magenta = point
            }
        }
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

    func makePipeline() -> ColorGradePipeline {
        ColorGradePipeline(grade: self)
    }

    func applying(to image: CIImage) -> CIImage {
        makePipeline().apply(to: image)
    }

    func renderedCGImage(from cgImage: CGImage, context: CIContext = CIContext()) -> CGImage? {
        guard !isNeutral else { return cgImage }
        let source = CIImage(cgImage: cgImage)
        let output = makePipeline().apply(to: source).cropped(to: source.extent)
        return context.createCGImage(output, from: source.extent)
    }

    func videoComposition(for asset: AVAsset) -> AVVideoComposition? {
        guard !isNeutral else { return nil }
        let pipeline = makePipeline()
        return AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let output = pipeline.apply(to: source).cropped(to: source.extent)
            request.finish(with: output, context: nil)
        }
    }
}

struct ColorGradePipeline {
    private let grade: ColorGrade
    private let cubeDimension = 32
    private let cubeData: Data?

    init(grade: ColorGrade) {
        self.grade = grade
        self.cubeData = grade.needsColorCube
            ? Self.makeCubeData(for: grade, dimension: cubeDimension)
            : nil
    }

    func apply(to image: CIImage) -> CIImage {
        var output = image

        if abs(grade.exposure) > 0.0001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(grade.exposure)
            output = filter.outputImage ?? output
        }

        if abs(grade.contrast - 1) > 0.0001 || abs(grade.saturation - 1) > 0.0001 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = 0
            filter.contrast = Float(max(0.1, grade.contrast))
            filter.saturation = Float(max(0, grade.saturation))
            output = filter.outputImage ?? output
        }

        if abs(grade.warmth) > 0.0001 || abs(grade.tint) > 0.0001 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = output
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: 6500 + grade.warmth * 2200,
                                            y: grade.tint * 120)
            output = filter.outputImage ?? output
        }

        if let cubeData,
           let filter = CIFilter(name: "CIColorCube") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(cubeDimension, forKey: "inputCubeDimension")
            filter.setValue(cubeData, forKey: "inputCubeData")
            output = filter.outputImage ?? output
        }

        if grade.vignette > 0.0001 {
            let filter = CIFilter.vignette()
            filter.inputImage = output
            filter.intensity = Float(grade.vignette * 1.8)
            filter.radius = Float(max(output.extent.width, output.extent.height) * 0.62)
            output = filter.outputImage ?? output
        }

        return output
    }

    private static func makeCubeData(for grade: ColorGrade, dimension: Int) -> Data {
        var cube: [Float] = []
        cube.reserveCapacity(dimension * dimension * dimension * 4)
        let denom = Double(dimension - 1)

        for blueIndex in 0..<dimension {
            let blue = Double(blueIndex) / denom
            for greenIndex in 0..<dimension {
                let green = Double(greenIndex) / denom
                for redIndex in 0..<dimension {
                    let red = Double(redIndex) / denom
                    let rgb = transformed(red: red, green: green, blue: blue, grade: grade)
                    cube.append(Float(rgb.red))
                    cube.append(Float(rgb.green))
                    cube.append(Float(rgb.blue))
                    cube.append(1)
                }
            }
        }

        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func transformed(red: Double,
                                    green: Double,
                                    blue: Double,
                                    grade: ColorGrade) -> RGB {
        let sourceLuma = luminance(red: red, green: green, blue: blue)
        var rgb = RGB(red: red, green: green, blue: blue)

        if !grade.shadows.isNeutral {
            rgb = apply(wheel: grade.shadows,
                        to: rgb,
                        weight: pow(max(0, 1 - sourceLuma), 2.2))
        }
        if !grade.midtones.isNeutral {
            let midWeight = max(0, 1 - abs(sourceLuma - 0.5) * 2)
            rgb = apply(wheel: grade.midtones,
                        to: rgb,
                        weight: pow(midWeight, 1.25))
        }
        if !grade.highlights.isNeutral {
            rgb = apply(wheel: grade.highlights,
                        to: rgb,
                        weight: pow(max(0, sourceLuma), 2.2))
        }
        if !grade.warper.isNeutral {
            rgb = apply(warper: grade.warper, to: rgb)
        }

        return rgb.clamped
    }

    private static func apply(wheel: ColorGrade.ColorWheel, to rgb: RGB, weight: Double) -> RGB {
        guard weight > 0.0001 else { return rgb }
        let magnitude = min(1, hypot(wheel.x, wheel.y))
        var output = rgb

        if magnitude > 0.0001 {
            let hue = normalizedDegrees(atan2(wheel.y, wheel.x) * 180 / .pi)
            let wheelColor = hsvToRGB(hue: hue, saturation: 1, value: 1)
            let colorLuma = luminance(red: wheelColor.red, green: wheelColor.green, blue: wheelColor.blue)
            let strength = magnitude * 0.36 * weight
            output.red += (wheelColor.red - colorLuma) * strength
            output.green += (wheelColor.green - colorLuma) * strength
            output.blue += (wheelColor.blue - colorLuma) * strength
        }

        if abs(wheel.level) > 0.0001 {
            let levelShift = wheel.level * 0.22 * weight
            output.red += levelShift
            output.green += levelShift
            output.blue += levelShift
        }

        return output
    }

    private static func apply(warper: ColorGrade.ColorWarper, to rgb: RGB) -> RGB {
        let hsv = rgbToHSV(red: rgb.red, green: rgb.green, blue: rgb.blue)
        guard hsv.saturation > 0.001 else { return rgb }

        var hue = hsv.hue
        var saturation = hsv.saturation

        for zone in ColorGrade.WarpZone.allCases {
            let point = warper.point(for: zone)
            guard !point.isNeutral else { continue }

            let distance = abs(shortestHueDelta(hue - zone.hueDegrees))
            guard distance < 75 else { continue }

            let weight = smoothstep(1 - distance / 75)
            hue += point.hueShift * 34 * weight
            saturation *= 1 + point.saturation * 0.55 * weight
        }

        return hsvToRGB(hue: hue,
                        saturation: clamp(saturation, 0, 1),
                        value: hsv.value)
    }

    private static func rgbToHSV(red: Double, green: Double, blue: Double)
    -> (hue: Double, saturation: Double, value: Double) {
        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue

        var hue: Double
        if delta < 0.00001 {
            hue = 0
        } else if maxValue == red {
            hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }

        hue = normalizedDegrees(hue)
        let saturation = maxValue <= 0 ? 0 : delta / maxValue
        return (hue, saturation, maxValue)
    }

    private static func hsvToRGB(hue: Double, saturation: Double, value: Double) -> RGB {
        let normalizedHue = normalizedDegrees(hue)
        let chroma = value * saturation
        let hPrime = normalizedHue / 60
        let x = chroma * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))

        let rgbPrime: RGB
        switch hPrime {
        case 0..<1: rgbPrime = RGB(red: chroma, green: x, blue: 0)
        case 1..<2: rgbPrime = RGB(red: x, green: chroma, blue: 0)
        case 2..<3: rgbPrime = RGB(red: 0, green: chroma, blue: x)
        case 3..<4: rgbPrime = RGB(red: 0, green: x, blue: chroma)
        case 4..<5: rgbPrime = RGB(red: x, green: 0, blue: chroma)
        default:    rgbPrime = RGB(red: chroma, green: 0, blue: x)
        }

        let match = value - chroma
        return RGB(red: rgbPrime.red + match,
                   green: rgbPrime.green + match,
                   blue: rgbPrime.blue + match)
    }

    private static func luminance(red: Double, green: Double, blue: Double) -> Double {
        red * 0.2126 + green * 0.7152 + blue * 0.0722
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = clamp(value, 0, 1)
        return t * t * (3 - 2 * t)
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        var output = degrees.truncatingRemainder(dividingBy: 360)
        if output < 0 { output += 360 }
        return output
    }

    private static func shortestHueDelta(_ degrees: Double) -> Double {
        var output = degrees.truncatingRemainder(dividingBy: 360)
        if output > 180 { output -= 360 }
        if output < -180 { output += 360 }
        return output
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        var clamped: RGB {
            RGB(red: ColorGradePipeline.clamp(red, 0, 1),
                green: ColorGradePipeline.clamp(green, 0, 1),
                blue: ColorGradePipeline.clamp(blue, 0, 1))
        }
    }
}
