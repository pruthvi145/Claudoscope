import SwiftUI

// MARK: - Timeline Sidebar Content

struct TimelineSidebarContent: View {
    let filterText: String
    let entries: [HistoryEntry]
    @Binding var selectedDay: String?
    var onSelect: ((HistoryEntry) -> Void)?

    // Flattened, virtualized rows so the ENTIRE list is a single LazyVStack.
    // Previously each day's entries lived in a non-lazy ForEach inside daySection,
    // so a day with hundreds of entries built every row the moment its header hit
    // the viewport. A flat [Row] in one LazyVStack builds only the ~30 rows
    // actually on screen, regardless of total entry count. The grouping/sort that
    // produces these rows is memoized into @State below so it runs once per
    // (filterText, entries) change instead of on every body re-evaluation.
    private enum Row: Identifiable {
        case header(dayLabel: String, count: Int)
        case entry(HistoryEntry)
        var id: String {
            switch self {
            case .header(let dayLabel, _): return "h-\(dayLabel)"
            case .entry(let entry): return "e-\(entry.id)"
            }
        }
    }

    // Memoized derived data. `rows` is recomputed only in .task(id:) when the
    // filter text or the entries array changes — NOT on every scroll/selection
    // redraw. `isEmpty` mirrors the prior `filteredEntries.isEmpty` check.
    @State private var rows: [Row] = []
    @State private var isEmpty = true

    private static func computeRows(filterText: String, entries: [HistoryEntry]) -> [Row] {
        let filtered: [HistoryEntry]
        if filterText.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter { entry in
                entry.display.localizedCaseInsensitiveContains(filterText) ||
                (entry.project?.localizedCaseInsensitiveContains(filterText) ?? false) ||
                (entry.sessionId?.localizedCaseInsensitiveContains(filterText) ?? false)
            }
        }

        if filtered.isEmpty { return [] }

        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEE, MMM d"

