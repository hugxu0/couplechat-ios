import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
import AVFoundation
import AVKit

// 鑱婂ぉ浼氳瘽椤碉細鐪熷疄鏁版嵁鏉ヨ嚜 ChatStore锛屽彲鎵胯浇 couple / ai 涓や釜棰戦亾銆?
struct ChatView: View {
    let channel: ChatChannel

    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var store: ChatStore
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var selectedMedia: PhotosPickerItem?
    @State private var mediaBusy = false
    @State private var showFileImporter = false
    @State private var showWallpaperPicker = false
    @State private var replyTarget: ChatMessage?
    @State private var showMedia = false
    @State private var scrollToMessageId: String?
    @State private var highlightedMessageId: String?
    @State private var pendingTopAnchor: String?
    @State private var isJumping = false
    @State private var mediaViewerMessageId: String?
    @State private var isRecording = false
    @State private var recordingCancelled = false
    @State private var recordingElapsed: TimeInterval = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var recordingPulse = false
    @State private var recordingTimer: Timer?
    @State private var audioRecorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var recordingStartDate: Date?
    @State private var showMicPermissionAlert = false
    @State private var showStickerPanel = false
    @State private var showAttachmentTray = false
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var mediaPreviewItems: [MediaPreviewItem] = []
    @ObservedObject private var stickerStore = StickerStore.shared
    @FocusState private var inputFocused: Bool
    private static let cancelDragThreshold: CGFloat = -70
    private static let composerButtonSize: CGFloat = 44

    init(channel: ChatChannel = .couple) {
        self.channel = channel
    }

    private var messages: [ChatMessage] { store.messages(for: channel) }
    private var mediaMessages: [ChatMessage] {
        // 璐寸焊涓嶈繘澶у浘娴忚 / 濯掍綋搴擄紝鍙畻鐪熷疄鍥剧墖鍜岃棰?        Array(store.mediaMessages(for: channel, includeFiles: false).reversed())
    }
    private var title: String {
        switch channel {
        case .couple: return store.partnerDisplayName(fallback: "鑱婂ぉ")
        case .ai: return "澶ф"
        }
    }
    private var subtitle: String {
        if !store.connected {
            return store.lastConnectionError ?? "鏈繛鎺?
        }
        switch channel {
        case .couple: return store.partnerOnline ? "鍦ㄧ嚎" : "绂荤嚎"
        case .ai: return store.aiTyping ? "姝ｅ湪杈撳叆" : "闄綘鑱婂ぉ"
        }
    }
    private var subtitleColor: Color {
        if !store.connected { return .red }
        switch channel {
        case .couple: return store.partnerOnline ? DS.Palette.green : DS.Palette.textSecondary
        case .ai: return store.aiTyping ? DS.Palette.green : DS.Palette.textSecondary
        }
    }
    private var displayedWallpaper: WallpaperChoice {
        if colorScheme == .dark && !theme.hasCustomWallpaper(for: channel) {
            return .night
        }
        return theme.wallpaper(for: channel)
    }

