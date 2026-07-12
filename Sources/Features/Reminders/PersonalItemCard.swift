import SwiftUI

struct PersonalItemCard: View {
    @EnvironmentObject private var store: ChatStore
    let item: PersonalItem
    let onEdit: () -> Void
    let onToggleDone: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.gap) {
            HStack(alignment: .top, spacing: DS.Spacing.gap) {
                if item.kind == .reminder {
                    Button(action: onToggleDone) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .font(DS.Typo.pageTitle.weight(.semibold))
                            .foregroundStyle(item.isDone ? DS.Palette.green : DS.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.isDone ? "标记未完成" : "标记完成")
                }

                VStack(alignment: .leading, spacing: DS.Spacing.compact - 1) {
                    HStack(spacing: DS.Spacing.tight + 2) {
                        Text(item.title)
                            .font(DS.Typo.cardTitle)
                            .foregroundStyle(item.isDone ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                            .strikethrough(item.isDone)

                        if item.scope == "shared" {
                            AvatarBadge(
                                url: store.avatarURL(for: item.owner),
                                fallbackEmoji: store.avatarText(for: item.owner),
                                size: 20,
                                background: DS.Palette.innerSurface)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if item.kind == .reminder, let dueDate = item.dueDate {
                        Label(dueDate.smartLabel, systemImage: item.isOverdue ? "exclamationmark.circle.fill" : "clock.fill")
                            .font(DS.Typo.caption.weight(.semibold))
                            .foregroundStyle(item.isOverdue ? DS.Palette.pink : DS.Palette.textSecondary)
                    }
                    if item.kind == .memo {
                        Text("更新于 \(updatedDateText)")
                            .font(DS.Typo.caption.weight(.medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }

                Menu {
                    Button("编辑", action: onEdit)
                    if item.kind == .reminder {
                        Button(item.isDone ? "标记未完成" : "标记完成", action: onToggleDone)
                    }
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(DS.Typo.cardTitle)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("更多操作")
            }

            if !displayMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReminderMarkdownPreview(markdown: displayMarkdown)
                    .font(DS.Typo.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(item.kind == .memo ? nil : 3)
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .opacity(item.isDone ? 0.68 : 1)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .onTapGesture(perform: onEdit)
    }

    private var updatedDateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(item.updatedAt) / 1000))
    }

    private var displayMarkdown: String {
        MemoDisplayFormatter.body(for: item)
    }
}

