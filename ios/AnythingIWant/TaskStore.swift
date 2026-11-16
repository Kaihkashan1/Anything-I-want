import Foundation
import Observation

// MARK: - Model

/// The Tasks tab's lists start as these (app/store.py's TASK_LISTS); the
/// user can add, rename and delete them. "Other" is always last and locked.
let defaultTaskLists = ["Home", "Errands", "Trip", "Other"]
let maxTaskLists = 32

func isLockedTaskList(_ name: String) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
        .caseInsensitiveCompare("Other") == .orderedSame
}

/// Same trimming/length rules as medicine categories (the server reuses
/// that normalizer for task lists too).
func normalizeTaskListName(_ raw: String) -> String? {
    normalizeMedicineCategoryName(raw)
}

/// Saved lists plus any list a task uses, de-duplicated case-insensitively,
/// "Other" last — mirrors app/store.py's merge_task_lists.
func mergeTaskLists(stored: [String], itemLists: [String]) -> [String] {
    var names: [String] = []
    var seen = Set<String>()
    let source = stored.isEmpty ? defaultTaskLists : stored
    for raw in source + itemLists {
        guard let name = normalizeTaskListName(raw) else { continue }
        let key = name.lowercased()
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        names.append(name)
        if names.count >= maxTaskLists { break }
    }
    let rest = names.filter { $0.caseInsensitiveCompare("Other") != .orderedSame }
    let clipped = rest.count >= maxTaskLists
        ? Array(rest.prefix(maxTaskLists - 1))
        : rest
    return clipped + ["Other"]
}

