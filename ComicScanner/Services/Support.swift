import Foundation
import Network
import Security

/// Reads any JSON without a fixed schema — useful for APIs whose field types vary (numbers as strings, etc.).
enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? {
        switch self {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return ["true", "1", "yes"].contains(s.lowercased())
        default: return nil
        }
    }

    var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }
}

/// API tokens live in the iOS Keychain, never in the app's code.
enum Keychain {
    private static let service = "ComicScanner"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Optional service tokens the user can add in Settings.
enum Tokens {
    static let verseDBKey = "versedb.token"
    static let priceChartingKey = "pricecharting.token"

    static var verseDB: String? { Keychain.get(verseDBKey) }
    static var priceCharting: String? { Keychain.get(priceChartingKey) }
}

/// Watches whether the phone is online.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { NetworkMonitor.shared.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }
}

enum ServiceError: LocalizedError {
    case offline
    case unauthorized(String)
    case rateLimited(String)
    case http(String, Int)
    case badData(String)
    /// A plain message shown as it is.
    case message(String)

    var errorDescription: String? {
        switch self {
        case .offline: return "You're offline."
        case .unauthorized(let service): return "\(service) didn't accept your token. Check it in Settings."
        case .rateLimited(let service): return "\(service) limit reached for now. Try again in a minute."
        case .http(let service, let code): return "\(service) returned error \(code)."
        case .badData(let service): return "Couldn't read the reply from \(service)."
        case .message(let text): return text
        }
    }
}
