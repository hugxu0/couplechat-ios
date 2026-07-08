import SwiftUI

// 大橘页：宠物状态 + 互动按钮。
// 3D 猫（网页版用 Three.js）以后可以用 SceneKit/RealityKit 加载同一个
// cute_cat.glb 模型；这一版先用 emoji 占位，把布局和交互立起来。

struct PetView: View {
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @State private var bubble = "喵~ 你来啦"
    @State private var showAIChat = false
    @State private var stats: [(icon: String, name: String, value: Double)] = [
        ("🍖", "饱食", 0.91), ("🛁", "清洁", 0.75), ("😻", "心情", 0.95), ("⚡", "精力", 1.0),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    petCard
                    statsCard
                    actionsRow
                    chatEntry
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showAIChat) { ChatView(channel: .ai) }
        }
    }

    private var petCard: some View {
        VStack(spacing: 12) {
            Text(bubble)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(DS.Palette.bubbleOther)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 6, y: 3)

            Text("🐱")
                .font(.system(size: 110))
                .padding(.vertical, 8)
                .background(
                    // 猫身后的柔光，跟随主题色，深浅模式都协调
                    Circle().fill(DS.Palette.accent.opacity(0.16)).frame(width: 150, height: 150).blur(radius: 24))
                .onTapGesture {
                    Haptics.medium()
                    withAnimation(DS.Anim.spring) { bubble = "喵喵喵~ 💗" }
                }

            Text("大橘现在超开心，元气满满！")
                .font(.system(size: 14))
                .foregroundStyle(DS.Palette.textSecondary)

            HStack {
                // 经验条
                HStack(spacing: 0) {
                    Text("Lv.4 · 经验 36%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DS.Palette.accent)
                        .clipShape(Capsule())
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(DS.Palette.innerSurface)
                .clipShape(Capsule())

                Label("亲密 239", systemImage: "heart.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Palette.pink)
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity)
        .dsCard()
    }

    private var statsCard: some View {
        VStack(spacing: 14) {
            ForEach(stats, id: \.name) { s in
                HStack(spacing: 10) {
                    Text(s.icon).font(.system(size: 20))
                    Text(s.name).font(.system(size: 15))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.Palette.innerSurface)
                            Capsule().fill(DS.Palette.green)
                                .frame(width: geo.size.width * s.value)
                        }
                    }
                    .frame(height: 10)
                    Text("\(Int(s.value * 100))")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private var actionsRow: some View {
        HStack(spacing: 10) {
            petAction("🍗", "喂食")
            petAction("🛁", "洗澡")
            petAction("🧶", "玩耍")
            petAction("🐾", "摸摸")
            petAction("💤", "睡觉")
        }
    }

    private func petAction(_ emoji: String, _ title: String) -> some View {
        Button {
            Haptics.medium()
        } label: {
            VStack(spacing: 5) {
                Text(emoji).font(.system(size: 26))
                Text(title).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text("可用").font(.system(size: 11))
                    .foregroundStyle(DS.Palette.accent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(DS.Palette.innerSurface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: 和大橘聊天入口（从聊天首页移来）
    private var chatEntry: some View {
        Button {
            Haptics.light()
            showAIChat = true
        } label: {
            HStack(spacing: 14) {
                Text("🐱")
                    .font(.system(size: 30))
                    .frame(width: 54, height: 54)
                    .background(theme.accent.color.opacity(0.12))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("和大橘聊聊")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(DS.Palette.textPrimary)
                        if store.aiTyping {
                            Text("正在输入")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DS.Palette.green)
                        }
                    }
                    Text(aiPreview)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
            }
            .padding(DS.Spacing.card)
            .frame(maxWidth: .infinity)
            .dsCard()
        }
        .buttonStyle(PressableStyle())
    }

    private var aiPreview: String {
        guard let last = store.messages(for: .ai).last else { return "找大橘说点悄悄话" }
        return last.type == "text" ? last.text : "[\(last.type)]"
    }
}