/// One row on the Tasks tab. `due` is a date-only "YYYY-MM-DD" string like
/// the inventory expiry dates; `createdAt`/`doneAt` are ISO timestamps the
/// server fills in when missing.
struct TaskItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var done: Bool
    var due: String?
    var list: String
    var notes: String
    var createdAt: String?
    var doneAt: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        done: Bool = false,
        due: String? = nil,
        list: String = "Other",
        notes: String = "",
        createdAt: String? = nil,
        doneAt: String? = nil
    ) {
        self.id = id
        self.title = title
        self.done = done
        self.due = due
        self.list = normalizeTaskListName(list) ?? "Other"
        self.notes = notes
        self.createdAt = createdAt
        self.doneAt = doneAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, done, due, list, notes
        case createdAt = "created_at"
        case doneAt = "done_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        done = try container.decodeIfPresent(Bool.self, forKey: .done) ?? false
        due = try container.decodeIfPresent(String.self, forKey: .due)
        let rawList = try container.decodeIfPresent(String.self, forKey: .list) ?? "Other"
        list = normalizeTaskListName(rawList) ?? "Other"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        doneAt = try container.decodeIfPresent(String.self, forKey: .doneAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(done, forKey: .done)
        try container.encodeIfPresent(due, forKey: .due)
        try container.encode(list, forKey: .list)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(doneAt, forKey: .doneAt)
    }

    func isIn(list name: String) -> Bool {
        list.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// GET/PUT /api/tasks body: `{"items": [...], "lists": [...]}`.
struct TasksResponse: Codable {
    let items: [TaskItem]
    var lists: [String]?

    init(items: [TaskItem], lists: [String]? = nil) {
        self.items = items
        self.lists = lists
    }
}

// MARK: - Store

/// The Tasks tab — same fetch/cache/optimistic-save shape as MedicineStore,
/// against /api/tasks. Lists can be added, renamed, or deleted like
/// medicine categories.
@Observable @MainActor
final class TaskStore {
    var items: [TaskItem] = []
    var lists: [String] = defaultTaskLists
    var isLoading = false
    var actionError: String?
    var lastRefreshError: String?

    private nonisolated static let encoder = JSONEncoder()
    private nonisolated static let decoder = JSONDecoder()
    private static let urlKey = "anythingIWant.serverURL"
    private static let secretKey = "anythingIWant.serverSecret"
    private static let cacheName = "tasksCache.json"
    @ObservationIgnored private var refreshTask: Task<Bool, Never>?
    @ObservationIgnored private var lastSuccessfulRefresh: Date?
    private static let staleInterval: TimeInterval = 90

    init() {
        loadCache()
    }

    var openCount: Int { items.filter { !$0.done }.count }
    var doneCount: Int { items.filter(\.done).count }

    private var serverURL: String {
        let stored = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        let value = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? RecipeStore.hostedURL : value
    }

    private var serverSecret: String {
        UserDefaults.standard.string(forKey: Self.secretKey) ?? ""
    }

    @discardableResult
    func refresh(force: Bool = true, auto: Bool = false) async -> Bool {
        if !force, let lastSuccessfulRefresh, Date().timeIntervalSince(lastSuccessfulRefresh) < Self.staleInterval {
            return true
        }
        if let refreshTask {
            return await refreshTask.value
        }
        let task = Task { await loadRemote(auto: auto) }
        refreshTask = task
        let result = await task.value
        if refreshTask == task {
            refreshTask = nil
        }
        return result
    }

    private func loadRemote(auto: Bool) async -> Bool {
        let hadCache = !items.isEmpty
        if !hadCache {
            isLoading = true
        }
        defer { isLoading = false }

        if await fetchOnce() {
            lastRefreshError = nil
            return true
        }
        guard auto, hadCache, !Task.isCancelled else { return false }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard !Task.isCancelled else { return false }
        if await fetchOnce() {
            lastRefreshError = nil
            return true
        }
        lastRefreshError = "Couldn't refresh — pull down to try again."
        return false
    }

    private func fetchOnce() async -> Bool {
        do {
            let payload = try await APIClient(baseURLString: serverURL).fetchTasks(secret: serverSecret)
            let nextLists = mergeTaskLists(stored: payload.lists ?? [], itemLists: payload.items.map(\.list))
            if items != payload.items { items = payload.items }
            if lists != nextLists { lists = nextLists }
            lastSuccessfulRefresh = Date()
            persistCache()
            return true
        } catch {
            return false
        }
    }

    // MARK: Tasks

    func upsert(_ task: TaskItem) {
        var next = items
        if let index = next.firstIndex(where: { $0.id == task.id }) {
            next[index] = task
        } else {
            next.append(task)
        }
        var nextLists = lists
        if !nextLists.contains(where: { $0.caseInsensitiveCompare(task.list) == .orderedSame }) {
            if let other = nextLists.firstIndex(where: { $0.caseInsensitiveCompare("Other") == .orderedSame }) {
                nextLists.insert(task.list, at: other)
            } else {
                nextLists.append(task.list)
            }
        }
        replaceAll(next, lists: nextLists)
    }

    func toggleDone(id: String) {
        let next = items.map { task -> TaskItem in
            guard task.id == id else { return task }
            var changed = task
            changed.done.toggle()
            // The server stamps done_at when it's missing; set it locally
            // too so the Done list sorts right before the round trip.
            changed.doneAt = changed.done ? ISO8601DateFormatter().string(from: Date()) : nil
            return changed
        }
        replaceAll(next, lists: lists)
    }

    func delete(id: String) {
        replaceAll(items.filter { $0.id != id }, lists: lists)
    }

    func clearDone() {
        replaceAll(items.filter { !$0.done }, lists: lists)
    }

    // MARK: Lists

    func addList(_ raw: String) {
        guard let name = normalizeTaskListName(raw) else { return }
        if lists.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return }
        guard lists.count < maxTaskLists else { return }
        var next = lists
        if let other = next.firstIndex(where: { $0.caseInsensitiveCompare("Other") == .orderedSame }) {
            next.insert(name, at: other)
        } else {
            next.append(name)
        }
        replaceAll(items, lists: next)
    }

    func renameList(_ from: String, to raw: String) {
        guard !isLockedTaskList(from) else { return }
        guard let name = normalizeTaskListName(raw) else { return }
        guard let index = lists.firstIndex(where: { $0.caseInsensitiveCompare(from) == .orderedSame }) else { return }
        if lists.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
                && $0.caseInsensitiveCompare(from) != .orderedSame
        }) {
            return
        }
        var next = lists
        next[index] = name
        let nextItems = items.map { task -> TaskItem in
            guard task.isIn(list: from) else { return task }
            var moved = task
            moved.list = name
            return moved
        }
        replaceAll(nextItems, lists: next)
    }

    /// Deleting a list moves its tasks to "Other".
    func deleteList(_ name: String) {
        guard !isLockedTaskList(name) else { return }
        let remaining = lists.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        guard remaining != lists else { return }
        let nextItems = items.map { task -> TaskItem in
            guard task.isIn(list: name) else { return task }
            var moved = task
            moved.list = "Other"
            return moved
        }
        replaceAll(nextItems, lists: remaining.isEmpty ? ["Other"] : remaining)
    }

    // MARK: Sync

    private func replaceAll(_ next: [TaskItem], lists nextLists: [String]) {
        let previousItems = items
        let previousLists = lists
        items = next
        lists = mergeTaskLists(stored: nextLists, itemLists: next.map(\.list))
        persistCache()
        let snapshotItems = items
        let snapshotLists = lists
        Task {
            do {
                let confirmed = try await APIClient(baseURLString: serverURL)
                    .updateTasks(items: snapshotItems, lists: snapshotLists, secret: serverSecret)
                if items == snapshotItems, lists == snapshotLists {
                    items = confirmed.items
                    if let remote = confirmed.lists, !remote.isEmpty {
                        lists = mergeTaskLists(stored: remote, itemLists: confirmed.items.map(\.list))
                    }
                    persistCache()
                }
            } catch {
                if items == snapshotItems, lists == snapshotLists {
                    items = previousItems
                    lists = previousLists
                    persistCache()
                }
                actionError = error.localizedDescription
            }
        }
    }

    private func cacheURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.cacheName)
    }

    private func loadCache() {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let payload = try? Self.decoder.decode(TaskCache.self, from: data),
              payload.serverURL == serverURL
        else { return }
        items = payload.items
        if let stored = payload.lists, !stored.isEmpty {
            lists = stored
        }
    }

    private func persistCache() {
        guard let url = cacheURL() else { return }
        let payload = TaskCache(serverURL: serverURL, items: items, lists: lists)
        Task.detached(priority: .utility) {
            guard let data = try? Self.encoder.encode(payload) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}

private struct TaskCache: Codable {
    let serverURL: String
    let items: [TaskItem]
    var lists: [String]?
}
