import Foundation

// MARK: - Comic barcode

/// A comic book barcode: the 12-digit UPC-A plus the optional 5-digit add-on
/// printed to its right (3 digits issue number, 1 digit cover variant, 1 digit printing).
struct ComicBarcode: Hashable, Identifiable {
    var base: String
    var addOn: String

    var id: String { base }

    init(base: String, addOn: String = "") {
        self.base = base
        self.addOn = addOn
    }

    /// Parses a scanner payload. UPC-A is usually reported as EAN-13 with a leading 0.
    init?(payload: String) {
        let digits = payload.filter(\.isNumber)
        switch digits.count {
        case 12:
            self.init(base: digits)
        case 13:
            self.init(base: digits.hasPrefix("0") ? String(digits.dropFirst()) : digits)
        case 17:
            self.init(base: String(digits.prefix(12)), addOn: String(digits.suffix(5)))
        case 18 where digits.hasPrefix("0"):
            self.init(base: String(digits.dropFirst().prefix(12)), addOn: String(digits.suffix(5)))
        default:
            return nil
        }
    }

    var hasAddOn: Bool { addOn.count == 5 && addOn.allSatisfy(\.isNumber) }
    var fullUPC: String? { hasAddOn ? base + addOn : nil }
    var issueNumber: Int? { hasAddOn ? Int(addOn.prefix(3)) : nil }
    var coverVariant: Int? { hasAddOn ? Int(addOn.dropFirst(3).prefix(1)) : nil }
    var printing: Int? { hasAddOn ? Int(addOn.suffix(1)) : nil }

    var formattedBase: String {
        guard base.count == 12 else { return base }
        let c = Array(base)
        return "\(c[0]) \(String(c[1...5])) \(String(c[6...10])) \(c[11])"
    }

    /// Starting spec for the details screen.
    var spec: ComicSpec {
        var spec = ComicSpec()
        spec.upc = fullUPC ?? base
        if let issue = issueNumber { spec.issue = String(issue) }
        if let printing, printing > 0 { spec.printing = printing }
        if let cover = coverVariant, cover > 1 {
            spec.notes = "Barcode says cover variant \(cover) — describe the cover in Variant (e.g. Cover B, artist name, 1:25)."
        }
        return spec
    }
}

// MARK: - Graded slab certificate

struct SlabCert: Hashable, Identifiable {
    var company: GradingCompany
    var number: String

    var id: String { "\(company.rawValue)-\(number)" }

    var lookupURL: URL? {
        switch company {
        case .cgc: return URL(string: "https://www.cgccomics.com/certlookup/\(number)/")
        case .psa: return URL(string: "https://www.psacard.com/cert/\(number)")
        case .cbcs, .pgx: return nil  // no automatic lookup; details are entered by hand
        }
    }

    /// Recognises the QR code / barcode on a slab label.
    init?(payload: String) {
        let lower = payload.lowercased()
        let digits = firstMatch(#"(\d{7,13})"#, in: payload)
        if lower.contains("cgccomics.com") || lower.contains("cgccards.com") {
            guard let digits else { return nil }
            self.init(company: .cgc, number: digits)
        } else if lower.contains("psacard.com") {
            guard let number = firstMatch(#"cert/(\d+)"#, in: lower) ?? digits else { return nil }
            self.init(company: .psa, number: number)
        } else if lower.contains("cbcscomics.com") {
            guard let digits else { return nil }
            self.init(company: .cbcs, number: digits)
        } else if payload.allSatisfy(\.isNumber), (7...12).contains(payload.count) {
            // A bare number from a label barcode. CGC comic certs are 10 digits ending in 00x.
            let looksCGC = payload.count == 10 && payload.dropLast().hasSuffix("00")
            self.init(company: looksCGC ? .cgc : .psa, number: payload)
        } else {
            return nil
        }
    }

    init(company: GradingCompany, number: String) {
        self.company = company
        self.number = number
    }
}

// MARK: - Helpers

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


/// First capture group (or whole match if there is no group) of a case-insensitive regex.
func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    let rangeIndex = match.numberOfRanges > 1 ? 1 : 0
    guard let range = Range(match.range(at: rangeIndex), in: text) else { return nil }
    return String(text[range])
}

/// All capture groups of the first match, or nil.
func firstGroups(_ pattern: String, in text: String) -> [String?]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    return (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}

func matches(_ pattern: String, _ text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

func replacing(_ pattern: String, in text: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
}
