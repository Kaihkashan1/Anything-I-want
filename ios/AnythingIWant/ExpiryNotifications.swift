import Foundation
import UserNotifications

/// Local reminders for cupboard groceries and medicines that expire soon.
/// Fires at 9:00 on the morning 7 days before, 3 days before, and on the
/// expiry date — matching the badges already shown on those rows.
enum ExpiryNotifications {
    static let enabledKey = "recipeBox.expiryNotificationsEnabled"
    private static let idPrefix = "expiry."
    private static let leadDays = [7, 3, 0]
    private static let hour = 9
    private static let pendingCap = 64

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func refresh(pantry: [PantryItem], medicines: [MedicineItem]) {
        Task { await refreshAsync(pantry: pantry, medicines: medicines) }
    }

    static func refreshAsync(pantry: [PantryItem], medicines: [MedicineItem]) async {
        let center = UNUserNotificationCenter.current()
        await removePending(center: center)
        guard isEnabled else { return }

        let granted = await requestAuthorization(center: center)
        guard granted else { return }

        let requests = scheduledRequests(pantry: pantry, medicines: medicines)
        for request in requests {
            try? await center.add(request)
        }
    }

    private static func requestAuthorization(center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    private static func removePending(center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static func scheduledRequests(
        pantry: [PantryItem],
        medicines: [MedicineItem]
    ) -> [UNNotificationRequest] {
        var candidates: [(Date, UNNotificationRequest)] = []
        for item in pantry {
            appendCandidates(name: item.name, expiry: item.expiry, id: item.id, into: &candidates)
        }
        for item in medicines {
            appendCandidates(name: item.name, expiry: item.expiry, id: item.id, into: &candidates)
        }
        return candidates
            .sorted { $0.0 < $1.0 }
            .prefix(pendingCap)
            .map(\.1)
    }

    private static func appendCandidates(
        name: String,
        expiry: String?,
        id: String,
        into candidates: inout [(Date, UNNotificationRequest)]
    ) {
        guard let expiry, let day = parseExpiry(expiry) else { return }
        let calendar = Calendar.current
        let expiryDay = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: Date())
        guard expiryDay >= today else { return }

        for lead in leadDays {
            guard let fireDay = calendar.date(byAdding: .day, value: -lead, to: expiryDay) else { continue }
            var components = calendar.dateComponents([.year, .month, .day], from: fireDay)
            components.hour = hour
            components.minute = 0
            guard let fireDate = calendar.date(from: components), fireDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = lead == 0 ? L("Expires today") : L("Expiring soon")
            content.body = lead == 0
                ? L("\(name) expires today.")
                : L("\(name) expires in \(lead) days.")
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: "\(idPrefix)\(id).\(lead)",
                content: content,
                trigger: trigger
            )
            candidates.append((fireDate, request))
        }
    }

    private static func parseExpiry(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }
}
