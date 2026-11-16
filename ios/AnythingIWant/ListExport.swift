import SwiftUI

/// Plain-text export of a list — the share button on Cupboard, Shop, Pack
/// and Tasks. Produces the same text as the web app's export (see
/// app/static/app.js, "Export a list as plain text"); keep the two in step.
/// Every function returns nil when there's nothing to export.
enum ListExport {
    // MARK: - Shared formatting

    static func line(_ bullet: String, _ name: String, _ details: [String]) -> String {
        let extra = details
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return extra.isEmpty ? "\(bullet) \(name)" : "\(bullet) \(name) — \(extra)"
    }

    static func groups(_ groups: [(heading: String, lines: [String])]) -> String {
        groups
            .filter { !$0.lines.isEmpty }
            .map { group in
                group.heading.isEmpty
                    ? group.lines.joined(separator: "\n")
                    : group.heading.uppercased(with: Locale(identifier: "en")) + "\n" + group.lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

    static func header(_ title: String) -> String {
        "\(title)\n\(shortDateString(Date()))"
    }

    /// The category order to group by: the store's own order, then any
    /// category an item uses that the list doesn't know, case-insensitively
    /// deduped.
    static func order(_ known: [String], extra: [String]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for raw in known + extra {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            names.append(name)
        }
        return names
    }

    static func amountText(_ amount: Double, unit: String) -> String {
        let shown = amount.rounded() == amount
            ? String(Int(amount.rounded()))
            : String(format: "%g", amount)
        return "\(shown) \(unit)".trimmingCharacters(in: .whitespaces)
    }

    static func expiryText(_ expiry: String?) -> String {
        guard let expiry, !expiry.isEmpty else { return "" }
        if let date = parseExpiryDate(expiry) {
            return "expires \(shortDateString(date, utc: true))"
        }
        return "expires \(expiry)"
    }

    private static func byName<T>(_ items: [T], _ name: (T) -> String) -> [T] {
        items.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// Items grouped under their FIRST category only — the app shows a
    /// multi-category item under each, but a shared list shouldn't repeat it.
    private static func inventoryGroups<T>(
        _ items: [T],
        categories: [String],
        firstCategory: (T) -> String,
        line makeLine: (T) -> String
    ) -> [(heading: String, lines: [String])] {
        let names = order(categories, extra: items.map(firstCategory))
        return names.map { name in
            let rows = items.filter { firstCategory($0).caseInsensitiveCompare(name) == .orderedSame }
            return (heading: name, lines: rows.map(makeLine))
        }
    }

    // MARK: - Cupboard

    static func groceries(_ items: [PantryItem], categories: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        let sorted = byName(items) { $0.name }
        let body = groups(inventoryGroups(
            sorted,
            categories: categories,
            firstCategory: { $0.categories.first ?? "Other" },
            line: { item in
                line("•", item.name, [
                    "\(amountText(item.amount, unit: item.unit.rawValue)), \(item.status.label.lowercased())",
                    expiryText(item.expiry),
                    item.notes,
                ])
            }
        ))
        return "\(header("Cupboard · Groceries"))\n\n\(body)"
    }

    static func medicines(_ items: [MedicineItem], categories: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        let sorted = byName(items) { $0.name }
        let body = groups(inventoryGroups(
            sorted,
            categories: categories,
            firstCategory: { $0.categories.first ?? "Other" },
            line: { item in
                line("•", item.name, [
                    "\(amountText(item.amount, unit: item.unit.rawValue)), \(item.status.label.lowercased())",
                    expiryText(item.expiry),
                    item.purpose,
                    item.notes,
                ])
            }
        ))
        return "\(header("Medicines"))\n\n\(body)"
    }

    // MARK: - Shop / Pack

    /// `listKey` is shop, shop_medicines, take_to_india or bring_to_germany.
    /// Only what's still to get — ticked items are left out.
    static func checklist(_ items: [ToBuyItem], listKey: String, categories: [String]) -> String? {
        let open = items.filter { !$0.checked }
        guard !open.isEmpty else { return nil }
        let pack = listKey == "take_to_india" || listKey == "bring_to_germany"
        let title: String
        switch listKey {
        case "shop_medicines": title = "Shop · Medicines"
        case "take_to_india": title = "Take to India"
        case "bring_to_germany": title = "Bring to Germany"
        default: title = "Shop · Groceries"
        }
        let makeLine: (ToBuyItem) -> String = { item in
            line("☐", item.text, [pack ? "" : item.qty, item.notes])
        }
        let sorted = byName(open) { $0.text }
        let body: String
        if pack {
            body = sorted.map(makeLine).joined(separator: "\n")
        } else {
            let names = order(categories, extra: open.map(\.category))
            body = groups(names.map { name in
                let rows = sorted.filter { $0.category.caseInsensitiveCompare(name) == .orderedSame }
                return (heading: name, lines: rows.map(makeLine))
            })
        }
        return "\(header(title))\n\n\(body)"
    }

    // MARK: - Tasks

    /// Calendar days from today to `due` (negative when overdue), compared
    /// in UTC like TaskItem.dueBadge so the count never drifts by one.
    private static func daysUntil(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let todayComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = calendar.date(from: todayComponents) ?? date
        return calendar.dateComponents([.day], from: today, to: date).day ?? 0
    }

    /// Open tasks, grouped by list, overdue and soonest-due first, then
    /// undated ones in the order they were added.
    static func tasks(_ items: [TaskItem], lists: [String]) -> String? {
        var indexed: [(task: TaskItem, index: Int)] = []
        for (index, task) in items.enumerated() where !task.done {
            indexed.append((task: task, index: index))
        }
        guard !indexed.isEmpty else { return nil }
        let sorted = indexed.sorted { lhs, rhs in
            let leftDue = lhs.task.due ?? ""
            let rightDue = rhs.task.due ?? ""
            if leftDue.isEmpty != rightDue.isEmpty { return !leftDue.isEmpty }
            if leftDue != rightDue { return leftDue < rightDue }
            return lhs.index < rhs.index
        }
        let names = order(lists, extra: sorted.map { $0.task.list })
        let body = groups(names.map { name in
            let rows = sorted.filter { $0.task.list.caseInsensitiveCompare(name) == .orderedSame }
            let lines = rows.map { row -> String in
                let task = row.task
                var due = ""
                if let raw = task.due, !raw.isEmpty {
                    if let date = parseExpiryDate(raw) {
                        let shown = shortDateString(date, utc: true)
                        due = daysUntil(date) < 0 ? "Overdue \(shown)" : "due \(shown)"
                    } else {
                        due = "due \(raw)"
                    }
                }
                return line("☐", task.title, [due, task.notes])
            }
            return (heading: name, lines: lines)
        })
        return "\(header("Tasks"))\n\n\(body)"
    }
}

/// Header button that opens the share sheet with a list's text — styled
/// like CircleIconButton. Dimmed and inert when there's nothing to share.
struct ShareListButton: View {
    let text: String?
    var size: CGFloat = 42

    private var glyph: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Theme.neutral800)
            .frame(width: size, height: size)
            .background(Theme.surface)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
    }

    var body: some View {
        if let text {
            ShareLink(item: text) {
                glyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Share list"))
        } else {
            glyph
                .opacity(0.4)
                .accessibilityLabel(L("Share list"))
                .accessibilityHint(L("Nothing to share in this list yet."))
        }
    }
}
