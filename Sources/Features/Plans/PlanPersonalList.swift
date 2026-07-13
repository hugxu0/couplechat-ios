import SwiftUI

struct PlanPersonalList: View {
    let kind: PersonalItemKind
    let scope: String
    let items: [PersonalItem]
    let allItems: [PersonalItem]
    let loading: Bool
    let onCreate: () -> Void
    let onEdit: (PersonalItem) -> Void
    let onToggle: (PersonalItem) -> Void
    let onDelete: (PersonalItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            HStack {
                Text(kind == .reminder ? "提醒" : "备忘")
                    .font(DS.Typo.cardTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Button(createTitle, systemImage: "plus", action: onCreate)
                    .font(DS.Typo.button)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            summary
            if loading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            } else if items.isEmpty {
                VStack(spacing: DS.Spacing.gap) {
                    AppEmptyState(emptyTitle, systemImage: kind == .reminder ? "bell.slash" : "text.book.closed")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 300, maximum: 560), spacing: DS.Spacing.gap)],
                    spacing: DS.Spacing.gap
                ) {
                    ForEach(items) { item in
                        PersonalItemCard(
                            item: item,
                            onEdit: { onEdit(item) },
                            onToggleDone: { onToggle(item) },
                            onDelete: { onDelete(item) })
                    }
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: DS.Spacing.gap) {
            metric("待办", value: reminders.filter { !$0.isDone }.count, color: DS.Palette.accent)
            metric("今日", value: reminders.filter(\.isToday).count, color: DS.Palette.blue)
            metric("备忘", value: memos.count, color: DS.Palette.pink)
        }
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(DS.Typo.pageTitle.monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(DS.Typo.caption.weight(.medium))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dsCard(radius: DS.Radius.tile)
        .accessibilityElement(children: .combine)
    }

    private var reminders: [PersonalItem] { allItems.filter { $0.kind == .reminder && $0.scope == scope } }
    private var memos: [PersonalItem] { allItems.filter { $0.kind == .memo && $0.scope == scope } }
    private var createTitle: String { kind == .reminder ? "添加提醒" : "写备忘录" }
    private var emptyTitle: String {
        if scope == "shared" { return kind == .reminder ? "还没有共享提醒" : "还没有共享备忘" }
        return kind == .reminder ? "还没有私人提醒" : "还没有私人备忘"
    }
}
