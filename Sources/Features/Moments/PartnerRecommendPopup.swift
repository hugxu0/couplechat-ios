import SwiftUI

// MARK: - 收到推荐的弹窗（对方送来的惊喜）

struct PartnerRecommendPopup: View {
    let recommend: PartnerRecommend
    let onDismiss: () -> Void

    @EnvironmentObject private var theme: ThemeManager
    @State private var appeared = false

    var body: some View {
        ZStack {
            // 半透明暗背景，点击也可关闭
            DS.Surface.scrim
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // 顶部渐变礼物区
                ZStack {
                    theme.accent.gradient
                    VStack(spacing: 6) {
                        Text("🎁")
                            .font(.system(size: 44))
                            .scaleEffect(appeared ? 1.0 : 0.4)
                            .rotationEffect(.degrees(appeared ? 0 : -18))
                        Text("\(recommend.fromName) 给你推荐了")
                            .font(DS.Typo.secondary.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(.vertical, 22)

                    // 柔光装饰
                    Image(systemName: "sparkles")
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.16))
                        .offset(x: 110, y: -14)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.14))
                        .offset(x: -110, y: 20)
                }
                .frame(height: 118)

                // 推荐内容
                VStack(spacing: 18) {
                    Text(recommend.text)
                        .font(DS.Typo.body.weight(.medium))
                        .foregroundStyle(DS.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                        .padding(.horizontal, 22)
                        .padding(.top, 20)

                    Button {
                        Haptics.light()
                        onDismiss()
                    } label: {
                        Text("收到啦 💗")
                            .font(DS.Typo.button)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(theme.accent.gradient, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.horizontal, 22)
                    .padding(.bottom, 20)
                }
                .background(DS.Palette.cardSurface)
            }
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel + 2, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
            .scaleEffect(appeared ? 1.0 : 0.82)
            .opacity(appeared ? 1.0 : 0)
            .padding(.horizontal, 36)
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) {
                appeared = true
            }
        }
    }
}
