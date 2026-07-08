import SwiftUI
import PhotosUI

// 微信式表情面板：顶部分页（表情 / 收藏 / 各分组 + 管理），下面网格。
// 表情点一下插入输入框；贴纸点一下直接发送；长按贴纸可收藏 / 移动分组 / 删除；
// 「＋」添加自定义贴纸（相册选图 → 上传 → 入库）。

struct StickerEmojiPanel: View {
    @ObservedObject var store: StickerStore
    let onEmoji: (String) -> Void
    let onSendSticker: (Sticker) -> Void

    @EnvironmentObject private var chatStore: ChatStore

    // 选中的分页："emoji" / "fav" / 分组 id
    @State private var tab: String = "emoji"
    @State private var pickerItem: PhotosPickerItem?
    @State private var addBusy = false
    @State private var showManage = false

    private let emojiColumns = [GridItem(.adaptive(minimum: 42), spacing: 4)]
    private let stickerColumns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

    private var addGroupId: String {
        // 在某个分组页就加到该组，否则加到默认组
        if tab != "emoji", tab != "fav", store.groups.contains(where: { $0.id == tab }) {
            return tab
        }
        return StickerStore.defaultGroupId
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.25)
            tabStrip
            Divider().opacity(0.15)
            content
        }
        .background(DS.Palette.floatSurface)
        .photosPicker(isPresented: pickerBinding, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            addSticker(from: item)
        }
        .sheet(isPresented: $showManage) {
            StickerManageSheet(store: store)
        }
    }

    // 让「＋」直接触发相册（用一个隐藏 bool 桥接 PhotosPicker）
    @State private var showPicker = false
    private var pickerBinding: Binding<Bool> {
        Binding(get: { showPicker }, set: { showPicker = $0 })
    }

    // MARK: 顶部分页

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tabChip(id: "emoji", systemImage: "face.smiling", title: "表情")
                tabChip(id: "fav", systemImage: "star.fill", title: "收藏")
                ForEach(store.sortedGroups) { group in
                    tabChip(id: group.id, systemImage: "square.grid.2x2", title: group.name)
                }
                Button {
                    showManage = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 40, height: 34)
                        .background(DS.Palette.innerSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func tabChip(id: String, systemImage: String, title: String) -> some View {
        let selected = tab == id
        return Button {
            Haptics.selection()
            tab = id
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
            }
            .foregroundStyle(selected ? .white : DS.Palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                selected ? AnyShapeStyle(DS.Palette.accent) : AnyShapeStyle(DS.Palette.innerSurface),
                in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if tab == "emoji" {
            emojiGrid
        } else {
            stickerGrid(for: tab)
        }
    }

    private var emojiGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(EmojiCatalog.sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.leading, 4)
                        LazyVGrid(columns: emojiColumns, spacing: 4) {
                            ForEach(section.emojis, id: \.self) { emoji in
                                Button {
                                    Haptics.light()
                                    onEmoji(emoji)
                                } label: {
                                    Text(emoji)
                                        .font(.system(size: 28))
                                        .frame(width: 42, height: 42)
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func stickerGrid(for tabId: String) -> some View {
        let items = tabId == "fav" ? store.favorites : store.stickers(in: tabId)
        let canAdd = tabId != "fav"

        ScrollView {
            if items.isEmpty && !canAdd {
                emptyHint(tabId == "fav" ? "长按贴纸即可收藏" : "还没有表情")
            } else {
                LazyVGrid(columns: stickerColumns, spacing: 10) {
                    ForEach(items) { sticker in
                        stickerTile(sticker)
                    }
                    if canAdd {
                        addTile
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private func stickerTile(_ sticker: Sticker) -> some View {
        Button {
            Haptics.light()
            onSendSticker(sticker)
        } label: {
            CachedImage(url: sticker.mediaURL, contentMode: .fit) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DS.Palette.innerSurface)
                    .overlay(ProgressView().tint(DS.Palette.accent))
            }
            .frame(width: 72, height: 72)
            .background(DS.Palette.cardSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if sticker.favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                        .padding(4)
                }
            }
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button {
                store.toggleFavorite(sticker)
            } label: {
                Label(sticker.favorite ? "取消收藏" : "收藏",
                      systemImage: sticker.favorite ? "star.slash" : "star")
            }
            Menu {
                ForEach(store.sortedGroups) { group in
                    Button(group.name) { store.move(sticker, to: group.id) }
                }
            } label: {
                Label("移动到分组", systemImage: "folder")
            }
            Button(role: .destructive) {
                store.delete(sticker)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var addTile: some View {
        Button {
            showPicker = true
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Palette.innerSurface)
                .frame(width: 72, height: 72)
                .overlay {
                    if addBusy {
                        ProgressView().tint(DS.Palette.accent)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
        }
        .buttonStyle(PressableStyle())
        .disabled(addBusy)
    }

    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "face.dashed")
                .font(.system(size: 30))
                .foregroundStyle(DS.Palette.textSecondary.opacity(0.5))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DS.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func addSticker(from item: PhotosPickerItem) {
        let group = addGroupId
        addBusy = true
        Task {
            defer {
                Task { @MainActor in
                    addBusy = false
                    pickerItem = nil
                }
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let url = await chatStore.uploadSticker(image) else {
                await MainActor.run { Haptics.medium() }
                return
            }
            await MainActor.run {
                store.add(url: url, groupId: group)
                Haptics.light()
            }
        }
    }
}

// MARK: - 表情分组管理

struct StickerManageSheet: View {
    @ObservedObject var store: StickerStore
    @Environment(\.dismiss) private var dismiss

    @State private var showNewGroup = false
    @State private var newGroupName = ""
    @State private var renaming: StickerGroup?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.sortedGroups) { group in
                        HStack {
                            Image(systemName: "square.grid.2x2")
                                .foregroundStyle(DS.Palette.accent)
                            Text(group.name)
                                .foregroundStyle(DS.Palette.textPrimary)
                            Spacer()
                            Text("\(store.stickers(in: group.id).count)")
                                .font(.system(size: 13))
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing) {
                            if group.id != StickerStore.defaultGroupId {
                                Button(role: .destructive) {
                                    store.deleteGroup(group)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            Button {
                                renaming = group
                                renameText = group.name
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(DS.Palette.accent)
                        }
                    }
                } header: {
                    Text("表情分组")
                } footer: {
                    Text("删除分组后，组内表情会移回「我的表情」。")
                }

                Section {
                    Button {
                        newGroupName = ""
                        showNewGroup = true
                    } label: {
                        Label("新建分组", systemImage: "folder.badge.plus")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("表情管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("新建分组", isPresented: $showNewGroup) {
                TextField("分组名（最多 8 字）", text: $newGroupName)
                Button("创建") { store.createGroup(name: newGroupName) }
                Button("取消", role: .cancel) {}
            }
            .alert("重命名分组", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("分组名", text: $renameText)
                Button("保存") {
                    if let group = renaming { store.renameGroup(group, to: renameText) }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            }
        }
    }
}
