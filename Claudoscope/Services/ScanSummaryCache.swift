import Foundation

// SessionSummary and its nested types (ModelTokenBreakdown, ModelDayCost,
// DailyContribution, SessionObservability, EffortDistribution, EffortLevel,
// ErrorClassification) declare `Codable` at their own definitions — struct
// Codable synthesis must live in the declaring file — so they serialize here
// directly with no manual coding.

/// One cached parse result plus the file fingerprint that validates it. A scan
/// reuses `summary` only when the file's mtime AND size are unchanged, so just
/// the new/modified transcripts get re-parsed on relaunch.
struct CachedSessionSummary: Codable {
    let mtime: Double   // file modificationDate as epoch seconds
    let size: Int
    let dirName: String // owning project directory (to rebuild sessionsByProject)
    let summary: SessionSummary
}

/// On-disk metadata cache: absolute file path -> CachedSessionSummary, persisted
/// as a binary plist under ~/Library/Caches/<bundleid>/.
///
/// Re-parsing every JSONL on each launch is the dominant startup cost (CPU-bound
/// JSON decoding of thousands of files). This cache turns a relaunch into "load
/// the plist + parse only what changed", cutting a multi-thousand-session scan
/// from tens of seconds to ~1-2s.
struct ScanSummaryCache: Codable {
    // Bump ONLY when the parser logic or SessionSummary shape changes, so a build
    // that parses differently won't trust stale summaries. Deliberately NOT tied
    // to the bundle/marketing version — keying on that re-scanned on every
    // cosmetic version bump (which made reopening the app rescan during dev).
    static let schemaVersion = 2

    var version: Int
    var pricingSignature: String  // invalidate when costs would differ
    var entries: [String: CachedSessionSummary]

    private static func cacheURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.claudoscope.app"
        let dir = base.appendingPathComponent(bundleId, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan-summary-cache.plist")
    }

    /// Process-stable signature of the active pricing table. Stored so changing
    /// provider/region/rates invalidates cached `estimatedCost` values.
    static func pricingSignature(_ table: [String: ModelPricing]) -> String {
        table.keys.sorted().map { k -> String in
            let p = table[k]!
            return "\(k):\(p.input),\(p.output),\(p.cacheRead),\(p.cacheCreation5m),\(p.cacheCreation1h),\(p.isUnknown)"
        }.joined(separator: ";")
    }

    /// Load cached entries, or nil if absent / unreadable / wrong schema /
    /// mismatched pricing — any of which forces a full reparse. NOT keyed on the
    /// bundle version, so reopening the app (or running a SHA-stamped rebuild)
    /// reuses the cache as long as parser schema and pricing are unchanged.
    static func load(pricingSignature: String) -> [String: CachedSessionSummary]? {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(ScanSummaryCache.self, from: data),
              cache.version == schemaVersion,
              cache.pricingSignature == pricingSignature
        else { return nil }
        return cache.entries
    }

    /// Persist the full set of current entries (atomic write). Best-effort: a
    /// failure here just means the next scan is cold, never incorrect.
    static func save(entries: [String: CachedSessionSummary], pricingSignature: String) {
        guard let url = cacheURL() else { return }
        let cache = ScanSummaryCache(
            version: schemaVersion,
            pricingSignature: pricingSignature,
            entries: entries
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
