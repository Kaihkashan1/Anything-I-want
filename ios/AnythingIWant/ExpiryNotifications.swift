import Foundation
import Observation
import UserNotifications

/// Which cupboard list an expiry reminder points at.
enum ExpiryKind: String, Equatable {
    case grocery
    case medicine
}

/// A tapped expiry reminder. `token` is new every tap so opening the same
/// item again still scrolls to it.
struct ExpiryFocus: Equatable {
    var id: String
    var kind: ExpiryKind?
    var token: UUID
}

/// Set when the user taps an expiry reminder. RootView switches to Cupboard
/// and PantryView scrolls that row into view.
@MainActor
@Observable
final class ExpiryNotificationRouter {
    static let shared = ExpiryNotificationRouter()
    var pending: ExpiryFocus?

    private init() {}

    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ExpiryNotificationDelegate.shared
    }
}

private final class ExpiryNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ExpiryNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let focus = ExpiryNotifications.focus(from: response)
        if let focus {
            Task { @MainActor in
                ExpiryNotificationRouter.shared.pending = focus
            }
        }
        completionHandler()
    }
}

/// Local reminders for cupboard groceries and medicines that expire soon.
/// Fires at 9:00 on the morning 7 days before, 3 days before, and on the
/// expiry date — matching the badges already shown on those rows.
/// Tapping one opens that product in the Cupboard list.
enum ExpiryNotifications {
    static let enabledKey = "anythingIWant.expiryNotificationsEnabled"
    private static let idPrefix = "expiry."
    private static let itemIDKey = "expiryItemID"
    private static let kindKey = "expiryKind"
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
            appendCandidates(name: item.name, expiry: item.expiry, id: item.id, kind: .grocery, into: &candidates)
        }
        for item in medicines {
            appendCandidates(name: item.name, expiry: item.expiry, id: item.id, kind: .medicine, into: &candidates)
        }
        return candidates
            .sorted { $0.0 < $1.0 }
            .prefix(pendingCap)
            .map(\.1)
    }

    /// The item a notification tap should open. Reminders scheduled before
    /// this payload existed still work: their identifier is `expiry.<id>.<lead>`.
    static func focus(from response: UNNotificationResponse) -> ExpiryFocus? {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return nil }
        let request = response.notification.request
        let info = request.content.userInfo
        let kind = (info[kindKey] as? String).flatMap(ExpiryKind.init(rawValue:))
        let id = (info[itemIDKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? idFromIdentifier(request.identifier)
        guard let id else { return nil }
        return ExpiryFocus(id: id, kind: kind, token: UUID())
    }

    private static func idFromIdentifier(_ identifier: String) -> String? {
        guard identifier.hasPrefix(idPrefix) else { return nil }
        let rest = identifier.dropFirst(idPrefix.count)
        guard let dot = rest.lastIndex(of: "."), dot > rest.startIndex else { return nil }
        return String(rest[..<dot])
    }

    private static func appendCandidates(
        name: String,
        expiry: String?,
        id: String,
        kind: ExpiryKind,
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
            content.userInfo = [
                itemIDKey: id,
                kindKey: kind.rawValue,
            ]

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
