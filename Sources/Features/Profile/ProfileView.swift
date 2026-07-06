import SwiftUI

// 我的页：头像信息 + 设置项列表。占位版。

struct ProfileView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    header
                    settingsCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .navigationTitle("我的")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Text("🐶")
                .font(.system(size: 48))
                .frame(width: 96, height: 96)
                .background(Color.white.opacity(0.9))
                .clipShape(Circle())
            Text("小旭")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(DS.Palette.textPrimary)
            Text("要亲亲")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Palette.pink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .dsCard()
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            row(icon: "person.crop.circle", title: "个人资料")
            divider
            row(icon: "paintpalette", title: "外观")
            divider
            row(icon: "bell.badge", title: "通知设置")
            divider
            row(icon: "info.circle", title: "关于")
        }
        .padding(.vertical, 6)
        .dsCard()
    }

    private var divider: some View {
        Divider().padding(.leading, 56).opacity(0.5)
    }

    private func row(icon: String, title: String) -> some View {
        Button { } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, DS.Spacing.card)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
