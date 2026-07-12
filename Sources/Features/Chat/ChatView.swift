import SwiftUI

struct ChatView: View {
    let channel: ChatChannel

    init(channel: ChatChannel = .couple) {
        self.channel = channel
    }

    var body: some View {
        ChatSessionScreen(channel: channel)
    }
}
