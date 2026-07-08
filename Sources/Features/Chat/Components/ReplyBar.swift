import SwiftUI

/// 回复栏组件
struct ReplyBar: View {
    let message: ChatMessage?
    let onClose: () -> Void
    
    var body: some View {
        if let message = message {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(DS.Palette.accent)
                    .frame(width: 3)
                    .cornerRadius(1.5)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                    
                    Text(previewText(for: message))
                        .font(.system(size: 14))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(DS.Palette.textSecondary.opacity(0.1), in: Circle())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
    
    private func previewText(for message: ChatMessage) -> String {
        switch message.type {
        case "sticker": return "[表情]"
        case "image": return "[图片]"
        case "video": return "[视频]"
        case "file": return "[文件]"
        case "voice": return "[语音]"
        default: return message.displayText
        }
    }
}

/// AI 打字提示组件
struct AiTypingHint: View {
    let isTyping: Bool
    let isReplying: Bool
    
    var body: some View {
        if isTyping || isReplying {
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(DS.Palette.textSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(dotOpacity(index))
                        .animation(dotAnimation(index), value: isTyping || isReplying)
                }
                
                Text(isReplying ? "思考中" : "正在输入")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
    
    private func dotOpacity(_ index: Int) -> Double {
        guard isTyping || isReplying else { return 0.55 }
        let phase = (Date().timeIntervalSinceReferenceDate * 3.4) + Double(index) * 0.35
        let value = (sin(phase) + 1) / 2
        return 0.35 + value * 0.65
    }
    
    private func dotAnimation(_ index: Int) -> Animation {
        .easeInOut(duration: 0.6 + Double(index) * 0.08).repeatForever(autoreverses: true)
    }
}
