import SwiftUI

// MARK: - Tools Sidebar

struct ToolsSidebarContent: View {
    let projects: [Project]
    let sessionsByProject: [String: [SessionSummary]]
    let filterText: String
    @Binding var selectedSessionId: String?
    @Binding var selectedProjectId: String?
    // Collapse state lifted out of the per-project view so the whole list can be
    // ONE flat LazyVStack (mirrors SessionsSidebarContent). Empty = every project
    // expanded, matching the prior `isExpanded = true` default.
    @State private var collapsedProjects: Set<String> = []

    // Flattened rows so the ENTIRE list is virtualized. Previously each project's
    // sessions lived in a non-lazy ForEach inside its ToolsProjectGroup, so a
    // project with thousands of sessions built every row the moment it hit the
    // viewport. A single LazyVStack over a flat [Row] builds only the rows on
    // screen, regardless of total session count.
    private enum Row: Identifiable {
        case header(project: Project, count: Int)
        case session(SessionSummary, projectId: String)
        var id: String {
            switch self {
            case .header(let project, _): return "h-\(project.id)"
            case .session(let session, _): return "s-\(session.id)"
            }
        }
    }

    private var rows: [Row] {
        let filtering = !filterText.isEmpty
        var result: [Row] = []
        for project in projects {
            // Subagents are hidden — see SidebarView for rationale.
            let visible = (sessionsByProject[project.id] ?? []).filter { !$0.isSubagent }
            let matching: [SessionSummary]
            if filtering {
                let titleMatched = visible.filter { $0.title.localizedCaseInsensitiveContains(filterText) }
                let nameMatches = project.name.localizedCaseInsensitiveContains(filterText)
                if !nameMatches && titleMatched.isEmpty { continue }
                matching = titleMatched
            } else {
                matching = visible
            }
            result.append(.header(project: project, count: matching.count))
            if !collapsedProjects.contains(project.id) {
                for session in matching {
                    result.append(.session(session, projectId: project.id))
                }
            }
        }
        return result
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .header(let project, let count):
                    ToolsProjectHeaderRow(
                        name: project.name,
                        count: count,
                        isExpanded: !collapsedProjects.contains(project.id)
                    ) {
                        if collapsedProjects.contains(project.id) {
                            collapsedProjects.remove(project.id)
                        } else {
                            collapsedProjects.insert(project.id)
                        }
                    }
                case .session(let session, let projectId):
                    ToolsSessionRow(
                        session: session,
                        isSelected: selectedSessionId == session.id
                    ) {
                        selectedSessionId = session.id
                        selectedProjectId = projectId
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ToolsProjectHeaderRow: View {
    let name: String
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: Motion.quick)) { onToggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                Text(name)
                    .font(Typography.bodyMedium)
                    .lineLimit(1)

                Spacer()

                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ToolsSessionRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Text(formatRelativeTime(session.lastTimestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if session.toolCallCount > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "wrench")
                            .font(.system(size: 9))
                        Text("\(session.toolCallCount)")
                            .font(Typography.caption)
                    }
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.leading, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.04) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Tools Main Panel

struct ToolsMainPanelView: View {
    let session: ParsedSession

    @State private var selectedCategories: Set<ToolCategory> = Set(ToolCategory.allCases)
    @State private var errorsOnly = false
    @State private var searchText = ""
    @State private var grouping: ToolGrouping = .flat
    @State private var expandedEntries: Set<String> = []

    // Session-derived data, extracted once per session via `.task(id: session.id)`
    // instead of on every body evaluation. `extractToolCalls` walks every record
    // and `computeToolAnalytics` scans all entries — doing that work on each render
    // (and each keystroke) was the main cost. `analytics` is derived in the same
    // task right after `entries`, so the two never disagree.
    @State private var entries: [ToolCallEntry] = []
    @State private var analytics: ToolAnalytics = .empty

    // Filter result, recomputed only when an input actually changes (the filter
    // fields, or the underlying entries) rather than on every render. Previously
    // this O(n) `localizedCaseInsensitiveContains` scan ran on every body eval and
    // was read once per row.
    @State private var filteredEntries: [ToolCallEntry] = []

    // Grouped views of `filteredEntries`, memoized so the `Dictionary(grouping:)`
    // work happens once per filter change instead of on every body evaluation of
    // the (lazy) tool-call list. Derived alongside `filteredEntries`.
    @State private var groupedByTurn: [(turn: Int, entries: [ToolCallEntry])] = []
    @State private var groupedByCategory: [ToolCategory: [ToolCallEntry]] = [:]

    private func computeEntries() {
        let extracted = extractToolCalls(from: session)
        entries = extracted
        analytics = computeToolAnalytics(extracted)
        recomputeFiltered()
    }

    private func recomputeFiltered() {
        let result = entries.filter { entry in
            guard selectedCategories.contains(entry.category) else { return false }
            if errorsOnly && !entry.isError { return false }
            if !searchText.isEmpty {
                let haystack = [
                    entry.toolName,
                    entry.primaryArg ?? "",
                    entry.resultContent ?? ""
                ].joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(searchText) {
                    return false
                }
            }
            return true
        }
        filteredEntries = result

        // Memoize the grouped representations from the same result.
        let byTurn = Dictionary(grouping: result, by: \.turnIndex)
        groupedByTurn = byTurn.keys.sorted().map { (turn: $0, entries: byTurn[$0] ?? []) }
        groupedByCategory = Dictionary(grouping: result, by: \.category)
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    icon: "wrench.and.screwdriver",
                    title: "No tool calls",
                    message: "This session has no tool usage to display."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        // Header
                        Text("Tools \u{2014} Session \"\(session.slug ?? session.id)\"")
                            .font(Typography.panelTitle)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.top, Spacing.lg)

                        // Stat cards
                        statsRow
                            .padding(.horizontal, Spacing.xl)

                        // Filters
                        filtersRow
                            .padding(.horizontal, Spacing.xl)

                        // Grouping
                        groupingPicker
                            .padding(.horizontal, Spacing.xl)

                        Divider()
                            .padding(.horizontal, Spacing.xl)

                        // Tool call list
                        toolCallList
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.xl)
                    }
                }
            }
        }
        .task(id: session.id) { computeEntries() }
        .onChange(of: searchText) { _, _ in recomputeFiltered() }
        .onChange(of: selectedCategories) { _, _ in recomputeFiltered() }
        .onChange(of: errorsOnly) { _, _ in recomputeFiltered() }
    }

    // MARK: - Stat Cards Row

    private var statsRow: some View {
        HStack(spacing: Spacing.md) {
            StatCard(
                title: "Total Calls",
                value: "\(analytics.totalCalls)"
            )
            StatCard(
                title: "Errors",
                value: "\(analytics.errorCount)",
                isHighlighted: analytics.errorCount > 0
            )
            StatCard(
                title: "Error Rate",
                value: String(format: "%.1f%%", analytics.errorRate * 100),
                isHighlighted: analytics.errorRate > 0.1
            )
            StatCard(
                title: "Files Touched",
                value: "\(analytics.uniqueFilesTouched)"
            )
        }
    }

    // MARK: - Category Filter Chips + Search

    private var filtersRow: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(ToolCategory.allCases, id: \.rawValue) { category in
                ToolCategoryChip(
                    category: category,
                    isSelected: selectedCategories.contains(category)
                ) {
                    if selectedCategories.contains(category) {
                        selectedCategories.remove(category)
                    } else {
                        selectedCategories.insert(category)
                    }
                }
            }

            Divider()
                .frame(height: 20)

            Toggle(isOn: $errorsOnly) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("Errors Only")
                        .font(Typography.caption)
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(errorsOnly ? Color.red.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(errorsOnly ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1)
            )

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search tools...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
    }

    // MARK: - Grouping Picker

    private var groupingPicker: some View {
        HStack(spacing: Spacing.sm) {
            Text("Grouping:")
                .font(Typography.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: $grouping) {
                ForEach(ToolGrouping.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            Spacer()

            Text("\(filteredEntries.count) of \(entries.count) calls")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Tool Call List

    @ViewBuilder
    private var toolCallList: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text("No matching tool calls")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.xl)
        } else {
            switch grouping {
            case .flat:
                LazyVStack(spacing: Spacing.xs) {
                    ForEach(filteredEntries) { entry in
                        ToolCallRow(
                            entry: entry,
                            isExpanded: expandedEntries.contains(entry.id),
                            onToggle: { toggleExpanded(entry.id) }
                        )
                    }
                }

            case .byTurn:
                LazyVStack(spacing: Spacing.sm) {
                    ForEach(groupedByTurn, id: \.turn) { turn, turnEntries in
                        DisclosureGroup {
                            VStack(spacing: Spacing.xs) {
                                ForEach(turnEntries) { entry in
                                    ToolCallRow(
                                        entry: entry,
                                        isExpanded: expandedEntries.contains(entry.id),
                                        onToggle: { toggleExpanded(entry.id) }
                                    )
                                }
                            }
                        } label: {
                            HStack(spacing: Spacing.sm) {
                                Text("Turn \(turn)")
                                    .font(Typography.bodyMedium)
                                Text("\(turnEntries.count) tool calls")
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

            case .byCategory:
                let orderedCategories: [ToolCategory] = [.read, .write, .exec, .other]
                LazyVStack(spacing: Spacing.lg) {
                    ForEach(orderedCategories, id: \.rawValue) { category in
                        if let catEntries = groupedByCategory[category], !catEntries.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                HStack(spacing: Spacing.sm) {
                                    Circle()
                                        .fill(categoryColorForCategory(category))
                                        .frame(width: 8, height: 8)
                                    Text(category.label.uppercased())
                                        .font(Typography.sectionLabel)
                                        .foregroundStyle(.secondary)
                                    Text("\(catEntries.count)")
                                        .font(Typography.caption)
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(Capsule())
                                }

                                ForEach(catEntries) { entry in
                                    ToolCallRow(
                                        entry: entry,
                                        isExpanded: expandedEntries.contains(entry.id),
                                        onToggle: { toggleExpanded(entry.id) }
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleExpanded(_ id: String) {
        withAnimation(.easeInOut(duration: Motion.quick)) {
            if expandedEntries.contains(id) {
                expandedEntries.remove(id)
            } else {
                expandedEntries.insert(id)
            }
        }
    }
}

// MARK: - Tool Call Row

private struct ToolCallRow: View {
    let entry: ToolCallEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button(action: onToggle) {
                HStack(spacing: 0) {
                    // Category color bar
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(categoryColor(for: entry.toolName))
                        .frame(width: 3)
                        .padding(.trailing, Spacing.sm)

                    // Tool icon
                    Image(systemName: toolIcon(for: entry.toolName))
                        .font(.system(size: 12))
                        .foregroundStyle(categoryColor(for: entry.toolName))
                        .frame(width: 20)

                    // Tool name
                    Text(entry.toolName)
                        .font(Typography.bodyMedium)
                        .padding(.leading, Spacing.xs)

                    // Primary arg
                    if let arg = entry.primaryArg {
                        Text(arg)
                            .font(Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, Spacing.sm)
                    }

                    Spacer()

                    // Error badge
                    if entry.isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .padding(.trailing, Spacing.xs)
                    }

                    // Expand chevron
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    // Input JSON
                    if !entry.input.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("INPUT")
                                .font(Typography.micro)
                                .foregroundStyle(.tertiary)

                            Text(formatInputJSON(entry.input))
                                .font(Typography.codeSmall)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.sm)
                                .background(Color.primary.opacity(0.03))
                                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                    }

                    // Result content
                    if let result = entry.resultContent, !result.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text(entry.isError ? "ERROR" : "RESULT")
                                .font(Typography.micro)
                                .foregroundStyle(entry.isError ? Color.red : Color.secondary)

                            ScrollView(.vertical) {
                                Text(result.prefix(2000) + (result.count > 2000 ? "\n... (\(result.count) chars total)" : ""))
                                    .font(Typography.codeSmall)
                                    .foregroundStyle(entry.isError ? .red.opacity(0.8) : .secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .padding(Spacing.sm)
                            .background(entry.isError ? Color.red.opacity(0.04) : Color.primary.opacity(0.03))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.leading, 23) // align with content after color bar + icon
                .padding(.bottom, Spacing.md)
            }
        }
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

// MARK: - Category Chip

private struct ToolCategoryChip: View {
    let category: ToolCategory
    let isSelected: Bool
    let onTap: () -> Void

    private var chipColor: Color {
        categoryColorForCategory(category)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Circle()
                    .fill(chipColor)
                    .frame(width: 6, height: 6)
                Text(category.label)
                    .font(Typography.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? chipColor.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(isSelected ? chipColor.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .opacity(isSelected ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grouping Mode

private enum ToolGrouping: String, CaseIterable {
    case flat
    case byTurn
    case byCategory

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .byTurn: return "By Turn"
        case .byCategory: return "By Category"
        }
    }
}

// MARK: - Helpers

/// Get category color from a ToolCategory enum value (not a tool name)
private func categoryColorForCategory(_ category: ToolCategory) -> Color {
    switch category {
    case .read:  return Color(red: 0.52, green: 0.72, blue: 0.92)
    case .write: return Color(red: 0.36, green: 0.79, blue: 0.65)
    case .exec:  return Color(red: 0.83, green: 0.66, blue: 0.26)
    case .other: return .secondary
    }
}

/// Format tool input dictionary as readable JSON-like text
private func formatInputJSON(_ input: [String: AnyCodableValue]) -> String {
    let lines = input.sorted(by: { $0.key < $1.key }).map { key, value in
        "\(key): \(value.displayString)"
    }
    return lines.joined(separator: "\n")
}
