import SwiftUI

struct PetTodayTogetherView: View {
    let prompt: PetDailyPrompt?
    let currentUsername: String
    let isBusy: Bool
    let onRespond: (String) async -> Bool

    @State private var responseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AppSectionHeader(
                title: "今天一起",
                subtitle: "两个人异步完成，不打卡、不催促")

            if let prompt {
                promptCard(prompt)
                PetPairedEchoView(isCompleted: prompt.isCompleted)
                responseCards(prompt)
                responseComposer(prompt)
                rewardCard(prompt)
            } else {
                AppEmptyState(
                    "今天先晒晒太阳",
                    systemImage: "sun.max.fill",
                    detail: "新题目会由服务端同步到你们的所有设备")
            }
        }
        .padding(.top, 4)
    }

    private func promptCard(_ prompt: PetDailyPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("今天的小事", systemImage: "sparkles")
                .font(DS.Typo.sectionLabel)
                .foregroundStyle(DS.Palette.orange)
            Text(prompt.prompt)
                .font(.title3.weight(.semibold))
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [DS.Palette.orange.opacity(0.13), DS.Palette.pink.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
    }

    private func responseCards(_ prompt: PetDailyPrompt) -> some View {
        let mine = prompt.responses.first { $0.username == currentUsername }
        let partner = prompt.responses.first { $0.username != currentUsername }
        return VStack(spacing: 10) {
            PetResponseCard(
                title: mine?.displayName ?? "我",
                text: mine?.text,
                tint: DS.Palette.blue)
            PetResponseCard(
                title: partner?.displayName ?? "TA",
                text: partner?.text,
                tint: DS.Palette.pink)
        }
    }

    @ViewBuilder
    private func responseComposer(_ prompt: PetDailyPrompt) -> some View {
        let hasResponded = prompt.responses.contains { $0.username == currentUsername }
        if !hasResponded {
            VStack(alignment: .leading, spacing: 10) {
                TextField("写下你的回应…", text: $responseText, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.plain)
                    .padding(14)
                    .background(DS.Palette.innerSurface)
                    .clipShape(RoundedRectangle(
                        cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityLabel("回应今天一起")

                Text("\(responseText.count)/1000")
                    .font(DS.Typo.caption.monospacedDigit())
                    .foregroundStyle(
                        responseText.count > 1_000 ? DS.Palette.red : DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                AppPrimaryButton(
                    title: "留下我的回声",
                    busy: isBusy,
                    enabled: canSubmit) {
                        submit()
                    }
            }
        } else if !prompt.isCompleted {
            StatusBanner(text: "你的回声已留下，等 TA 来时会自然汇合", kind: .info)
        }
    }

    @ViewBuilder
    private func rewardCard(_ prompt: PetDailyPrompt) -> some View {
        if prompt.isCompleted, let reward = prompt.reward?.item {
            HStack(spacing: 12) {
                Image(systemName: reward.symbolName ?? "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(DS.Palette.orange)
                    .frame(width: 46, height: 46)
                    .background(DS.Palette.orange.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("两条回声汇合了")
                        .font(DS.Typo.cardTitle)
                    Text("小窝藏品 · \(reward.name)")
                        .font(DS.Typo.secondary)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(DS.Palette.orange)
            }
            .padding(14)
            .background(DS.Palette.orange.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var canSubmit: Bool {
        let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 1_000
    }

    private func submit() {
        let value = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            if await onRespond(value) { responseText = "" }
        }
    }
}

private struct PetPairedEchoView: View {
    let isCompleted: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(DS.Palette.blue).frame(width: 14, height: 14)
            Capsule()
                .fill(LinearGradient(
                    colors: [DS.Palette.blue.opacity(0.55), DS.Palette.orange.opacity(0.75)],
                    startPoint: .leading,
                    endPoint: .trailing))
                .frame(height: 3)
            Image(systemName: isCompleted ? "pawprint.fill" : "pawprint")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isCompleted ? DS.Palette.orange : DS.Palette.textSecondary)
                .frame(width: 36, height: 36)
                .background(DS.Palette.orange.opacity(isCompleted ? 0.13 : 0.05), in: Circle())
            Capsule()
                .fill(LinearGradient(
                    colors: [DS.Palette.orange.opacity(0.75), DS.Palette.pink.opacity(0.55)],
                    startPoint: .leading,
                    endPoint: .trailing))
                .frame(height: 3)
            Circle().fill(DS.Palette.pink).frame(width: 14, height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCompleted ? "双方回应已汇合，获得橘色爪印" : "正在等待双方回应汇合")
    }
}

private struct PetResponseCard: View {
    let title: String
    let text: String?
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(DS.Typo.sectionLabel)
                    .foregroundStyle(tint)
                Text(text ?? "还没有留下回声")
                    .font(DS.Typo.body)
                    .foregroundStyle(text == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(text == nil ? 0.045 : 0.085))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
