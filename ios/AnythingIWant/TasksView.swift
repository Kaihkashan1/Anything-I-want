import SwiftUI

/// The Tasks tab — a general to-do list (chores, errands, trip prep), kept
/// apart from Shop/Pack because those merge duplicate ingredients and sort
/// by aisle. Open tasks are grouped by list; Done shows finished ones,
/// newest first, with a "Clear done" button.
struct TasksView: View {
    @Environment(TaskStore.self) private var tasks

    @State private var query = ""
    @State private var segment: TaskSegment = .open
    @State private var presentedSheet: TaskPresentedSheet?

    private enum TaskSegment: String, CaseIterable, Identifiable {
        case open = "Open"
        case done = "Done"
        var id: String { rawValue }
        var localizedName: String { L(String.LocalizationValue(rawValue)) }
    }

    private enum TaskPresentedSheet: Identifiable {
        case add
        case edit(TaskItem)
        case lists

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let task): "edit-\(task.id)"
            case .lists: "lists"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                segmentRow
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 12)
                searchField
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 14)
                content
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.bottom, 16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await tasks.refresh() }
        .sheet(item: $presentedSheet) { sheet in
            sheetContent(for: sheet)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { tasks.actionError != nil },
                set: { shown in if !shown { tasks.actionError = nil } }
            ),
            presenting: tasks.actionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: TaskPresentedSheet) -> some View {
        switch sheet {
        case .add:
            TaskItemSheet(task: nil, lists: tasks.lists) { tasks.upsert($0) }
        case .edit(let task):
            TaskItemSheet(task: task, lists: tasks.lists) { tasks.upsert($0) }
        case .lists:
            TaskListsSheet()
                .environment(tasks)
        }
    }

    // MARK: - Header / controls

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tasks")
                    .font(Theme.display(36))
                    .foregroundStyle(Theme.ink)
                Text(L("\(tasks.openCount) open · \(tasks.doneCount) done"))
                    .font(Theme.body(10.5, weight: .semibold))
                    .tracking(1.47)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accent700)
            }
            Spacer()
            HStack(spacing: 8) {
                ShareListButton(text: ListExport.tasks(tasks.items, lists: tasks.lists))

                CircleIconButton(lucide: .gear) {
                    presentedSheet = .lists
                }
                .accessibilityLabel(L("Task lists"))

                Button {
                    presentedSheet = .add
                } label: {
                    LucideIcon(.plus, size: 19)
                        .foregroundStyle(Theme.bg)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Add task"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 66)
        .padding(.horizontal, Theme.screenPadding)
        .padding(.bottom, 16)
    }

    private var segmentRow: some View {
        HStack(spacing: 7) {
            ForEach(TaskSegment.allCases) { option in
                Button {
                    segment = option
                } label: {
                    Text(option.localizedName)
                        .font(Theme.body(13, weight: .semibold))
                        .foregroundStyle(segment == option ? .white : Theme.neutral800)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 4)
                        .background(segment == option ? Theme.accent : Theme.surface)
                        .overlay {
                            if segment != option {
                                Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                            }
                        }
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.localizedName)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            LucideIcon(.search, size: 17)
                .foregroundStyle(Theme.neutral600)
            TextField(L("Search tasks"), text: $query)
                .font(Theme.body(14.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Theme.surface)
        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
        .clipShape(Capsule())
    }

    // MARK: - Filtering / sorting

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matchesQuery(_ task: TaskItem) -> Bool {
        let q = trimmedQuery
        guard !q.isEmpty else { return true }
        return task.title.lowercased().contains(q)
            || task.notes.lowercased().contains(q)
            || task.list.lowercased().contains(q)
    }

    /// Open tasks per list, in list order. Within a list: dated tasks first,
    /// earliest due date first (so overdue ones lead), then undated ones in
    /// the order they were added.
    private var groupedOpen: [(list: String, tasks: [TaskItem])] {
        var indexed: [(task: TaskItem, index: Int)] = []
        for (index, task) in tasks.items.enumerated() where !task.done && matchesQuery(task) {
            indexed.append((task, index))
        }
        let names = mergeTaskLists(stored: tasks.lists, itemLists: indexed.map { $0.task.list })
        var groups: [(list: String, tasks: [TaskItem])] = []
        for name in names {
            let rows = indexed.filter { $0.task.isIn(list: name) }
            guard !rows.isEmpty else { continue }
            let sorted = rows.sorted { lhs, rhs in
                let leftDue = lhs.task.due ?? ""
                let rightDue = rhs.task.due ?? ""
                if leftDue.isEmpty != rightDue.isEmpty { return !leftDue.isEmpty }
                if leftDue != rightDue { return leftDue < rightDue }
                return lhs.index < rhs.index
            }
            groups.append((name, sorted.map { $0.task }))
        }
        return groups
    }

    /// Finished tasks, most recently ticked first.
    private var doneTasks: [TaskItem] {
        tasks.items
            .filter { $0.done && matchesQuery($0) }
            .sorted { ($0.doneAt ?? "") > ($1.doneAt ?? "") }
    }

    // MARK: - Content

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(Theme.body(14))
            .foregroundStyle(Theme.neutral600)
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
    }

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .open:
            if tasks.openCount == 0 {
                emptyText(L("No open tasks. Tap + to add one."))
            } else if groupedOpen.isEmpty {
                emptyText(L("Nothing matches that yet."))
            } else {
                ForEach(groupedOpen, id: \.list) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(group.list.uppercased(with: Locale(identifier: "en")))
                            .font(Theme.body(10.5, weight: .semibold))
                            .tracking(1.26)
                            .foregroundStyle(Theme.neutral600)
                        ForEach(group.tasks) { task in
                            taskRow(task)
                        }
                    }
                    .padding(.bottom, 18)
                }
            }
        case .done:
            if tasks.doneCount == 0 {
                emptyText(L("Nothing done yet."))
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Spacer()
                        Button {
                            tasks.clearDone()
                        } label: {
                            Text("Clear done")
                                .font(Theme.body(12.5, weight: .semibold))
                                .foregroundStyle(Theme.accent700)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if doneTasks.isEmpty {
                        emptyText(L("Nothing matches that yet."))
                    } else {
                        ForEach(doneTasks) { task in
                            taskRow(task)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                tasks.toggleDone(id: task.id)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(task.done ? Theme.sage500 : Theme.neutral400, lineWidth: 2)
                        .background(Circle().fill(task.done ? Theme.sage500 : .clear))
                    if task.done {
                        LucideIcon(.check, size: 12)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.done ? L("Mark \(task.title) not done") : L("Mark \(task.title) done"))

            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(Theme.body(14.5, weight: .semibold))
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? Theme.neutral500 : Theme.neutral900)
                    .multilineTextAlignment(.leading)

                if !task.notes.isEmpty {
                    Text(task.notes)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.neutral600)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !task.done, let badge = task.dueBadge {
                    metaChip(badge.label, fill: badge.fill, foreground: badge.foreground, border: badge.border)
                } else if task.done, segment == .done {
                    metaChip(task.list, fill: Theme.neutral100, foreground: Theme.neutral700)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            LucideTrashButton(accessibilityLabel: L("Remove \(task.title)")) {
                tasks.delete(id: task.id)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .cardBackground(radius: 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            presentedSheet = .edit(task)
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(task.title)
    }

    private func metaChip(
        _ text: String,
        fill: Color,
        foreground: Color,
        border: Color? = nil
    ) -> some View {
        Text(text)
            .font(Theme.body(10.5, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(fill)
            .overlay {
                if let border {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .clipShape(Capsule())
    }
}

// MARK: - Due badge

extension TaskItem {
    struct DueBadge {
        let label: String
        let fill: Color
        let foreground: Color
        let border: Color?
    }

    /// Cream text on solid badges — same as MedicineItem.expiryBadge.
    private static let badgeCream = Color(hex: 0xfff8ec)

    /// "Overdue · 12-11-26", "Due today · …" / "Due in N days · …" within
    /// three days, otherwise just the date — same colours as the medicine
    /// expiry badge.
    var dueBadge: DueBadge? {
        guard let due, let date = parseExpiryDate(due) else { return nil }
        // parseExpiryDate reads the date at UTC midnight; compare calendar
        // days in UTC too so the count never drifts by one.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = calendar.date(from: todayComponents) ?? date
        let diff = calendar.dateComponents([.day], from: today, to: date).day ?? 0
        let shown = shortDateString(date, utc: true)
        if diff < 0 {
            return DueBadge(label: "\(L("Overdue")) · \(shown)", fill: Theme.accent800, foreground: Self.badgeCream, border: nil)
        }
        if diff <= 3 {
            let label = diff == 0 ? L("Due today") : L("Due in \(diff) days")
            return DueBadge(label: "\(label) · \(shown)", fill: Theme.accent500, foreground: Self.badgeCream, border: nil)
        }
        return DueBadge(label: shown, fill: .clear, foreground: Theme.neutral600, border: Theme.divider)
    }
}

// MARK: - Add / edit sheet

struct TaskItemSheet: View {
    @Environment(\.dismiss) private var dismiss

    let task: TaskItem?
    var onSave: (TaskItem) -> Void

    /// Chip options — the store's lists, plus any typed with "New list".
    @State private var lists: [String]
    @State private var title: String
    @State private var list: String
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var notes: String
    @State private var newList = ""

    init(task: TaskItem?, lists: [String], onSave: @escaping (TaskItem) -> Void) {
        self.task = task
        self.onSave = onSave
        let names = lists.isEmpty ? defaultTaskLists : lists
        // Keep the task's own list selectable even if the list was removed
        // elsewhere.
        if let current = task?.list, !names.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            _lists = State(initialValue: names + [current])
        } else {
            _lists = State(initialValue: names)
        }
        _title = State(initialValue: task?.title ?? "")
        // New tasks start in Other.
        _list = State(initialValue: task?.list ?? "Other")
        if let due = task?.due, let date = parseExpiryDate(due) {
            _hasDue = State(initialValue: true)
            _dueDate = State(initialValue: date)
        } else {
            _hasDue = State(initialValue: false)
            _dueDate = State(initialValue: Calendar.current.startOfDay(for: Date()))
        }
        _notes = State(initialValue: task?.notes ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.neutral300)
                .frame(width: 44, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(task == nil ? L("Add task") : L("Edit task"))
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.ink)

                    TextField("e.g. Renew passport", text: $title)
                        .font(Theme.body(14.5))
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Theme.surface)
                        .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                        .clipShape(Capsule())

                    field(kicker: L("List")) {
                        VStack(alignment: .leading, spacing: 10) {
                            FlowLayout(spacing: 7) {
                                ForEach(lists, id: \.self) { option in
                                    compactChip(option, selected: list.caseInsensitiveCompare(option) == .orderedSame) {
                                        list = option
                                    }
                                }
                            }
                            HStack(spacing: 9) {
                                TextField(L("New list"), text: $newList)
                                    .font(Theme.body(14))
                                    .textInputAutocapitalization(.words)
                                    .padding(.horizontal, 16)
                                    .frame(height: 42)
                                    .background(Theme.surface)
                                    .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                                    .clipShape(Capsule())
                                    .onSubmit(useNewList)
                                Button(action: useNewList) {
                                    LucideIcon(.plus, size: 16)
                                        .foregroundStyle(Theme.bg)
                                        .frame(width: 42, height: 42)
                                        .background(normalizeTaskListName(newList) != nil ? Theme.accent : Theme.neutral400)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(normalizeTaskListName(newList) == nil)
                                .accessibilityLabel(L("Add list"))
                            }
                        }
                    }

                    field(kicker: L("Due date (optional)")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $hasDue) {
                                Text(hasDue ? L("Date set") : L("No due date"))
                                    .font(Theme.body(13))
                                    .foregroundStyle(Theme.neutral700)
                            }
                            .tint(Theme.accent)

                            if hasDue {
                                DatePicker(
                                    "Due",
                                    selection: $dueDate,
                                    displayedComponents: .date
                                )
                                .datePickerStyle(.compact)
                                .labelsHidden()
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 46)
                                .background(Theme.surface)
                                .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                                .clipShape(Capsule())
                            }
                        }
                    }

                    field(kicker: L("Notes")) {
                        TextField("Optional", text: $notes, axis: .vertical)
                            .font(Theme.body(14))
                            .lineLimit(3...10)
                            .padding(12)
                            .frame(minHeight: 70, alignment: .topLeading)
                            .background(Theme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Theme.divider, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }

                    Button(action: save) {
                        Text(L("Save"))
                            .font(Theme.display(15))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(AccentFillButtonStyle(
                        fill: canSave ? Theme.accent : Theme.neutral400,
                        pressedFill: canSave ? Theme.accent600 : Theme.neutral400
                    ))
                    .disabled(!canSave)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 22)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    /// Picks the typed list name. The store adds it to the saved lists when
    /// the task is saved (TaskStore.upsert).
    private func useNewList() {
        guard let name = normalizeTaskListName(newList) else { return }
        if let existing = lists.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            list = existing
        } else {
            lists.insert(name, at: max(lists.count - 1, 0))
            list = name
        }
        newList = ""
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var saved = task ?? TaskItem(title: trimmed)
        saved.title = trimmed
        saved.list = normalizeTaskListName(list) ?? "Other"
        saved.due = hasDue ? formatExpiryDate(dueDate) : nil
        saved.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(saved)
        dismiss()
    }

    private func field<Content: View>(kicker: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(kicker.uppercased(with: Locale(identifier: "en")))
                .font(Theme.body(10.5, weight: .semibold))
                .tracking(1.26)
                .foregroundStyle(Theme.neutral600)
            content()
        }
    }

    private func compactChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.body(12.5, weight: .semibold))
                .foregroundStyle(selected ? .white : Theme.neutral800)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.surface)
                .overlay {
                    if !selected {
                        Capsule().strokeBorder(Theme.divider, lineWidth: 1)
                    }
                }
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Lists management

/// Add, rename, and delete task lists — opened from the Tasks gear. Same
/// layout as MedicineCategoriesSheet.
struct TaskListsSheet: View {
    @Environment(TaskStore.self) private var tasks
    @Environment(\.dismiss) private var dismiss

    @State private var newList = ""
    @State private var listToDelete: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.neutral300)
                .frame(width: 44, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Lists")
                        .font(Theme.display(22))
                        .foregroundStyle(Theme.ink)

                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(tasks.lists, id: \.self) { name in
                            CategoryRenameRow(
                                name: name,
                                locked: isLockedTaskList(name),
                                onRename: { tasks.renameList(name, to: $0) },
                                onDelete: { listToDelete = name }
                            )
                        }
                    }

                    Text("Deleting a list moves its tasks to \"Other\".")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.neutral600)

                    HStack(spacing: 9) {
                        TextField(L("New list"), text: $newList)
                            .font(Theme.body(14.5))
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 18)
                            .frame(height: 48)
                            .background(Theme.surface)
                            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
                            .clipShape(Capsule())
                            .onSubmit(addListFromField)

                        Button(action: addListFromField) {
                            LucideIcon(.plus, size: 18)
                                .foregroundStyle(Theme.bg)
                                .frame(width: 48, height: 48)
                                .background(canAddList ? Theme.accent : Theme.neutral400)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAddList)
                        .accessibilityLabel(L("Add list"))
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(Theme.display(15))
                            .foregroundStyle(Theme.bg)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel(L("Done"))
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 36)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .alert(
            L("Delete \(listToDelete ?? "")?"),
            isPresented: Binding(
                get: { listToDelete != nil },
                set: { shown in if !shown { listToDelete = nil } }
            )
        ) {
            Button(L("Cancel"), role: .cancel) { listToDelete = nil }
            Button(L("Delete"), role: .destructive) {
                if let name = listToDelete {
                    tasks.deleteList(name)
                }
                listToDelete = nil
            }
        } message: {
            Text(L("Tasks in this list will move to Other."))
        }
    }

    private var canAddList: Bool {
        normalizeTaskListName(newList) != nil && tasks.lists.count < maxTaskLists
    }

    private func addListFromField() {
        tasks.addList(newList)
        newList = ""
    }
}
