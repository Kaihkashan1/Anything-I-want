import Network
import Observation
import SwiftUI

/// Live reachability for the hosted API. Used to keep the last-synced
/// cookbook/cupboard on screen when the phone is offline, and to kick a
/// refresh the moment connectivity comes back.
@Observable
@MainActor
final class Connectivity {
    /// True until the first path update arrives, so a banner doesn't flash
    /// on launch before NWPathMonitor has spoken.
    private(set) var isOnline = true
    private(set) var hasPath = false

    var isOffline: Bool { hasPath && !isOnline }

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "anything-i-want.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.hasPath = true
            }
        }
        monitor.start(queue: queue)
    }
}

/// Compact strip shown while the last-synced cache is standing in for the
/// server. Sage, not error-red — this is expected, not a crash.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
            Text("Offline — showing recipes saved on this phone")
                .font(Theme.body(12.5, weight: .semibold))
        }
        .foregroundStyle(Theme.sage800)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.screenPadding)
        .background(Theme.sage100)
    }
}

/// Shown only after an automatic refresh (launch/foreground/reconnect) has
/// already failed twice in a row over an existing cache — see
/// RecipeStore/PantryStore.loadRemote. Terracotta, not sage: unlike being
/// offline, this is a real failure worth a manual nudge, not a normal state.
struct RefreshFailedBanner: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(Theme.body(12.5, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Retry", action: onRetry)
                .font(Theme.body(12.5, weight: .bold))
                .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.accent700)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.screenPadding)
        .background(Theme.accent100)
    }
}

/// When this copy of the app was signed, and when that signature stops
/// launching it. A free Apple developer install lasts 7 days; reading the
/// embedded profile is the real deadline, and it resets on every reinstall.
/// Year-long and App Store builds have no short profile, so `current` is nil
/// and the banner stays hidden.
struct AppInstall: Equatable {
    var installedAt: Date
    var expiresAt: Date

    /// Whole calendar days until the profile stops launching the app.
    /// Zero means it still runs today; negative means it has already lapsed.
    var daysLeft: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let expiry = calendar.startOfDay(for: expiresAt)
        return calendar.dateComponents([.day], from: today, to: expiry).day ?? 0
    }

    var bannerText: String {
        let date = shortDateString(installedAt)
        switch daysLeft {
        case 1:
            return L("Installed \(date) · 1 day left")
        case 2...:
            return L("Installed \(date) · \(daysLeft) days left")
        case 0:
            return L("Installed \(date) · reinstall today")
        default:
            return L("Installed \(date) · expired — reinstall")
        }
    }

    static var current: AppInstall? {
        guard let profile = provisioningDates() else { return nil }
        let lifetime = profile.expires.timeIntervalSince(profile.created)
        guard lifetime > 0, lifetime <= 14 * 24 * 60 * 60 else { return nil }
        return AppInstall(installedAt: profile.created, expiresAt: profile.expires)
    }

    private static func provisioningDates() -> (created: Date, expires: Date)? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8))
        else { return nil }
        let plistData = data[start.lowerBound..<end.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let created = plist["CreationDate"] as? Date,
              let expires = plist["ExpirationDate"] as? Date
        else { return nil }
        return (created, expires)
    }
}

struct InstallBanner: View {
    let install: AppInstall

    var body: some View {
        let urgent = install.daysLeft <= 2
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 12, weight: .semibold))
            Text(install.bannerText)
                .font(Theme.body(12.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(urgent ? Theme.accent800 : Theme.neutral700)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, Theme.screenPadding)
        .background(urgent ? Theme.accent100 : Theme.neutral100)
    }
}
