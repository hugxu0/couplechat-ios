import SwiftUI

// 聊天首页：情侣卡（头像 + 状态）、状态标签、互动按钮、最新消息预览、进入聊天。
// 数据目前是假数据，后续接入后端后替换。

struct ChatHomeView: View {
    @EnvironmentObject private var store: ChatStore
    @State private var showChat = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    coupleCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90) // 给悬浮标签栏留位置
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showChat) { ChatView() }
        }
    }

    // MARK: 情侣主卡片
    private var coupleCard: some View {
        VStack(spacing: 20) {
            // 头像区
            HStack {
                avatarColumn(name: "小旭", mood: "要亲亲", moodColor: DS.Palette.pink, emoji: "🐶")
                Spacer()
                Text("💗")
                    .font(.system(size: 34))
                Spacer()
                avatarColumn(name: "小偲", mood: "在想你", moodColor: DS.Palette.textSecondary, emoji: "🐰")
            }
            .padding(.horizontal, 12)

            Divider().opacity(0.5)

            // 状态标签
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    statusChip("在想你", color: DS.Palette.pink)
                    statusChip("想贴贴", color: DS.Palette.pink)
                    statusChip("忙完找你", color: DS.Palette.blue)
                    statusChip("要亲亲", color: .orange)
                    statusChip("＋", color: DS.Palette.textSecondary)
                }
            }
            .scrollIndicators(.hidden)

            Divider().opacity(0.5)

            // 互动按钮
            HStack(spacing: 10) {
                quickAction("💗", "想你了", "心跳波纹")
                quickAction("✋", "拍一拍", "轻轻碰一下")
                quickAction("🌸", "送花花", "送你一朵")
                quickAction("💩", "扔粑粑", "坏笑一下")
                quickAction("🪧", "贴条", "贴张便利贴")
            }

            Divider().opacity(0.5)

            // 最新消息预览（真数据：最近三条）
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最新消息").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Palette.pink)
                    Spacer()
                    Text(store.messages.last?.timeString ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                ForEach(store.messages.suffix(3)) { m in
                    previewBubble(
                        m.type == "text" ? m.text : "[\(m.type == "image" ? "图片" : m.type == "video" ? "视频" : "表情")]",
                        mine: m.sender == store.session?.username)
                }
            }

            // 进入聊天
            Button {
                Haptics.light()
                showChat = true
            } label: {
                Text("进入聊天")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(DS.Palette.accentGradient)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            }
            .buttonStyle(PressableStyle())
        }
        .padding(DS.Spacing.card)
        .dsCard()
    }

    private func avatarColumn(name: String, mood: String, moodColor: Color, emoji: String) -> some View {
        VStack(spacing: 8) {
            Text(mood)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(moodColor)
            Text(emoji)
                .font(.system(size: 44))
                .frame(width: 92, height: 92)
                .background(Color.white.opacity(0.8))
                .clipShape(Circle())
            Text(name)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    private func statusChip(_ text: String, color: Color) -> some View {
        Button {
            Haptics.selection()
        } label: {
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.85))
                .clipShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func quickAction(_ emoji: String, _ title: String, _ subtitle: String) -> some View {
        Button {
            Haptics.medium()
        } label: {
            VStack(spacing: 4) {
                Text(emoji).font(.system(size: 26))
                Text(title).font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(subtitle).font(.system(size: 10))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private func previewBubble(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer() }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(mine ? .white : DS.Palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(mine ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.bubbleOther))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.bubble, style: .continuous))
            if !mine { Spacer() }
        }
    }
}
