import Foundation

enum AppDeepLink: Equatable {
    case coupleChat
    case dajuChat
    case reminders

    static func parse(_ url: URL) -> AppDeepLink? {
        guard url.scheme?.lowercased() == "couplechat" else { return nil }
        let section = url.host?.lowercased()
        let destination = url.pathComponents
            .filter { $0 != "/" }
            .first?
            .lowercased()
        switch (section, destination) {
        case ("chat", "couple"): return .coupleChat
        case ("chat", "ai"): return .dajuChat
        case ("plans", "reminders"): return .reminders
        default: return nil
        }
    }
}

@MainActor
final class AppDeepLinkRouter: ObservableObject {
    static let shared = AppDeepLinkRouter()

    @Published private(set) var destination: AppDeepLink?

    private init() {}

    func handle(_ url: URL) {
        destination = AppDeepLink.parse(url)
    }

    func consume() {
        destination = nil
    }
}

extension Notification.Name {
    static let openCoupleChatDeepLink = Notification.Name("openCoupleChatDeepLink")
    static let openDajuChatDeepLink = Notification.Name("openDajuChatDeepLink")
    static let openRemindersDeepLink = Notification.Name("openRemindersDeepLink")
}
