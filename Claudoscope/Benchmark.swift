import Foundation

// Headless, all-feature performance benchmark.
//
// Run with:  Claudoscope --benchmark
// (intercepted in ClaudoscopeApp.init() before any window is created, so the
// GUI never launches). Times every major feature against the real
// ~/.claude data and prints a per-feature table, then exit(0).
//
// This is the "benchmark across all features" tool: it isolates each service
// operation that a UI interaction triggers, so we can see exactly where the
// time goes without having to click through the app.

enum PerfBenchmark {

    /// Bridge the async suite into the synchronous App.init() call site, then exit.
    static func runAndExit() -> Never {
        let sem = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await runSuite()
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    private static func ms(_ work: () async throws -> Void) async -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        do { try await work() } catch { FileHandle.standardError.write("  (step threw: \(error))\n".data(using: .utf8)!) }
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    private static func line(_ label: String, _ ms: Double, _ detail: String = "") {
        let l = label.padding(toLength: 34, withPad: " ", startingAt: 0)
        let m = String(format: "%9.1f ms", ms)
        print("\(l)\(m)   \(detail)")
    }

    private static func runSuite() async {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let pricing = PricingTables.anthropic
        let parser = SessionParser()

        print("")
        print("================ Claudoscope feature benchmark ================")
        print("data: \(claudeDir.appendingPathComponent("projects").path)")
        print("--------------------------------------------------------------")

        // 1) Full project scan (app startup / refresh cost)
        let scanner = ProjectScanner(claudeDir: claudeDir, parser: parser, pricingTable: pricing)
        var projects: [Project] = []
        var sessionsByProject: [String: [SessionSummary]] = [:]
        let scanMs = await ms {
            let r = await scanner.scan()
            projects = r.projects
            sessionsByProject = r.sessionsByProject
        }
        let totalSessions = sessionsByProject.values.reduce(0) { $0 + $1.count }
        line("1. Full scan (all sessions)", scanMs, "\(projects.count) projects, \(totalSessions) sessions")

        // Build the (session, project) pairs analytics consumes.
        var pairs: [(session: SessionSummary, project: Project)] = []
        for p in projects { for s in (sessionsByProject[p.id] ?? []) { pairs.append((s, p)) } }

        // Correctness checksum: cached summaries MUST reproduce the same cost/token
        // totals as a fresh parse. Compare this line cold vs warm — they must match
        // (modulo any session that changed on disk between the two runs).
        let sumCost = pairs.reduce(0.0) { $0 + $1.session.estimatedCost }
        let sumIn = pairs.reduce(0) { $0 + $1.session.totalInputTokens }
        let sumOut = pairs.reduce(0) { $0 + $1.session.totalOutputTokens }
        let sumCache = pairs.reduce(0) { $0 + $1.session.totalCacheReadTokens }
        print(String(format: "   checksum: sessions=%ld cost=%.4f in=%ld out=%ld cacheRead=%ld",
                     pairs.count, sumCost, sumIn, sumOut, sumCache))

        // Locate the largest transcript = worst-case "click a session" target.
        let largest = locateLargestSession(under: claudeDir.appendingPathComponent("projects"))

        // 2) Full parse of the largest session (the synchronous cost of opening it)
        var parsed: ParsedSession?
        if let largest {
            let parseMs = await ms {
                parsed = try await parser.parse(url: largest.url, sessionId: largest.sessionId)
            }
            let sizeMB = Double(largest.size) / 1_048_576.0
            line("2. Open largest session (parse)", parseMs,
                 String(format: "%.1f MB, %d records", sizeMB, parsed?.records.count ?? 0))
        }

        // 3) Markdown render simulation: parseMarkdown over every message body.
        //    The UI runs this inside `body` per visible message on EVERY re-render,
        //    so we report both a single pass and the per-message cost.
        if let parsed {
            let texts = parsed.records.compactMap { rec -> String? in
                guard let t = rec.message?.content?.textContent, !t.isEmpty else { return nil }
                return t
            }
            var blockCount = 0
            let mdMs = await ms {
                for t in texts { blockCount += parseMarkdown(t).count }
            }
            let perMsg = texts.isEmpty ? 0 : mdMs / Double(texts.count)
            line("3. Markdown parse (1 render pass)", mdMs,
                 String(format: "%d msgs, %.2f ms/msg, %d blocks", texts.count, perMsg, blockCount))

            // 4) Per-message regex tag-strip (ChatMessageViews.displayText), also per render.
            let stripMs = await ms {
                for t in texts { _ = stripSystemTags(t) }
            }
            line("4. Regex tag-strip (1 render pass)", stripMs,
                 String(format: "%.3f ms/msg", texts.isEmpty ? 0 : stripMs / Double(texts.count)))

            // 4b) ChatView derived maps. OLD: computed-property recomputed per visible
            // row with an O(turns × records) nested loop → simulate ~25 visible rows on
            // first render. NEW: computed once, O(records). This is the real "opening a
            // session takes seconds" cost the per-feature timings above couldn't see.
            let recs = parsed.records
            func oldTurnDurations() -> [Int: TurnDuration] {
                let durations = ObservabilityAnalyzer.computeTurnDurations(records: recs)
                var dict: [Int: TurnDuration] = [:]
                var turnIndex = 0
                var recordToTurn: [Int: Int] = [:]
                for (i, record) in recs.enumerated() where record.type == .assistant && record.message?.stopReason != nil {
                    recordToTurn[i] = turnIndex; turnIndex += 1
                }
                for duration in durations {
                    for (recordIdx, turn) in recordToTurn where turn == duration.turnIndex { dict[recordIdx] = duration }
                }
                return dict
            }
            func newTurnDurations() -> [Int: TurnDuration] {
                let durations = ObservabilityAnalyzer.computeTurnDurations(records: recs)
                var turnToRecord: [Int: Int] = [:]
                var turnIndex = 0
                for (i, record) in recs.enumerated() where record.type == .assistant && record.message?.stopReason != nil {
                    turnToRecord[turnIndex] = i; turnIndex += 1
                }
                var dict: [Int: TurnDuration] = [:]
                for duration in durations { if let r = turnToRecord[duration.turnIndex] { dict[r] = duration } }
                return dict
            }
            let visibleRows = 25
            let oldMs = await ms { for _ in 0..<visibleRows { _ = oldTurnDurations() } }
            let newMs = await ms { _ = newTurnDurations() }
            line("4b. ChatView open (OLD per-row)", oldMs,
                 String(format: "%d visible rows × recompute | NEW once=%.1fms (%.0f× faster)",
                        visibleRows, newMs, newMs > 0 ? oldMs / newMs : 0))
        }

        // 5) Analytics compute across time ranges (the Analytics tab cost)
        for (label, days) in [("7d", 7), ("30d", 30), ("90d", 90)] {
            let from = Calendar.current.date(byAdding: .day, value: -days, to: Date())
            let ams = await ms {
                _ = AnalyticsEngine.compute(sessions: pairs, pricingTable: pricing, from: from, to: nil)
            }
            line("5. Analytics compute (\(label))", ams)
        }
        let allMs = await ms {
            _ = AnalyticsEngine.compute(sessions: pairs, pricingTable: pricing, from: nil, to: nil)
        }
        line("5. Analytics compute (all)", allMs)

        // 6) Config-health lint (fast checks + per-session checks)
        let linter = ConfigLinterService()
        let allSessions = sessionsByProject.values.flatMap { $0 }
        let lintMs = await ms {
            _ = await linter.lint(projectRoot: nil, globalClaudeDir: claudeDir)
            _ = await linter.lintSessions(allSessions)
        }
        line("6. Config-health lint", lintMs, "\(allSessions.count) sessions")

        // 7) Secret scan over full history (the slow background pass)
        let secretMs = await ms {
            _ = await linter.lintSessionSecrets(allSessions, claudeDir: claudeDir)
        }
        line("7. Secret scan (full history)", secretMs)

        // 8) Timeline load
        let timeline = TimelineService(claudeDir: claudeDir)
        let tlMs = await ms { _ = await timeline.loadEntries(since: nil, limit: nil) }
        line("8. Timeline load", tlMs)

        // 9) Plans load
        let plansSvc = PlansService(claudeDir: claudeDir)
        let plansMs = await ms { _ = await plansSvc.loadPlans() }
        line("9. Plans load", plansMs)

        print("==============================================================")
        print("")
    }

    /// Walk ~/.claude/projects (top-level transcripts only) and return the largest.
    private static func locateLargestSession(under projectsDir: URL) -> (url: URL, sessionId: String, size: Int)? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return nil }
        var best: (url: URL, sessionId: String, size: Int)?
        for dir in dirs {
            let dirURL = projectsDir.appendingPathComponent(dir)
            guard let files = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let url = dirURL.appendingPathComponent(f)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 ?? 0
                if best == nil || size > best!.size {
                    best = (url, String(f.dropLast(6)), size)
                }
            }
        }
        return best
    }

    /// Mirror of ChatMessageViews.UserMessageBubble.displayText tag stripping.
    private static func stripSystemTags(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<user-prompt-submit-hook>[\s\S]*?</user-prompt-submit-hook>"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
