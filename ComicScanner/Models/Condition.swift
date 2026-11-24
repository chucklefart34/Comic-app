import Foundation

/// The three price columns. Boundaries follow the number grades eBay sellers write in titles.
enum PriceBand: String, CaseIterable, Codable, Identifiable {
    case low = "Low"
    case mid = "Mid"
    case high = "High"

    var id: String { rawValue }

    var gradeRange: String {
        switch self {
        case .low: return "Under 5.0"
        case .mid: return "5.0 – 9.0"
        case .high: return "9.2 and up"
        }
    }

    static func of(grade: Double) -> PriceBand {
        if grade < 5.0 { return .low }
        if grade <= 9.0 { return .mid }
        return .high
    }
}

/// What the user says their copy is.
enum Condition: String, CaseIterable, Codable, Identifiable {
    case poor = "Poor"
    case fair = "Fair"
    case good = "Good"
    case veryGood = "Very Good"
    case fine = "Fine"
    case veryFine = "Very Fine"
    case nearMint = "Near Mint"
    case graded = "CGC Graded"

    var id: String { rawValue }

    var short: String {
        switch self {
        case .poor: return "PR"
        case .fair: return "FR"
        case .good: return "GD"
        case .veryGood: return "VG"
        case .fine: return "FN"
        case .veryFine: return "VF"
        case .nearMint: return "NM"
        case .graded: return "CGC"
        }
    }

    /// A typical number grade for the condition (nil for slabs — their grade is set separately).
    var typicalGrade: Double? {
        switch self {
        case .poor: return 0.5
        case .fair: return 1.0
        case .good: return 2.0
        case .veryGood: return 4.0
        case .fine: return 6.0
        case .veryFine: return 8.0
        case .nearMint: return 9.4
        case .graded: return nil
        }
    }

    var band: PriceBand? { typicalGrade.map(PriceBand.of(grade:)) }
}

/// Standard number grades (CGC scale).
let standardGrades: [Double] = [10, 9.9, 9.8, 9.6, 9.4, 9.2, 9.0, 8.5, 8.0, 7.5, 7.0, 6.5, 6.0, 5.5, 5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0, 1.8, 1.5, 1.0, 0.5]

func gradeLabel(_ grade: Double) -> String {
    grade >= 10 ? "10" : String(format: "%.1f", grade)
}
