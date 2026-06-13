import Foundation

/// Scans ~/.claude/projects/ directories to discover projects and session files.
/// Port of server/services/project-scanner.ts
struct ProjectScanner {
    let claudeDir: URL
    let parser: SessionParser
    let pricingTable: [String: ModelPricing]

    /// Maximum number of files parsed concurrently to avoid CPU saturation.
    /// Heavy Claude Code users can accumulate thousands of session files;
    /// unbounded concurrency pegs the CPU and starves the UI run loop.
    private static let maxConcurrentParses = 8

    /// Scan all projects and collect session metadata.
    /// The optional `onProgress` callback fires on MainActor with (processed, total) counts.
    func scan(onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil) async -> (projects: [Project], sessionsByProject: [String: [SessionSummary]]) {

        let projectsDir = claudeDir.appendingPathComponent("projects")
        var projects: [Project] = []
        var sessionsByProject: [String: [SessionSummary]] = [:]

        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            return (projects, sessionsByProject)
        }

        let projectDirs = dirNames.filter { name in
            var isDir: ObjCBool = false
            let fullPath = projectsDir.appendingPathComponent(name).path
            return fm.fileExists(atPath: fullPath, isDirectory: &isDir) && isDir.boolValue
        }

        // Collect all JSONL entries across all projects first, then parse with throttled concurrency
        var allEntries: [(dirName: String, url: URL, sessionId: String)] = []

        for dirName in projectDirs {
            let dirURL = projectsDir.appendingPathComponent(dirName)
            guard let topFiles = try? fm.contentsOfDirectory(atPath: dirURL.path) else {
                continue
            }

            for name in topFiles {
                if name.hasSuffix(".jsonl") {
                    let sid = String(name.dropLast(6))
                    allEntries.append((dirName, dirURL.appendingPathComponent(name), sid))
                    // A session file is never a directory, so it can't hold a
                    // subagents/ subdir. Skipping the probe below removes one
                    // failed `contentsOfDirectory` syscall per session file —
                    // i.e. ~half of all scan syscalls for projects dominated by
                    // top-level transcripts.
                    continue
                }
                // Only session-id *directories* can hold a subagents/ subdir.
                let subagentsDir = dirURL.appendingPathComponent(name).appendingPathComponent("subagents")
                if let subFiles = try? fm.contentsOfDirectory(atPath: subagentsDir.path) {
                    for subFile in subFiles where subFile.hasSuffix(".jsonl") {
                        let subId = String(subFile.dropLast(6))
                        allEntries.append((dirName, subagentsDir.appendingPathComponent(subFile), subId))
                    }
                }
            }
        }

