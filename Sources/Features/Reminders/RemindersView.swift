import SwiftUI

// 提醒页：提醒/备忘切换 + 按人分组。假数据。

struct RemindersView: View {
    @State private var section = 0   // 0 提醒 / 1 备忘
    @State private var person = 0    // 0 小旭 / 1 小偲
    @State private var draft = ""
    @State private var reminders: [String] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Spacing.gap) {
                    segmented(["提醒", "备忘"], selection: $section, accentGradient: true)
                    segmented(["小旭", "小偲"], selection: $person, accentGradient: false)
                        .frame(maxWidth: 280)
                    listCard
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.bottom, 90)
            }
            .scrollIndicators(.hidden)
            .background(DS.Palette.bgGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func segmented(_ items: [String], selection: Binding<Int>, accentGradient: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, label in
                Button {
                    withAnimation(DS.Anim.spring) { selection.wrappedValue = i }
                    Haptics.selection()
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selection.wrappedValue == i
                                         ? (accentGradient ? .white : DS.Palette.accent)
                                         : DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background {
                            if selection.wrappedValue == i {
                                Group {
                                    if accentGradient {
                                        Capsule().fill(DS.Palette.accentGradient)
                                    } else {
                                        Capsule().fill(Color.white)
                                    }
                                }
                                .matchedGeometryEffect(id: "seg", in: segNS, isSource: true)
                            }
                        }
                }
            }
        }
        .padding(4)
        .background(DS.Palette.innerSurface)
        .clipShape(Capsule())
    }
    @Namespace private var segNS

    private var listCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(person == 0 ? "小旭" : "小偲")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text("\(reminders.count) 条提醒")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            HStack(spacing: 8) {
                TextField("加一条提醒...", text: $draft)
                    .font(.system(size: 15))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.04))
                    .clipShape(Capsule())

                Button { } label: {
                    Text("时间").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.black.opacity(0.04))
                        .clipShape(Capsule())
                }
                Button {
                    guard !draft.isEmpty else { return }
                    Haptics.light()
                    withAnimation(DS.Anim.spring) {
                        reminders.append(draft)
                        draft = ""
                    }
                } label: {
                    Text("添加").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(DS.Palette.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }

            if reminders.isEmpty {
                Text("还没有提醒")
                    .font(.system(size: 15))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(reminders, id: \.self) { item in
                    HStack {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(DS.Palette.accent)
                        Text(item).font(.system(size: 15))
                            .foregroundStyle(DS.Palette.textPrimary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .padding(DS.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.bubbleOther)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .shadow(color: DS.Surface.shadow, radius: DS.Surface.shadowRadius, y: DS.Surface.shadowY)
    }
}
