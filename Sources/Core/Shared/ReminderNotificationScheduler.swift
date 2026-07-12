import Foundation
import UserNotifications

enum ReminderNotificationScheduler {
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            if !granted {
                print("[Reminder] ⚠️ 用户拒绝了通知权限")
            }
        } catch {
            print("[Reminder] ⚠️ 请求通知权限失败: \(error.localizedDescription)")
        }
    }

    static func schedule(_ item: PersonalItem, account: String) async {
        guard item.kind == .reminder, item.owner == account, !item.isDone, let dueDate = item.dueDate else {
            await cancel(item, account: account)
            return
        }

        guard dueDate > Date() else {
            await cancel(item, account: account)
            return
        }

        await requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.bodyMarkdown.isEmpty ? "有一条提醒到时间了" : item.bodyMarkdown
        content.sound = .default
        content.userInfo = ["itemId": item.id, "owner": account]

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: identifier(for: item.id, account: account),
            content: content,
            trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[Reminder] ⚠️ 调度提醒失败 id=\(item.id) title=\(item.title): \(error.localizedDescription)")
        }
    }

    static func cancel(_ item: PersonalItem, account: String) async {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [identifier(for: item.id, account: account)])
    }

    static func rescheduleAll(_ items: [PersonalItem], account: String) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let prefix = "personal-reminder.\(account)."
        let ownedIdentifiers = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ownedIdentifiers)

        for item in items where item.kind == .reminder {
            await schedule(item, account: account)
        }
    }

    private static func identifier(for itemId: String, account: String) -> String {
        "personal-reminder.\(account).\(itemId)"
    }
}
