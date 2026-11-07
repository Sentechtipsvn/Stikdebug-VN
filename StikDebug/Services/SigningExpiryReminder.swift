import Combine
import Foundation
import UserNotifications

@MainActor
final class SigningExpiryReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SigningExpiryReminder()

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: "vn.signingReminder.enabled")
    @Published private(set) var expiry: Date?
    @Published private(set) var status = ""
    @Published private(set) var permissionDenied = false

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var refreshTask: Task<Void, Never>?
    private var needsRefresh = false

    private override init() {
        super.init()
        center.delegate = self
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "vn.signingReminder.enabled")
        if enabled {
            Task {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                refresh()
            }
        } else {
            refresh()
        }
    }

    func refresh() {
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while needsRefresh {
                needsRefresh = false
                await synchronize()
            }
            refreshTask = nil
        }
    }

    private func synchronize() async {
        expiry = Self.readExpiry()
        let settings = await center.notificationSettings()
        permissionDenied = settings.authorizationStatus == .denied
        let pending = await center.pendingNotificationRequests().filter { Self.isReminder($0.identifier) }
        let now = Date()
        guard isEnabled, let expiry, expiry > now,
              [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            await removeOldDelivered(keeping: nil)
            if !isEnabled { status = "Đã tắt nhắc hạn ký." }
            else if permissionDenied { status = "Hãy cho phép thông báo trong Cài đặt iPhone." }
            else if expiry == nil { status = "Chưa đọc được hạn từ hồ sơ ký của bản cài này." }
            else if expiry.map({ $0 <= now }) == true { status = "Hồ sơ ký đã hết hạn." }
            else { status = "Đang chờ quyền thông báo." }
            return
        }

        let expiryKey = "vn.signingReminder.expiry"
        let startKey = "vn.signingReminder.enabledAt"
        let enabledAt: Date
        if defaults.object(forKey: expiryKey) as? Date == expiry,
           let saved = defaults.object(forKey: startKey) as? Date {
            enabledAt = saved
        } else {
            enabledAt = now
            defaults.set(expiry, forKey: expiryKey)
            defaults.set(enabledAt, forKey: startKey)
        }

        let prefix = SigningExpirySchedule.identifierPrefix + "\(expiry.timeIntervalSince1970)."
        let dates = SigningExpirySchedule.dates(expiry: expiry, enabledAt: enabledAt, now: now)
        let desired = dates.map { (id: prefix + "\($0.timeIntervalSince1970)", date: $0) }
        let ids = Set(desired.map { $0.id })
        let existing = Set(pending.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: Array(existing.subtracting(ids)))
        await removeOldDelivered(keeping: prefix)

        var failed = false
        for item in desired where !existing.contains(item.id) {
            guard isEnabled else { break }
            let delay = item.date.timeIntervalSinceNow
            guard delay > 0 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "StikDebug VN sắp hết hạn ký"
            content.body = "Hết hạn lúc \(expiry.formatted(date: .abbreviated, time: .shortened)). Hãy gia hạn rồi mở lại VN để cập nhật lịch nhắc."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: item.id, content: content, trigger: trigger))
            } catch { failed = true }
        }

        if failed { status = "Chưa đặt được đầy đủ lịch nhắc. Hãy mở lại VN để thử lại." }
        else if let next = dates.first { status = "Nhắc tiếp lúc \(next.formatted(date: .abbreviated, time: .shortened))." }
        else { status = "Đã qua các mốc nhắc của kỳ này." }
    }

    private func removeOldDelivered(keeping prefix: String?) async {
        let delivered = await center.deliveredNotifications()
        let outdated = delivered.map { $0.request.identifier }.filter { identifier in
            Self.isReminder(identifier) && !(prefix.map { identifier.hasPrefix($0) } ?? false)
        }
        center.removeDeliveredNotifications(withIdentifiers: outdated)
    }

    private static func readExpiry() -> Date? {
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url),
              let plist = try? CMSDecoderHelper.decodeCMSData(data),
              let fields = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any] else { return nil }
        return fields["ExpirationDate"] as? Date
    }

    private nonisolated static func isReminder(_ identifier: String) -> Bool {
        identifier.hasPrefix(SigningExpirySchedule.identifierPrefix)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        Self.isReminder(notification.request.identifier) ? [.banner, .list, .sound] : []
    }
}
