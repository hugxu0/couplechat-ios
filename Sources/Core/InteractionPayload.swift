import SwiftUI

enum InteractionEffectKind: String {
    case miss
    case pat
    case flower
    case poop
    case note
}

struct InteractionPayload: Identifiable, Equatable {
    let id: String
    let kind: InteractionEffectKind
    let text: String

    private static let prefix = "[[ccfx:"
    private static let suffix = "]]"

    static func encode(kind: InteractionEffectKind, text: String) -> String {
        "\(prefix)\(kind.rawValue)\(suffix)\(text)"
    }

    static func parse(id: String, text: String) -> InteractionPayload? {
        if text.hasPrefix(prefix),
           let closeRange = text.range(of: suffix) {
            let rawKind = String(text[text.index(text.startIndex, offsetBy: prefix.count)..<closeRange.lowerBound])
            guard let kind = InteractionEffectKind(rawValue: rawKind) else { return nil }
            let body = String(text[closeRange.upperBound...])
            return InteractionPayload(id: id, kind: kind, text: body)
        }
        guard let kind = cleanKind(for: text) else { return nil }
        return InteractionPayload(id: id, kind: kind, text: text)
    }

    static func displayText(_ text: String) -> String {
        guard text.hasPrefix(prefix),
              let closeRange = text.range(of: suffix) else { return text }
        return String(text[closeRange.upperBound...])
    }

    private static func cleanKind(for text: String) -> InteractionEffectKind? {
        if text == "💗 想你了" { return .miss }
        if text == "🖐️ 拍了拍你" { return .pat }
        if text == "🌸 送你一朵花花" { return .flower }
        if text == "💩 扔了个粑粑" { return .poop }
        if text.hasPrefix("🪧 ") { return .note }
        return nil
    }
}

extension ChatMessage {
    var displayText: String {
        InteractionPayload.displayText(text)
    }

    var interactionPayload: InteractionPayload? {
        if let interaction = meta?.interaction,
           let kind = InteractionEffectKind(rawValue: interaction.kind) {
            return InteractionPayload(id: interaction.id, kind: kind, text: interaction.text)
        }
        InteractionPayload.parse(id: id, text: text)
    }
}

struct InteractionPresentation: Identifiable, Equatable {
    var id: String { payload.id }
    let payload: InteractionPayload
    let senderName: String
    let duration: Double
}

struct IncomingInteractionOverlay: View {
    let payload: InteractionPayload
    let senderName: String
    let onDismiss: () -> Void
    var duration: Double = 2.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var torn = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch payload.kind {
                case .note:
                    noteLayer(in: proxy.size)
                default:
                    effectLayer(in: proxy.size)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.78)) {
                appeared = true
            }
            if payload.kind != .note {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    await MainActor.run {
                        withAnimation(.easeOut(duration: 0.24)) {
                            appeared = false
                        }
                    }
                    try? await Task.sleep(nanoseconds: 260_000_000)
                    await MainActor.run { onDismiss() }
                }
            }
        }
    }

    private func effectLayer(in size: CGSize) -> some View {
        ZStack {
            Color.clear

            ForEach(0..<(reduceMotion ? 7 : 26), id: \.self) { index in
                Text(effectEmoji)
                    .font(.system(size: CGFloat(20 + (index % 4) * 8)))
                    .opacity(appeared ? 0.88 : 0)
                    .scaleEffect(appeared ? 1 : 0.35)
                    .rotationEffect(.degrees(Double((index % 7) - 3) * 16))
                    .position(effectPosition(index, in: size))
                    .animation(.spring(response: 0.58, dampingFraction: 0.72).delay(Double(index) * 0.018), value: appeared)
            }

            VStack(spacing: 10) {
                Text(effectEmoji)
                    .font(.system(size: 76))
                    .scaleEffect(appeared ? 1 : 0.6)
                    .shadow(color: effectColor.opacity(0.24), radius: 22, y: 12)
                Text(effectTitle)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(senderName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
            }
            .scaleEffect(appeared ? 1 : 0.82)
            .opacity(appeared ? 1 : 0)
        }
        .background(effectColor.opacity(appeared ? 0.10 : 0))
    }

    private func noteLayer(in size: CGSize) -> some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.08))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("贴条")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                    Spacer()
                    Image(systemName: "pin.fill")
                        .foregroundStyle(Color(red: 0.92, green: 0.54, blue: 0.30))
                }

                Text(noteText)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(4)
                    .minimumScaleFactor(0.72)

                Text("向外一撕，才能继续看屏幕")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(DS.Palette.textSecondary)

                Button {
                    tearAway()
                } label: {
                    Text("撕掉")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(DS.Palette.pink, in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(18)
            .frame(width: min(270, size.width * 0.72))
            .background(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.93, blue: 0.48), Color(red: 1.0, green: 0.80, blue: 0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: 64, height: 8)
                    .padding(.top, 8)
            }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
            .rotationEffect(.degrees(torn ? 15 : noteRotation))
            .scaleEffect(appeared ? 1 : 0.72)
            .opacity(torn ? 0 : (appeared ? 1 : 0))
            .offset(noteOffset(in: size))
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        if abs(value.translation.width) + abs(value.translation.height) > 90 {
                            tearAway()
                        }
                    }
            )
        }
    }

    private var noteText: String {
        payload.text.replacingOccurrences(of: "🪧", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectEmoji: String {
        switch payload.kind {
        case .miss: return "💗"
        case .pat: return "🖐️"
        case .flower: return "🌸"
        case .poop: return "💩"
        case .note: return "🪧"
        }
    }

    private var effectTitle: String {
        switch payload.kind {
        case .miss: return "想你了"
        case .pat: return "拍了拍你"
        case .flower: return "送你一朵花花"
        case .poop: return "扔了个粑粑"
        case .note: return "贴了一张小纸条"
        }
    }

    private var effectColor: Color {
        switch payload.kind {
        case .miss: return DS.Palette.pink
        case .pat: return Color(red: 1.0, green: 0.66, blue: 0.24)
        case .flower: return Color(red: 1.0, green: 0.46, blue: 0.70)
        case .poop: return Color(red: 0.70, green: 0.45, blue: 0.22)
        case .note: return Color(red: 1.0, green: 0.78, blue: 0.26)
        }
    }

    private var noteRotation: Double {
        Double((stableSeed % 15) - 7)
    }

    private var stableSeed: Int {
        payload.id.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
    }

    private func effectPosition(_ index: Int, in size: CGSize) -> CGPoint {
        let xSeed = (stableSeed + index * 37) % 100
        let ySeed = (stableSeed + index * 61) % 100
        let x = size.width * (0.08 + CGFloat(xSeed) / 100 * 0.84)
        let y = size.height * (0.10 + CGFloat(ySeed) / 100 * 0.76)
        return CGPoint(x: x, y: y)
    }

    private func noteOffset(in size: CGSize) -> CGSize {
        let x = CGFloat((stableSeed % 55) - 27) / 100 * size.width
        let y = CGFloat(((stableSeed / 3) % 45) - 18) / 100 * size.height
        let tearY = torn ? -size.height : 0
        return CGSize(width: x, height: y + tearY)
    }

    private func tearAway() {
        Haptics.medium()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            torn = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 430_000_000)
            await MainActor.run { onDismiss() }
        }
    }
}
