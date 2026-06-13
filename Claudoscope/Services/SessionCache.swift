import Foundation
import OrderedCollections

/// LRU cache for parsed sessions, capacity 50.
actor SessionCache {
    private var cache = OrderedDictionary<String, ParsedSession>()
    private let capacity: Int

    // Bumped 20 -> 50: heavy users navigate far more than 20 sessions in a
    // sitting, and the old cap forced a full re-parse every time a session
    // scrolled out of the window. 50 keeps recently-viewed transcripts hot
    // while staying well within memory (records are the only large field).
    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func get(_ key: String) -> ParsedSession? {
        guard let value = cache[key] else { return nil }
        // Move to end (most recently used)
        cache.removeValue(forKey: key)
        cache[key] = value
        return value
    }

    func set(_ key: String, value: ParsedSession) {
        cache.removeValue(forKey: key)
        cache[key] = value

        // Evict oldest if over capacity
        while cache.count > capacity {
            cache.removeFirst()
        }
    }

    func invalidate(_ key: String) {
        cache.removeValue(forKey: key)
    }

    func clear() {
        cache.removeAll()
    }
}
