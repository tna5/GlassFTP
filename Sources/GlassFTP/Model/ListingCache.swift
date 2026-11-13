import Foundation

/// Bounded least-recently-used cache of directory listings.
///
/// Listings are what make navigation feel instant, but they are also the
/// largest thing the app holds: a folder of fifty thousand entries is roughly
/// ten megabytes, and a session that wanders through a deep tree would grow
/// without limit. The budget is counted in entries rather than folders, since
/// folder sizes vary by orders of magnitude.
struct ListingCache {
    /// Roughly 40 MB at ~200 bytes per entry.
    static let defaultBudget = 200_000

    private(set) var budget: Int
    private var storage: [String: [RemoteEntry]] = [:]
    /// Least recently stored first.
    private var order: [String] = []
    private(set) var totalEntries = 0

    init(budget: Int = defaultBudget) {
        self.budget = budget
    }

    subscript(path: String) -> [RemoteEntry]? {
        storage[path]
    }

    var cachedPaths: [String] { order }

    /// Inserts a listing, evicting the oldest folders until the budget is met.
    ///
    /// `pinned` is never evicted — it is the folder on screen, and dropping it
    /// would force an immediate refetch of the one listing certain to be needed.
    mutating func store(_ listing: [RemoteEntry], for path: String, pinning pinned: String?) {
        if let existing = storage[path] {
            totalEntries -= existing.count
            order.removeAll { $0 == path }
        }
        storage[path] = listing
        totalEntries += listing.count
        order.append(path)

        while totalEntries > budget {
            guard let victim = order.first(where: { $0 != path && $0 != pinned }) else { break }
            totalEntries -= storage[victim]?.count ?? 0
            storage.removeValue(forKey: victim)
            order.removeAll { $0 == victim }
        }
    }

    /// Changes the budget, evicting oldest-first if it shrank.
    mutating func setBudget(_ newBudget: Int, pinning pinned: String?) {
        budget = max(newBudget, 1_000)
        while totalEntries > budget {
            guard let victim = order.first(where: { $0 != pinned }) else { break }
            remove(victim)
        }
    }

    mutating func remove(_ path: String) {
        guard let existing = storage.removeValue(forKey: path) else { return }
        totalEntries -= existing.count
        order.removeAll { $0 == path }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
        totalEntries = 0
    }

    var isOverBudget: Bool { totalEntries >= budget }
}