        let grouped = Dictionary(grouping: filtered) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                return dayFormatter.string(from: entry.timestamp)
            }
        }

        // Sort groups by the newest entry in each group (preserves prior ordering).
        let sortedGroups = grouped
            .map { (key: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { groupA, groupB in
                let dateA = groupA.entries.first?.timestamp ?? .distantPast
                let dateB = groupB.entries.first?.timestamp ?? .distantPast
                return dateA > dateB
            }

        var result: [Row] = []
        for group in sortedGroups {
            result.append(.header(dayLabel: group.key, count: group.entries.count))
            for entry in group.entries {
                result.append(.entry(entry))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 24))
                        .foregroundStyle(.quaternary)
                    Text("No history found")
                        .font(Typography.body)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let dayLabel, let count):
                            dayHeaderRow(dayLabel, count: count)
                        case .entry(let entry):
                            TimelineSidebarRow(entry: entry) {
                                onSelect?(entry)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        // Recompute the memoized rows only when the inputs actually change — the
        // filter text or the entries array. A single signature-keyed .task fires
        // on first appearance and on any change, so the O(n) grouping/filter runs
        // once per change instead of on every body/scroll re-evaluation.
        .task(id: rowsSignature) {
            rebuildRows()
        }
    }

    // Cheap, stable identity for (filterText, entries). Detects a real input
    // change without requiring HistoryEntry to be Equatable.
    private var rowsSignature: String {
        "\(filterText)|\(entries.count)|\(entries.first?.id ?? "")|\(entries.last?.id ?? "")"
    }

    private func rebuildRows() {
        let computed = Self.computeRows(filterText: filterText, entries: entries)
        rows = computed
        isEmpty = computed.isEmpty
    }

    @ViewBuilder
    private func dayHeaderRow(_ dayLabel: String, count: Int) -> some View {
        Button {
            selectedDay = (selectedDay == dayLabel) ? nil : dayLabel
        } label: {
            HStack(spacing: 6) {
                Text(dayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selectedDay == dayLabel ? .white : .secondary)

                Text("\(count)")
                    .font(Typography.caption)
                    .foregroundStyle(selectedDay == dayLabel ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(selectedDay == dayLabel ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .background(selectedDay == dayLabel ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline Sidebar Row

private struct TimelineSidebarRow: View {
    let entry: HistoryEntry
    let onSelect: () -> Void

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: entry.timestamp)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 6) {
                Text(timeString)
                    .font(Typography.code)
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.display)
                        .font(Typography.body)
                        .lineLimit(2)
                        .foregroundStyle(.primary)

                    if let label = projectLabel(entry.project) {
                        Text(label)
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(AnyShapeStyle(.quaternary))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Timeline Main Panel View

struct TimelineMainPanelView: View {
    let entries: [HistoryEntry]
    let isLoading: Bool
    var onNavigateToSession: ((String, String, String?) -> Void)?

    @Environment(SessionStore.self) private var store
    @State private var expandedEntries: Set<String> = []

    // Memoized grouping of `entries` by day. Previously this was a computed
    // property recomputed (O(n log n)) on every ScrollView/body re-evaluation,
    // including every scroll tick. Now it is rebuilt once into @State whenever the
    // entries change (keyed by entries.count in .task) instead of per render.
    @State private var groupedByDayCache: [(key: String, entries: [HistoryEntry])] = []

    // Pre-computed sessionId -> (title, projectId) lookup. The previous
    // sessionInfo() scanned every project and every session (O(projects*sessions))
    // for EACH visible row. This dictionary makes the per-row lookup O(1). Rebuilt
    // only when store.sessionsByProject changes.
    @State private var sessionLookup: [String: (title: String, projectId: String)] = [:]

    // Pre-computed relative time strings keyed by entry.id. Avoids re-running
    // Date()-arithmetic + DateFormatter per visible row on every scroll/render.
    // Rebuilt when entries change or when refreshed on the periodic timer below so
    // "now"/"Nm" labels still advance as wall-clock time passes (same cadence the
    // old per-render computation effectively produced).
    @State private var timeStringCache: [String: String] = [:]

    private static let projectColors: [Color] = [
        .blue, .green, .orange, .pink, .indigo, .yellow
    ]

    private static let timeGutterWidth: CGFloat = 44
    private static let stripWidth: CGFloat = 3
    private static let longMessageThreshold = 120

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func computeGroupedByDay(_ entries: [HistoryEntry]) -> [(key: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current

        let grouped = Dictionary(grouping: entries) { entry -> String in
            if calendar.isDateInToday(entry.timestamp) {
                return "Today"
            } else if calendar.isDateInYesterday(entry.timestamp) {
                return "Yesterday"
            } else {
                return Self.dayFormatter.string(from: entry.timestamp)
            }
        }

        return grouped
            .map { (key: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { groupA, groupB in
                let dateA = groupA.entries.first?.timestamp ?? .distantPast
                let dateB = groupB.entries.first?.timestamp ?? .distantPast
                return dateA > dateB
            }
    }

    private static func computeSessionLookup(_ sessionsByProject: [String: [SessionSummary]]) -> [String: (title: String, projectId: String)] {
        var lookup: [String: (title: String, projectId: String)] = [:]
        for (projectId, sessions) in sessionsByProject {
            for session in sessions {
                // Preserve prior semantics: the old linear scan returned the FIRST
                // match it found. Don't overwrite an existing entry so the same
                // session id resolves to the same (title, projectId) as before.
                if lookup[session.id] == nil {
                    lookup[session.id] = (session.title, projectId)
                }
            }
        }
        return lookup
    }

    private static func computeTimeStrings(_ entries: [HistoryEntry]) -> [String: String] {
        let now = Date()
        var cache: [String: String] = [:]
        cache.reserveCapacity(entries.count)
        for entry in entries {
            cache[entry.id] = smartTimeString(entry.timestamp, now: now)
        }
        return cache
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    title: "No timeline entries",
                    message: "History entries from your Claude Code sessions will appear here."
                )
            } else {
                timelineContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Rebuild the day grouping and the relative-time cache once when entries
        // change, instead of recomputing them on every body/scroll evaluation.
        // Then refresh just the relative-time labels every 60s so "now"/"Nm" still
        // advance with the wall clock (matching the old per-render behavior),
        // without redoing the expensive grouping/lookups. The signature changes
        // whenever the entries array changes (count + first/last id), so a content
        // swap that keeps the same count still triggers a rebuild.
        .task(id: entriesSignature) {
            groupedByDayCache = Self.computeGroupedByDay(entries)
            timeStringCache = Self.computeTimeStrings(entries)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if Task.isCancelled { break }
                timeStringCache = Self.computeTimeStrings(entries)
            }
        }
        // Rebuild the O(1) session lookup only when the source map changes.
        .task(id: sessionsSignature) {
            sessionLookup = Self.computeSessionLookup(store.sessionsByProject)
        }
    }

    // Cheap, stable identity for the entries array. Avoids requiring HistoryEntry
    // to be Equatable while still detecting real changes (append/prepend/reload).
    private var entriesSignature: String {
        "\(entries.count)|\(entries.first?.id ?? "")|\(entries.last?.id ?? "")"
    }

    // Cheap identity for the session map: project count plus per-project session
    // counts. Changes when sessions are added/removed anywhere in the map.
    private var sessionsSignature: String {
        let perProject = store.sessionsByProject
            .map { "\($0.key):\($0.value.count)" }
            .sorted()
            .joined(separator: ",")
        return "\(store.sessionsByProject.count)|\(perProject)"
    }

    private var timelineContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groupedByDayCache, id: \.key) { group in
                    dayHeader(group.key, count: group.entries.count)

                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        let prev = index > 0 ? group.entries[index - 1] : nil
                        let gap = timeGapCategory(from: prev, to: entry)

                        if gap == .large && index > 0 {
                            gapSeparator
                        }

                        timelineRow(
                            entry: entry,
                            previousEntry: prev,
                            gap: gap
                        )
                    }
                }
            }
            .padding(.vertical, Spacing.lg)
            .padding(.horizontal, Spacing.xl)
        }
    }

    // MARK: - Day Header

    @ViewBuilder
    private func dayHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(Typography.sectionTitle)
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AnyShapeStyle(.quaternary))
                .clipShape(Capsule())

            Spacer()
        }
        .padding(.leading, Self.timeGutterWidth + Spacing.md + Self.stripWidth + Spacing.sm)
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Timeline Row

    @ViewBuilder
    private func timelineRow(entry: HistoryEntry, previousEntry: HistoryEntry?, gap: TimeGap) -> some View {
        let projectColor = colorForProject(entry.project)
        let isCommand = entry.display.hasPrefix("/")
        let isLong = !isCommand && entry.display.count > Self.longMessageThreshold
        let isExpanded = expandedEntries.contains(entry.id)
        let showBadge = shouldShowProjectBadge(entry, previousEntry: previousEntry, gap: gap)
        let showSession = shouldShowSessionId(entry, previousEntry: previousEntry)

        HStack(alignment: .top, spacing: 0) {
            // Time gutter
            VStack(alignment: .trailing, spacing: 1) {
                if !Calendar.current.isDateInToday(entry.timestamp) {
                    Text(Self.shortDateFormatter.string(from: entry.timestamp))
                        .font(Typography.micro)
                        .foregroundStyle(.quaternary)
                }
                Text(timeStringCache[entry.id] ?? Self.smartTimeString(entry.timestamp))
                    .font(Typography.codeSmall)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: Self.timeGutterWidth, alignment: .trailing)

            // Project color strip
            Rectangle()
                .fill(projectColor)
                .frame(width: Self.stripWidth)
                .padding(.leading, Spacing.md)

            // Content
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Session name (shown when session changes)
                if showSession, let info = sessionInfo(for: entry.sessionId) {
                    HStack {
                        Spacer()
                        if onNavigateToSession != nil {
                            Button {
                                onNavigateToSession?(info.projectId, info.sessionId, nil)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(info.title)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8, weight: .semibold))
                                }
                                .font(Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(info.title)
                                .font(Typography.codeSmall)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                    }
                }

                if isCommand {
                    Text(entry.display)
                        .font(Typography.codeSmall)
                        .foregroundStyle(.tertiary)
                } else if isLong && !isExpanded {
                    Text(entry.display)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Button {
                        withAnimation(.easeOut(duration: Motion.quick)) {
                            _ = expandedEntries.insert(entry.id)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                            Text("Show more")
                        }
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(entry.display)
                        .font(Typography.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    if isLong {
                        Button {
                            withAnimation(.easeOut(duration: Motion.quick)) {
                                _ = expandedEntries.remove(entry.id)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 8, weight: .semibold))
                                Text("Show less")
                            }
                            .font(Typography.caption)
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showBadge, let label = projectLabel(entry.project) {
                    Text(label)
                        .font(Typography.caption)
                        .foregroundStyle(projectColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(projectColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.leading, Spacing.sm)
            .padding(.vertical, isCommand ? Spacing.xs : Spacing.sm)
        }
        .padding(.top, gap.spacing)
    }

    // MARK: - Gap Separator

    private var gapSeparator: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, Self.timeGutterWidth + Spacing.md)
            .padding(.vertical, Spacing.sm)
    }

    // MARK: - Time Gap

    private enum TimeGap: Equatable {
        case tight
        case normal
        case wide
        case large

        var spacing: CGFloat {
            switch self {
            case .tight: return 0
            case .normal: return Spacing.xs
            case .wide: return Spacing.md
            case .large: return Spacing.lg
            }
        }
    }

    private func timeGapCategory(from previous: HistoryEntry?, to current: HistoryEntry) -> TimeGap {
        guard let previous else { return .tight }
        let interval = abs(previous.timestamp.timeIntervalSince(current.timestamp))
        if interval < 120 { return .tight }
        if interval < 600 { return .normal }
        if interval < 1800 { return .wide }
        return .large
    }

    // MARK: - Helpers

    private func shouldShowProjectBadge(_ entry: HistoryEntry, previousEntry: HistoryEntry?, gap: TimeGap) -> Bool {
        guard let prev = previousEntry else { return true }
        if gap == .large { return true }
        return entry.project != prev.project
    }

    private func shouldShowSessionId(_ entry: HistoryEntry, previousEntry: HistoryEntry?) -> Bool {
        guard let sid = entry.sessionId else { return false }
        guard let prev = previousEntry else { return true }
        return prev.sessionId != sid
    }

    private func sessionInfo(for sessionId: String?) -> (title: String, projectId: String, sessionId: String)? {
        guard let sessionId else { return nil }
        // O(1) lookup against the pre-computed cache. Falls back to a direct scan
        // only if the cache hasn't populated yet (e.g. first render before .task),
        // preserving the exact prior result either way.
        if let cached = sessionLookup[sessionId] {
            return (cached.title, cached.projectId, sessionId)
        }
        for (projectId, sessions) in store.sessionsByProject {
            if let match = sessions.first(where: { $0.id == sessionId }) {
                return (match.title, projectId, sessionId)
            }
        }
        return nil
    }

    private static func smartTimeString(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m"
        }
        return Self.timeFormatter.string(from: date)
    }

    private func colorForProject(_ path: String?) -> Color {
        guard let path else { return Self.projectColors[0] }
        let hash = abs(path.hashValue)
        let index = hash % Self.projectColors.count
        return Self.projectColors[index]
    }
}

// MARK: - Helpers

private func projectLabel(_ path: String?) -> String? {
    guard let path else { return nil }
    return path.split(separator: "/").last.map(String.init)
}
