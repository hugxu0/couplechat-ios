import SwiftUI

enum ChatHomeAvatarArt {
    case dog
    case bunny
}

struct ChatHomeCoupleAvatarColumn: View {
    let name: String
    let avatar: String
    var avatarURL: URL? = nil
    let image: ChatHomeAvatarArt
    let status: String?
    let online: Bool
    let ring: Color
    let editable: Bool
    let statusOptions: [ChatHomeStatusOption]
    let onStatusPick: (ChatHomeStatusOption) -> Void
    let onAddStatus: () -> Void
    let onClearStatus: () -> Void
    let onEditStatus: (ChatHomeStatusOption) -> Void
    let onDeleteStatus: (ChatHomeStatusOption) -> Void
    @State private var showStatusPicker = false

    var body: some View {
        VStack(spacing: 9) {
            statusCapsule

            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let avatarURL {
                        CachedImage(url: avatarURL) {
                            ChatHomeAvatarIllustration(kind: image, fallback: avatar)
                        }
                    } else {
                        ChatHomeAvatarIllustration(kind: image, fallback: avatar)
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay(Circle().stroke(DS.Palette.innerSurface.opacity(0.92), lineWidth: 4))
                .shadow(color: ring.opacity(0.18), radius: 10, y: 5)

                Circle()
                    .fill(online ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(DS.Palette.cardSurface, lineWidth: 4))
                    .offset(x: -9, y: -10)
            }

            Text(name)
                .font(DS.Typo.cardTitle)
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var statusCapsule: some View {
        if editable {
            Button {
                Haptics.light()
                showStatusPicker = true
            } label: {
                Text(status ?? "加状态")
                    .font(DS.Typo.secondary.weight(.bold))
                    .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.pink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DS.Palette.innerSurface, in: Capsule())
            }
            .frame(minWidth: 76, minHeight: 34)
            .contentShape(Capsule())
            .buttonStyle(PressableStyle())
            .confirmationDialog("选择状态", isPresented: $showStatusPicker, titleVisibility: .visible) {
                ForEach(statusOptions) { option in
                    Button(option.title) { onStatusPick(option) }
                }
                Button("添加状态") { onAddStatus() }
                if status != nil {
                    Button("清除当前状态", role: .destructive) { onClearStatus() }
                }
            }
            .contextMenu {
                ForEach(statusOptions) { option in
                    Button(option.title) { onStatusPick(option) }
                }
                Button("添加状态") { onAddStatus() }
                if let currentStatus = statusOptions.first(where: { $0.title == status }) {
                    Button("编辑当前状态") { onEditStatus(currentStatus) }
                    Button("删除当前状态", role: .destructive) { onDeleteStatus(currentStatus) }
                }
            }
            .accessibilityLabel(status == nil ? "添加状态" : "当前状态 \(status ?? "")")
        } else {
            Text(status ?? "想贴贴")
                .font(DS.Typo.secondary.weight(.bold))
                .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary.opacity(0.62))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(DS.Palette.innerSurface, in: Capsule())
        }
    }
}

struct ChatHomeAvatarIllustration: View {
    @Environment(\.colorScheme) private var colorScheme
    let kind: ChatHomeAvatarArt
    let fallback: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.16, green: 0.18, blue: 0.25), Color(red: 0.12, green: 0.13, blue: 0.21)]
                    : [Color.white.opacity(0.75), Color(red: 1.0, green: 0.95, blue: 0.97).opacity(0.6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            decorativeMarks
            Text(fallback)
                .font(.system(size: 38))
                .offset(y: 6)
        }
    }

    @ViewBuilder
    private var decorativeMarks: some View {
        switch kind {
        case .dog:
            Image(systemName: "bone.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color(red: 0.42, green: 0.46, blue: 0.56).opacity(0.22))
                .offset(x: 28, y: -30)
            Circle()
                .fill(Color(red: 0.97, green: 0.57, blue: 0.68).opacity(0.28))
                .frame(width: 18, height: 18)
                .offset(x: -32, y: -28)
        case .bunny:
            Image(systemName: "heart.fill")
                .font(.system(size: 18))
                .foregroundStyle(DS.Palette.pink.opacity(0.22))
                .offset(x: -32, y: -32)
            Image(systemName: "sparkle")
                .font(.system(size: 20))
                .foregroundStyle(DS.Palette.pink.opacity(0.30))
                .offset(x: 32, y: -24)
        }
    }
}
