import SwiftUI

enum ChatHomeAvatarArt {
    case dog
    case bunny
}

struct ChatHomeCoupleAvatarColumn: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let avatar: String
    var avatarURL: URL? = nil
    let image: ChatHomeAvatarArt
    let status: String?
    let online: Bool
    let ring: Color
    let editable: Bool
    let statusOptions: [ChatHomeStatusOption]
    let onStatusTap: () -> Void

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
                .overlay(
                    Circle()
                        .stroke(DS.Palette.innerSurface.opacity(0.92), lineWidth: 4)
                        .allowsHitTesting(false)
                )
                .shadow(color: ring.opacity(0.18), radius: 10, y: 5)

                Circle()
                    .fill(online ? DS.Palette.green : DS.Palette.textSecondary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .stroke(DS.Palette.cardSurface, lineWidth: 4)
                            .allowsHitTesting(false)
                    )
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
                onStatusTap()
            } label: {
                statusCapsuleLabel(showsMenuIndicator: true)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .zIndex(2)
            .accessibilityLabel(status == nil ? "添加状态" : "当前状态 \(status ?? "")")
            .accessibilityHint("轻点选择或管理自己的状态")
        } else {
            statusCapsuleLabel(showsMenuIndicator: false)
                .accessibilityLabel(status == nil ? "对方暂未设置状态" : "对方状态 \(status ?? "")")
        }
    }

    private func statusCapsuleLabel(showsMenuIndicator: Bool) -> some View {
        let tint = statusOptions.first(where: { $0.title == status })?.color ?? ring
        let title = status ?? (editable ? "加状态" : "暂无状态")
        return HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(tint.opacity(colorScheme == .dark ? 0.28 : 0.16))
                    .frame(width: 16, height: 16)
                if status == nil && editable {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                } else {
                    Circle()
                        .fill(status == nil ? DS.Palette.textTertiary : tint)
                        .frame(width: 7, height: 7)
                }
            }
            Text(title)
                .font(DS.Typo.secondary.weight(.bold))
                .foregroundStyle(status == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .multilineTextAlignment(.center)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minWidth: 96, minHeight: 44)
        .contentShape(Capsule())
        .background {
            Capsule()
                .fill(DS.Palette.fieldSurface)
            Capsule()
                .fill(tint.opacity(colorScheme == .dark ? 0.16 : 0.09))
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.18 : 0.76),
                            tint.opacity(colorScheme == .dark ? 0.48 : 0.30),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing),
                    lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10),
            radius: 7,
            y: 3)
    }
}

struct ChatHomeStatusPickerSheet: View {
    let currentStatus: String?
    let options: [ChatHomeStatusOption]
    let onPick: (ChatHomeStatusOption) -> Void
    let onAdd: () -> Void
    let onEdit: (ChatHomeStatusOption) -> Void
    let onDelete: (ChatHomeStatusOption) -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    private var currentOption: ChatHomeStatusOption? {
        options.first(where: { $0.title == currentStatus })
    }

    var body: some View {
        NavigationStack {
            List {
                Section("选择状态") {
                    ForEach(options) { option in
                        Button {
                            onPick(option)
                        } label: {
                            HStack(spacing: 11) {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 10, height: 10)
                                Text(option.title)
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Spacer()
                                if option.title == currentStatus {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(option.color)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("管理") {
                    Button(action: onAdd) {
                        Label("添加自定义状态", systemImage: "plus.circle")
                    }
                    if let currentOption {
                        Button { onEdit(currentOption) } label: {
                            Label("编辑当前状态", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            onDelete(currentOption)
                        } label: {
                            Label("删除当前状态", systemImage: "trash")
                        }
                    }
                    if currentStatus != nil {
                        Button(role: .destructive, action: onClear) {
                            Label("清除当前状态", systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("我的状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: onClose)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationSizing(.form)
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