        // Pre-fetch each file's mtime + size in a single stat() — reused both for
        // the newest-first sort AND as the cache fingerprint below.
        struct DatedEntry {
            let dirName: String
            let url: URL
            let sessionId: String
            let modDate: Date
            let size: Int
        }
        var datedEntries: [DatedEntry] = allEntries.map { entry in
            let attrs = try? fm.attributesOfItem(atPath: entry.url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? .distantPast
            let size = (attrs?[.size] as? Int) ?? 0
            return DatedEntry(dirName: entry.dirName, url: entry.url, sessionId: entry.sessionId,
                              modDate: date, size: size)
        }
        datedEntries.sort { $0.modDate > $1.modDate }

        // Persistent metadata cache: reuse a file's parsed summary when its mtime
        // AND size are unchanged since the last scan, so a relaunch only re-parses
        // new/modified transcripts. nil = cold cache (parse everything).
        let pricingSignature = ScanSummaryCache.pricingSignature(pricingTable)
        let cache = ScanSummaryCache.load(pricingSignature: pricingSignature)

        var resultsByProject: [String: [SessionSummary]] = [:]
        var newCacheEntries: [String: CachedSessionSummary] = [:]
        let projectDirSet = Set(projectDirs)
        let totalEntries = datedEntries.count
        var processed = 0

        // Partition into cache hits (reused immediately) and misses (parsed below).
        var misses: [DatedEntry] = []
        for de in datedEntries {
            let key = de.url.path
            if let cached = cache?[key],
               cached.mtime == de.modDate.timeIntervalSince1970,
               cached.size == de.size {
                resultsByProject[de.dirName, default: []].append(cached.summary)
                newCacheEntries[key] = cached
                processed += 1
            } else {
                misses.append(de)
            }
        }
        await onProgress?(processed, totalEntries)

        // Parse only the misses, with bounded concurrency to avoid CPU saturation.
        await withTaskGroup(of: (dirName: String, path: String, mtime: Double, size: Int, summary: SessionSummary)?.self) { group in
            var inflight = 0

            for de in misses {
                if Task.isCancelled { break }
                if inflight >= Self.maxConcurrentParses {
                    if let result = await group.next() {
                        if let r = result {
                            resultsByProject[r.dirName, default: []].append(r.summary)
                            newCacheEntries[r.path] = CachedSessionSummary(
                                mtime: r.mtime, size: r.size, dirName: r.dirName, summary: r.summary)
                        }
                        processed += 1
                        // Report progress every 50 files to avoid UI churn
                        if processed % 50 == 0 {
                            await onProgress?(processed, totalEntries)
                        }
                    }
                    inflight -= 1
                }

                let dirName = de.dirName
                let url = de.url
                let sessionId = de.sessionId
                let mtime = de.modDate.timeIntervalSince1970
                let size = de.size
                group.addTask {
                    do {
                        let summary = try await parser.parseMetadata(
                            url: url,
                            sessionId: sessionId,
                            pricingTable: pricingTable
                        )
                        return (dirName, url.path, mtime, size, summary)
                    } catch {
                        NSLog("[Claudoscope] Scanner: failed to parse %@: %@",
                              url.path, error.localizedDescription)
                        return nil
                    }
                }
                inflight += 1
            }

            for await result in group {
                if let r = result {
                    resultsByProject[r.dirName, default: []].append(r.summary)
                    newCacheEntries[r.path] = CachedSessionSummary(
                        mtime: r.mtime, size: r.size, dirName: r.dirName, summary: r.summary)
                }
                processed += 1
                if processed % 50 == 0 {
                    await onProgress?(processed, totalEntries)
                }
            }
        }

        await onProgress?(totalEntries, totalEntries)

        // Persist the cache for next launch. Skipped on cancellation so we never
        // drop entries for files this run didn't reach.
        if !Task.isCancelled {
            ScanSummaryCache.save(entries: newCacheEntries, pricingSignature: pricingSignature)
        }

        for dirName in projectDirSet {
            var sessions = resultsByProject[dirName] ?? []
            if sessions.isEmpty { continue }

            sessions.sort { a, b in
                if a.lastTimestamp.isEmpty && b.lastTimestamp.isEmpty { return false }
                if a.lastTimestamp.isEmpty { return false }
                if b.lastTimestamp.isEmpty { return true }
                return a.lastTimestamp > b.lastTimestamp
            }

            let project = Project(
                id: dirName,
                name: decodeProjectName(dirName),
                path: projectsDir.appendingPathComponent(dirName).path,
                sessionCount: sessions.count
            )

            projects.append(project)
            sessionsByProject[dirName] = sessions
        }

        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (projects, sessionsByProject)
    }
}

/// Decode an encoded project directory name into a human-readable project name.
/// Example: `-Users-liranb-projects-agent-hive` -> `agent-hive`
func decodeProjectName(_ encodedName: String) -> String {
    let segments = encodedName.split(separator: "-", omittingEmptySubsequences: true).map(String.init)

    var startIndex = 0

    // Look for "projects" keyword and take everything after it
    if let projectsIndex = segments.lastIndex(of: "projects"),
       projectsIndex + 1 < segments.count {
        startIndex = projectsIndex + 1
    } else if segments.count > 2,
              segments[0].lowercased() == "users" || segments[0].lowercased() == "home" {
        startIndex = 2
    }

    let meaningful = Array(segments[startIndex...])
    return meaningful.isEmpty ? encodedName : meaningful.joined(separator: "-")
}
