import CoreGraphics
import Foundation

/// Lightweight export-time digital stabilization.
struct VideoStabilization: Equatable {
    enum Strength: String, CaseIterable, Identifiable {
        case light
        case standard
        case strong

        var id: String { rawValue }

        var title: String {
            switch self {
            case .light:    return L.t("Light", "轻微")
            case .standard: return L.t("Standard", "标准")
            case .strong:   return L.t("Strong", "强力")
            }
        }

        var cropScale: CGFloat {
            switch self {
            case .light:    return 1.04
            case .standard: return 1.07
            case .strong:   return 1.11
            }
        }

        var smoothingRadius: Int {
            switch self {
            case .light:    return 5
            case .standard: return 9
            case .strong:   return 14
            }
        }

        var correctionScale: CGFloat {
            switch self {
            case .light:    return 0.65
            case .standard: return 0.85
            case .strong:   return 1.0
            }
        }

        var maxCorrectionRatio: CGFloat {
            switch self {
            case .light:    return 0.035
            case .standard: return 0.055
            case .strong:   return 0.08
            }
        }
    }

    var isEnabled = false
    var strength: Strength = .standard

    static let off = VideoStabilization()

    var isActive: Bool {
        isEnabled
    }
}