    var body: some View {
        messageList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    replyBar
                    aiTypingHint
                    if !mediaPreviewItems.isEmpty {
                        mediaPreviewRow
                    }
                    composer
                    if showStickerPanel {
                        StickerEmojiPanel(
                            store: stickerStore,
                            onEmoji: { draft += $0 },
                            onSendSticker: { sendSticker($0) })
                            .frame(height: 300)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .onChange(of: inputFocused) { _, focused in
                // 寮瑰嚭閿洏鏃舵敹璧疯〃鎯呴潰鏉垮拰闄勪欢闈㈡澘锛屼笁鑰呬笉骞跺瓨
                if focused {
                    if showStickerPanel || showAttachmentTray {
                        withAnimation(DS.Anim.springFast) {
                            showStickerPanel = false
                            showAttachmentTray = false
                        }
                    }
                }
            }
        .background(
            ZStack {
                displayedWallpaper.gradient(dark: colorScheme == .dark)
                if let img = theme.customWallpaperImage(for: channel) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                }
                displayedWallpaper.patternOverlay
            }
            .ignoresSafeArea()
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(subtitleColor)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    ChatDetailSettingsView(
                        channel: channel,
                        partnerName: title,
                        partnerAvatar: peerAvatar,
                        partnerOnline: store.partnerOnline,
                        onJumpToMessage: { jumpToMessage($0) },
                        onJumpToDate: { jumpToDate($0) }
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showMedia) {
            MediaGallerySheet(channel: channel)
        }
        .sheet(isPresented: $showWallpaperPicker) {
            WallpaperPickerSheet(channel: channel)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: Binding(
            get: { mediaViewerMessageId != nil },
            set: { if !$0 { mediaViewerMessageId = nil } }
        )) {
            MediaPagerView(messages: mediaMessages, selectedId: $mediaViewerMessageId)
        }
        // 杩涗細璇濋殣钘忓簳閮ㄦ爣绛炬爮锛岄€€鍑猴紙鍚晶婊戣繑鍥烇級鎭㈠
        .onAppear {
            app.pushSubpage()
            // 鍏滃簳锛氬唴瀛橀噷娌℃秷鎭椂绔嬪埢浠庢湰鍦板簱琛ワ紝淇濊瘉杩涙潵灏辫兘鐪嬪埌鍘嗗彶
            store.ensureLocalMessages(channel)
            store.markRead(channel)
        }
        .onDisappear { app.popSubpage() }
        .onChange(of: selectedMediaItems) {
            loadMediaPreviewItems()
        }
        .alert("闇€瑕侀害鍏嬮鏉冮檺", isPresented: $showMicPermissionAlert) {
            Button("鍘昏缃?) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("鍙栨秷", role: .cancel) {}
        } message: {
            Text("璇峰湪绯荤粺璁剧疆涓厑璁歌闂害鍏嬮锛屾墠鑳藉彂閫佽闊虫秷鎭?)
        }
    }

    // MARK: 娑堟伅鍒楄〃
    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if store.isLoadingOlder(channel) {
                        ProgressView()
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    } else if !store.connected && store.reachedOldestLocal.contains(channel.rawValue) {
                        Text("宸叉樉绀烘墍鏈夋湰鍦版秷鎭?)
                            .font(.system(size: 13))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                    } else {
                        // 鍔犺浇鏇村鍝ㄥ叺锛氭粴鍒伴《閮ㄨ嚜鍔ㄨЕ鍙?                        Color.clear
                            .frame(height: 1)
                            .id("loadMoreSentinel")
                            .onAppear {
                                guard messages.count > 0 else { return }
                                pendingTopAnchor = messages.first?.id
                                store.loadOlder(channel)
                            }
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, msg in
                        VStack(spacing: 0) {
                            if showTimeSeparator(index) {
                                Text(msg.timeString)
                                    .font(.system(size: 13))
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .padding(.vertical, 14)
                            }
                            if msg.kind == "system" {
                                systemMessage(msg)
                            } else {
                                let own = msg.sender == store.session?.username
                                let withinTwoMin = own && (Date().timeIntervalSince1970 * 1000 - msg.ts) < 120_000
                                MessageBubble(
                                    message: msg,
                                    mine: own,
                                    peerAvatar: peerAvatar,
                                    myAvatar: myAvatarEmoji,
                                    peerAvatarURL: peerAvatarURL,
                                    myAvatarURL: myAvatarURL,
                                    groupedWithPrevious: isGrouped(index),
                                    read: store.partnerHasRead(msg),
                                    canRetry: msg.type == "text",
                                    highlighted: highlightedMessageId == msg.id,
                                    onRetry: { store.resend(msg) },
                                    onMediaTap: {
                                        mediaViewerMessageId = msg.id
                                    },
                                    contextMenuContent: AnyView(messageContextMenu(msg, own: own, withinTwoMin: withinTwoMin)))
                                .padding(.top, bubbleTopPadding(index))
                            }
                        }
                        .id(msg.id)
                    }
                    // 搴曢儴閿氱偣锛氭墍鏈夐渶瑕佽创搴曠殑鏃跺€?scrollTo 鍒拌繖閲?                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                }
                .padding(.horizontal, DS.Spacing.page)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            // 鐐瑰嚮绌虹櫧澶勭敤 UIKit 鏍囧噯鏂瑰紡鏀惰捣閿洏锛岃窡绯荤粺閿洏鍔ㄧ敾缁熶竴
            .simultaneousGesture(
                TapGesture().onEnded {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                    if showStickerPanel || showAttachmentTray {
                        withAnimation(DS.Anim.springFast) {
                            showStickerPanel = false
                            showAttachmentTray = false
                        }
                    }
                }
            )
            // 鍒濆瀹氫綅浜ょ粰 .defaultScrollAnchor(.bottom)锛岃繖閲屽彧鍦ㄦ秷鎭暟鍙樺寲鏃惰ˉ璐村簳锛?            // 閬垮厤杩涢〉闈㈡椂澶氫竴娆?scrollTo 閫犳垚鐨勫叆鍦哄崱椤裤€?            .onChange(of: messages.last?.id) {
                guard !isJumping else { return }
                scrollToBottom(proxy, animated: true)
            }
            // 椤堕儴鎻掑叆鏇存棭娑堟伅鍚庯紝鎶婅鍙ｉ敋鍥炴彃鍏ュ墠鐨勭涓€鏉℃秷鎭紝閬垮厤鐢婚潰璺冲姩
            .onChange(of: messages.first?.id) { _, _ in
                guard let anchor = pendingTopAnchor else { return }
                pendingTopAnchor = nil
                // 绛変袱甯ц LazyVStack 瀹屾垚甯冨眬锛屽啀瀹氫綅鍒板師鏉ョ殑棣栨潯娑堟伅
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    withAnimation(.none) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            // 閿洏寮?鏀讹細杈撳叆鏍忕敱绯荤粺閬胯閿洏锛岃繖閲屽彧鐢ㄥ悓涓€鍔ㄧ敾鍚屾璐村簳婊氬姩銆?            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                withAnimation(keyboardAnimation(from: note)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                withAnimation(keyboardAnimation(from: note)) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: showStickerPanel) {
                withAnimation(DS.Anim.springFast) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: showAttachmentTray) {
                withAnimation(DS.Anim.springFast) {
                    proxy.scrollTo("bottomAnchor", anchor: .bottom)
                }
            }
            .onChange(of: scrollToMessageId) { _, targetId in
                guard let targetId else { return }
                isJumping = true
                // 绛夋悳绱?sheet 鏀惰捣銆佹柊鎻掑叆鐨勬秷鎭畬鎴愬竷灞€鍚庡啀瀹氫綅锛?.4s 瑕嗙洊 sheet 鍏抽棴鍔ㄧ敾锛?                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // 瀹氫綅婊氬姩涓嶅姞鍔ㄧ敾锛岄伩鍏嶅鍒氭暣浣撴浛鎹€佹湭甯冨眬杩囩殑 LazyVStack 鍋氬姩鐢绘彃鍊?                    proxy.scrollTo(targetId, anchor: .center)
                    withAnimation(DS.Anim.ease) {
                        highlightedMessageId = targetId
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        guard highlightedMessageId == targetId else { return }
                        withAnimation(DS.Anim.ease) {
                            highlightedMessageId = nil
                        }
                        if scrollToMessageId == targetId {
                            scrollToMessageId = nil
                        }
                        isJumping = false
                    }
                }
            }
        }
    }

