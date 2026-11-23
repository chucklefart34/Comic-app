import Foundation

/// Sold listings fetched ahead of time (while you pick a cover), so prices show the moment you tap.
/// Keyed by title + issue; entries are reused for 15 minutes.
@MainActor
final class SoldCache {
    static let shared = SoldCache()

    private var entries: [String: (started: Date, task: Task<[SoldListing], Error>)] = [:]

    static func key(for spec: ComicSpec) -> String {
        "\(spec.title.trimmed.lowercased())|\(spec.issue.trimmed.lowercased())"
    }

    /// Starts fetching a broad title + issue search unless one is already running or fresh.
    /// `seed` is added to the results (e.g. sold listings found by barcode).
    func prefetch(for spec: ComicSpec, seed: [SoldListing], bot: WebBot) {
        let key = Self.key(for: spec)
        guard !spec.title.trimmed.isEmpty, !spec.issue.trimmed.isEmpty, fresh(key) == nil else { return }
        let query = spec.broadQuery
        let task = Task<[SoldListing], Error> {
            let found = try await EbaySoldSearch.soldListings(query: query, bot: bot, comicsOnly: Prefs.searchComicsOnly)
            return merge(seed, found)
        }
        entries[key] = (Date(), task)
    }

    /// The prefetched (or still loading) results for this title + issue, if any.
    func results(for spec: ComicSpec) -> Task<[SoldListing], Error>? {
        fresh(Self.key(for: spec))
    }

    private func fresh(_ key: String) -> Task<[SoldListing], Error>? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.started) < 15 * 60 else { return nil }
        return entry.task
    }
}

/// Combines listing lists, dropping duplicates (same eBay item).
func merge(_ first: [SoldListing], _ second: [SoldListing]) -> [SoldListing] {
    var seen = Set<String>()
    return (first + second).filter { seen.insert($0.id).inserted }
}
