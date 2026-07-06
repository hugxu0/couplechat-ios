import SwiftUI

// 大橘页：宠物状态 + 互动按钮。
// 3D 猫（网页版用 Three.js）以后可以用 SceneKit/RealityKit 加载同一个
// cute_cat.glb 模型；这一版先用 emoji 占位，把布局和交互立起来。

struct PetView: View {
    @State private var bubble = "喵~ 你来啦"
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
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .navigationTitle("大橘")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("Lv.4")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(DS.Palette.accent)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var petCard: some View {
        VStack(spacing: 12) {
            Text(bubble)
                .font(.system(size: 16, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
                .shadow(color: DS.Surface.shadow, radius: 6, y: 3)

            Text("🐱")
                .font(.system(size: 110))
                .padding(.vertical, 8)
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
                .background(Color.white.opacity(0.7))
                .clipShape(Capsule())

                Label("亲密 239", systemImage: "heart.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DS.Palette.pink)
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 1, green: 0.97, blue: 0.86), Color(red: 1, green: 0.93, blue: 0.90)],
                           startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
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
                            Capsule().fill(Color.black.opacity(0.06))
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
            .background(Color.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}