    /// 鎼滅储缁撴灉璺宠浆锛氬厛纭繚鍛戒腑娑堟伅宸插姞杞借繘鍒楄〃锛堝彲鑳芥槸寰堣€佺殑鍘嗗彶锛夛紝鍐嶈Е鍙戞粴鍔ㄥ畾浣?    private func jumpToMessage(_ message: ChatMessage) {
        store.ensureMessageLoaded(message, channel: channel)
        scrollToMessageId = message.id
    }

    private func jumpToDate(_ date: Date) {
        guard let target = store.ensureDateLoaded(date, channel: channel) else { return }
        scrollToMessageId = target.id
    }

    /// 婊氬埌搴曢儴閿氱偣锛涘欢杩熶竴甯ц LazyVStack 娓叉煋绋冲畾
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = false) {
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottomAnchor", anchor: .bottom)
        }
    }

    /// 涓庝笂涓€鏉￠棿闅旇秴杩?8 鍒嗛挓鎵嶆樉绀烘椂闂村垎闅旓紙璐磋繎缃戦〉鐗堣涓猴級
    private func showTimeSeparator(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        return messages[index].ts - messages[index - 1].ts > 8 * 60 * 1000
    }

    /// 璺熶笂涓€鏉℃槸鍚屼竴涓汉 鈫?绠楀悓缁勶紙姘旀场闂磋窛鏇村皬銆佸ご鍍忓彧鏄剧ず涓€娆★級
    private func isGrouped(_ index: Int) -> Bool {
        guard index > 0, !showTimeSeparator(index) else { return false }
        return messages[index - 1].sender == messages[index].sender
            && messages[index - 1].kind != "system"
    }

    private func bubbleTopPadding(_ index: Int) -> CGFloat {
        guard index > 0, !showTimeSeparator(index) else { return 0 }
        return isGrouped(index) ? DS.Spacing.bubbleGapSame : DS.Spacing.bubbleGapOther
    }

    private var peerAvatar: String {
        if channel == .ai { return "馃惐" }
        return store.partner?.avatar ?? AccountPresentation.avatar(for: store.partner?.username ?? "si")
    }

    private var peerAvatarURL: URL? {
        channel == .ai ? nil : store.avatarURL(for: store.partner?.username)
    }

    private var myAvatarEmoji: String {
        AccountPresentation.avatar(for: store.session?.username ?? "xu")
    }

    private var myAvatarURL: URL? {
        store.avatarURL(for: store.session?.username)
    }

    // MARK: 绯荤粺娑堟伅锛堟挙鍥炴秷鎭姞閲嶆柊缂栬緫锛?    @ViewBuilder
    private func systemMessage(_ msg: ChatMessage) -> some View {
        HStack(spacing: 4) {
            Text(msg.text)
                .font(.system(size: 12))
                .foregroundStyle(DS.Palette.textSecondary)
            if msg.sender == store.session?.username,
               let recalledText = msg.recalledText, !recalledText.isEmpty {
                Button {
                    draft = recalledText
                    inputFocused = true
                } label: {
                    Text("閲嶆柊缂栬緫")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.Palette.accent)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: 闀挎寜鑿滃崟
    @ViewBuilder
    private func messageContextMenu(_ msg: ChatMessage, own: Bool, withinTwoMin: Bool) -> some View {

        if msg.type == "text" {
            Button {
                UIPasteboard.general.string = msg.displayText
            } label: {
                Label("澶嶅埗", systemImage: "doc.on.doc")
            }
        }

        Button {
            replyTarget = msg
            inputFocused = true
        } label: {
            Label("寮曠敤", systemImage: "arrowshape.turn.up.left")
        }

        if withinTwoMin && !msg.pending && !msg.failed {
            Button(role: .destructive) {
                store.recallMessage(msg, channel: channel)
            } label: {
                Label("鎾ゅ洖", systemImage: "trash")
            }
        }
    }

    // MARK: 鍥炲寮曠敤鏉?    @ViewBuilder
    private var replyBar: some View {
        if let target = replyTarget {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(DS.Palette.accent)
                    .frame(width: 3, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.Palette.accent)
                        .lineLimit(1)
                    Text(target.displayText)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation(DS.Anim.springFast) {
                        replyTarget = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var aiTypingHint: some View {
        if channel == .ai && (store.aiTyping || store.aiReplying) {
            HStack(spacing: 8) {
                typingDots
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var typingDots: some View {
        HStack(spacing: 5) {
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(0))
                .animation(typingDotAnimation(0), value: store.aiTyping || store.aiReplying)
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(1))
                .animation(typingDotAnimation(1), value: store.aiTyping || store.aiReplying)
            Circle().frame(width: 7, height: 7)
                .scaleEffect(store.aiTyping || store.aiReplying ? 1.0 : 0.7)
                .opacity(typingDotOpacity(2))
                .animation(typingDotAnimation(2), value: store.aiTyping || store.aiReplying)
        }
        .foregroundStyle(DS.Palette.accent)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.Palette.bubbleOther, in: Capsule())
    }

    private func typingDotOpacity(_ index: Int) -> Double {
        guard store.aiTyping || store.aiReplying else { return 0.55 }
        let phase = (Date().timeIntervalSinceReferenceDate * 3.4) + Double(index) * 0.35
        let value = (sin(phase) + 1) / 2
        return 0.35 + value * 0.65
    }

    private func typingDotAnimation(_ index: Int) -> Animation {
        .easeInOut(duration: 0.6 + Double(index) * 0.08).repeatForever(autoreverses: true)
    }

    // MARK: 杈撳叆鏍忥紙Telegram 寮忥細闄勪欢宓屽叆杈撳叆妗嗗唴锛屼笌琛ㄦ儏鎸夐挳瀵圭О锛涢害鍏嬮鎸変綇璇磋瘽锛?    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isRecording {
                recordingBar
            } else {
                if channel == .couple {
                    catButton
                }
                messageBox
            }
            micButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    // 鍗曞眰杈撳叆妗嗭細闄勪欢鎸夐挳宓屽湪宸︿晶锛岃〃鎯呮寜閽祵鍦ㄥ彸渚э紝瀵圭О甯冨眬锛屾暣浣撻珮搴︿笌涓や晶鍦嗗舰鎸夐挳瀵归綈
    private var messageBox: some View {
        HStack(alignment: .center, spacing: 8) {
            mediaPicker
            TextField("娑堟伅", text: $draft, axis: .vertical)
                .focused($inputFocused)
                .lineLimit(1...5)
                .font(.system(size: 17))
                .multilineTextAlignment(.leading)
            Button {
                Haptics.light()
                toggleStickerPanel()
            } label: {
                Image(systemName: showStickerPanel ? "keyboard" : "face.smiling")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(showStickerPanel ? DS.Palette.accent : DS.Palette.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, 13)
        .frame(minHeight: Self.composerButtonSize)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
    }

    private var mediaPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(mediaPreviewItems) { item in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Button {
                            withAnimation(DS.Anim.springFast) {
                                mediaPreviewItems.removeAll { $0.id == item.id }
                                selectedMediaItems.removeAll { $0 == item.item }
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DS.Palette.textSecondary.opacity(0.5))
                        }
                        .offset(x: 3, y: -3)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.top, 8)
        }
        .frame(height: 64)
    }

    // 褰曢煶涓細鏇挎崲杈撳叆妗嗭紝灞曠ず鏃堕暱 + 宸︽粦鍙栨秷鎻愮ず
    private var recordingBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(recordingPulse ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: recordingPulse)
            Text(recordingTimeLabel)
                .font(.system(size: 15, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("婊戝姩鍙栨秷")
                    .font(.system(size: 14))
            }
            .foregroundStyle(recordingCancelled ? .red : DS.Palette.textSecondary)
            .offset(x: min(0, dragTranslation * 0.4))
        }
        .padding(.horizontal, 16)
        .frame(height: Self.composerButtonSize)
        .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.bubble + 2, style: .continuous))
        .onAppear { recordingPulse = true }
        .onDisappear { recordingPulse = false }
    }

    private var recordingTimeLabel: String {
        let total = Int(recordingElapsed.rounded(.down))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // 娌℃枃瀛?鈫?鎸変綇璇磋瘽锛堢┖蹇冧富棰樿壊绾挎潯锛岃窡宸︿晶灏忕尗鎸夐挳瀵圭О鐨勭幓鐠冨簳锛夛紱
    // 鏈夋枃瀛?鈫?涓婚鑹插彂閫佹寜閽紱褰曢煶涓?鈫?瀹炲績鎻愮ず鎬?    private var micButton: some View {
        Group {
            if isRecording {
                Image(systemName: recordingCancelled ? "trash.fill" : "mic.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(recordingCancelled ? Color.red : DS.Palette.accent)
                    .clipShape(Circle())
                    .scaleEffect(recordingCancelled ? 1.12 : 1.0)
            } else if !mediaPreviewItems.isEmpty {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(DS.Palette.accent)
                    .clipShape(Circle())
            } else if draft.isEmpty {
                Image(systemName: "mic")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DS.Palette.accent)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .dsGlassInteractive(in: Circle())
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                    .background(DS.Palette.accent)
                    .clipShape(Circle())
            }
        }
        .animation(DS.Anim.springFast, value: draft.isEmpty)
        .animation(DS.Anim.springFast, value: isRecording)
        .animation(DS.Anim.springFast, value: recordingCancelled)
        .animation(DS.Anim.springFast, value: mediaPreviewItems.isEmpty)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard draft.isEmpty && mediaPreviewItems.isEmpty else { return }
                    if !isRecording {
                        beginRecording()
                    }
                    guard isRecording else { return }
                    dragTranslation = value.translation.width
                    let shouldCancel = dragTranslation < Self.cancelDragThreshold
                    if shouldCancel != recordingCancelled {
                        recordingCancelled = shouldCancel
                        Haptics.medium()
                    }
                }
                .onEnded { _ in
                    if !mediaPreviewItems.isEmpty {
                        sendMediaItems()
                        return
                    }
                    if !draft.isEmpty {
                        sendDraft()
                        return
                    }
                    guard isRecording else { return }
                    finishRecording(cancelled: recordingCancelled)
                }
        )
    }

    /// 灏忕尗鎸夐挳锛氫富棰樿壊绾挎€х尗澶达紝鐐逛竴涓嬪彫鍞ゅぇ姗?    private var catButton: some View {
        Button {
            summonDaju()
        } label: {
            CatHeadIcon()
                .stroke(DS.Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .frame(width: 23, height: 23)
                .frame(width: Self.composerButtonSize, height: Self.composerButtonSize)
                .dsGlassInteractive(in: Circle())
        }
        .buttonStyle(PressableStyle())
    }

    private var mediaPicker: some View {
        PhotosPicker(
            selection: $selectedMediaItems,
            maxSelectionCount: 9,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        ) {
            Image(systemName: mediaBusy ? "hourglass" : "paperclip")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(mediaBusy ? DS.Palette.textSecondary.opacity(0.6) : DS.Palette.textSecondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressableStyle())
        .disabled(mediaBusy)
    }

    // MARK: 褰曢煶锛圱elegram 寮忔寜浣忚璇濓細鎶墜鍙戦€侊紝宸︽粦鍙栨秷锛?
    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        recordingCancelled = false
        dragTranslation = 0
        recordingElapsed = 0
        Haptics.light()

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startRecorder()
        case .denied:
            isRecording = false
            showMicPermissionAlert = true
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                await MainActor.run {
                    guard isRecording else { return }
                    if granted {
                        startRecorder()
                    } else {
                        isRecording = false
                        showMicPermissionAlert = true
                    }
                }
            }
        @unknown default:
            isRecording = false
        }
    }

    private func startRecorder() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            isRecording = false
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            isRecording = false
            return
        }
        recorder.record()
        audioRecorder = recorder
        recordingURL = url
        recordingStartDate = Date()

        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                recordingElapsed = Date().timeIntervalSince(recordingStartDate ?? Date())
            }
        }
    }

    private func finishRecording(cancelled: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        let duration = recordingElapsed
        let url = recordingURL
        audioRecorder?.stop()
        audioRecorder = nil
        recordingURL = nil
        isRecording = false
        recordingCancelled = false
        dragTranslation = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard !cancelled, duration >= 1.0, let url else {
            if let url { try? FileManager.default.removeItem(at: url) }
            if !cancelled { Haptics.medium() }
            return
        }
        Haptics.light()
        sendVoice(url: url)
    }

    private func sendVoice(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        store.sendMedia(data: data, mimeType: "audio/m4a", preferredType: "voice", localPreviewURL: url, channel: channel)
    }

    /// 鐚尗鎸夐挳锛氬湪鍏叡鑱婂ぉ閲屽彫鍞ゅぇ姗橈紙鏈嶅姟绔瘑鍒?@澶ф 瑙﹀彂璇嶆墠浼氭彃璇濓級锛屼笉璺宠浆绉佽亰
    private func summonDaju() {
        Haptics.light()
        if !draft.contains("@澶ф") {
            draft = draft.isEmpty ? "@澶ф " : "@澶ф " + draft
        }
        inputFocused = true
    }

    private func toggleStickerPanel() {
        withAnimation(DS.Anim.springFast) {
            if showStickerPanel {
                showStickerPanel = false
            } else {
                inputFocused = false
                showStickerPanel = true
                showAttachmentTray = false
            }
        }
    }

    private func sendSticker(_ sticker: Sticker) {
        Haptics.light()
        store.sendSticker(url: sticker.url, channel: channel)
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Haptics.light()
        let target = replyTarget
        draft = ""
        replyTarget = nil
        let replyId = target?.id
        let previewText: String?
        if let target {
            previewText = replyPreview(for: target)
        } else {
            previewText = nil
        }
        store.sendText(text, channel: channel, replyTo: replyId, replyPreview: previewText)
    }

    private func replyPreview(for message: ChatMessage) -> String {
        let body: String
        switch message.type {
        case "sticker":
            body = "[琛ㄦ儏]"
        case "image":
            body = "[鍥剧墖]"
        case "video":
            body = "[瑙嗛]"
        case "file":
            body = "[鏂囦欢]"
        default:
            body = message.displayText
        }
        return "\(message.senderName): \(body)"
    }

    private func sendMedia(_ item: PhotosPickerItem) {
        mediaBusy = true
        Task {
            defer {
                Task { @MainActor in
                    mediaBusy = false
                    selectedMedia = nil
                }
            }

            guard let prepared = try? await prepareMedia(item) else {
                await MainActor.run { Haptics.medium() }
                return
            }

            await MainActor.run {
                Haptics.light()
                store.sendMedia(
                    data: prepared.data,
                    mimeType: prepared.mimeType,
                    preferredType: prepared.messageType,
                    localPreviewURL: nil,
                    channel: channel)
            }
        }
    }

    private func sendFile(_ url: URL) {
        mediaBusy = true
        Task {
            defer {
                Task { @MainActor in mediaBusy = false }
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            guard let data = try? Data(contentsOf: url) else {
                await MainActor.run { Haptics.medium() }
                return
            }
            let type = UTType(filenameExtension: url.pathExtension)
            let mimeType = type?.preferredMIMEType ?? "application/octet-stream"
            let name = url.lastPathComponent
            await MainActor.run {
                Haptics.light()
                store.sendMedia(
                    data: data,
                    mimeType: mimeType,
                    preferredType: "file",
                    localPreviewURL: nil,
                    channel: channel,
                    displayText: name)
            }
        }
    }

    private func loadMediaPreviewItems() {
        let items = selectedMediaItems
        guard !items.isEmpty else {
            withAnimation(DS.Anim.springFast) {
                mediaPreviewItems = []
            }
            return
        }

        mediaBusy = true
        Task {
            var previews: [MediaPreviewItem] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    continue
                }
                let id = UUID().uuidString
                previews.append(MediaPreviewItem(id: id, image: image, item: item))
            }

            await MainActor.run {
                withAnimation(DS.Anim.springFast) {
                    mediaPreviewItems = previews
                }
                mediaBusy = false
            }
        }
    }

    private func sendMediaItems() {
        let items = mediaPreviewItems
        guard !items.isEmpty else { return }

        mediaBusy = true
        withAnimation(DS.Anim.springFast) {
            mediaPreviewItems = []
            selectedMediaItems = []
        }

        Task {
            for item in items {
                guard let prepared = try? await prepareMedia(item.item) else {
                    continue
                }
                await MainActor.run {
                    Haptics.light()
                    store.sendMedia(
                        data: prepared.data,
                        mimeType: prepared.mimeType,
                        preferredType: prepared.messageType,
                        localPreviewURL: nil,
                        channel: channel)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            await MainActor.run {
                mediaBusy = false
            }
        }
    }


    private func prepareMedia(_ item: PhotosPickerItem) async throws -> PreparedMedia {
        let contentTypes = item.supportedContentTypes
        let isVideo = contentTypes.contains { $0.conforms(to: .movie) }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw NSError(domain: "media", code: 1)
        }

        if isVideo {
            let mimeType = contentTypes.contains(.quickTimeMovie) ? "video/quicktime" : "video/mp4"
            return PreparedMedia(data: data, mimeType: mimeType, messageType: "video")
        }

        if contentTypes.contains(.png) {
            return PreparedMedia(data: data, mimeType: "image/png", messageType: "image")
        }
        if contentTypes.contains(.gif) {
            return PreparedMedia(data: data, mimeType: "image/gif", messageType: "image")
        }
        if contentTypes.contains(.webP) {
            return PreparedMedia(data: data, mimeType: "image/webp", messageType: "image")
        }
        if contentTypes.contains(.jpeg) {
            return PreparedMedia(data: data, mimeType: "image/jpeg", messageType: "image")
        }

        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.86) else {
            throw NSError(domain: "media", code: 2)
        }
        return PreparedMedia(data: jpeg, mimeType: "image/jpeg", messageType: "image")
    }
}

private struct PreparedMedia {
    let data: Data
    let mimeType: String
    let messageType: String
}

private struct MediaPreviewItem: Identifiable {
    let id: String
    let image: UIImage
    let item: PhotosPickerItem
}

struct CatHeadIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        path.move(to: CGPoint(x: w * 0.24, y: h * 0.43))
        path.addLine(to: CGPoint(x: w * 0.20, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.39, y: h * 0.29))
        path.addQuadCurve(to: CGPoint(x: w * 0.61, y: h * 0.29), control: CGPoint(x: w * 0.50, y: h * 0.22))
        path.addLine(to: CGPoint(x: w * 0.80, y: h * 0.12))
        path.addLine(to: CGPoint(x: w * 0.76, y: h * 0.43))
        path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.86), control: CGPoint(x: w * 0.82, y: h * 0.74))
        path.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.43), control: CGPoint(x: w * 0.18, y: h * 0.74))

        path.move(to: CGPoint(x: w * 0.38, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.62, y: h * 0.50))
        path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.54))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.43, y: h * 0.67), control: CGPoint(x: w * 0.47, y: h * 0.64))
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.60))
        path.addQuadCurve(to: CGPoint(x: w * 0.57, y: h * 0.67), control: CGPoint(x: w * 0.53, y: h * 0.64))

        return path
    }
}

private func keyboardAnimation(from note: Notification) -> Animation {
    let info = note.userInfo ?? [:]
    let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
        ?? UIView.AnimationCurve.easeInOut.rawValue
    let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut

    guard duration > 0 else { return .linear(duration: 0.01) }

    switch curve {
    case .easeInOut:
        return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
    case .easeIn:
        return .timingCurve(0.42, 0, 1, 1, duration: duration)
    case .easeOut:
        return .timingCurve(0, 0, 0.58, 1, duration: duration)
    case .linear:
        return .linear(duration: duration)
    @unknown default:
        return .easeOut(duration: duration)
    }
}
