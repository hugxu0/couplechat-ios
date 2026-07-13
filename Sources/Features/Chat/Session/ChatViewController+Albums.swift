import UIKit

extension ChatViewController {
    func presentAlbumPicker(for message: ChatMessage) {
        guard let token = store.session?.token else { return }
        Task { [weak self] in
            do {
                let page = try await MomentsRepository().albums(limit: 50, token: token)
                guard let self else { return }
                if page.values.isEmpty {
                    presentAlbumMessage(
                        title: "还没有共同相册",
                        message: "请先到“时光”新建相册，再回来收藏这条媒体。")
                } else {
                    presentAlbumActions(page.values, message: message, token: token)
                }
            } catch {
                self?.presentAlbumMessage(title: "无法读取相册", message: error.localizedDescription)
            }
        }
    }

    private func presentAlbumActions(_ albums: [MomentAlbum], message: ChatMessage, token: String) {
        let sheet = UIAlertController(title: "加入共同相册", message: "选择这段时光要去的地方", preferredStyle: .actionSheet)
        for album in albums.prefix(12) {
            sheet.addAction(UIAlertAction(title: album.title, style: .default) { [weak self] _ in
                self?.add(message: message, to: album, token: token)
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func add(message: ChatMessage, to album: MomentAlbum, token: String) {
        Task { [weak self] in
            do {
                _ = try await MomentsRepository().addMessage(
                    albumId: album.id, messageId: message.id, token: token)
                NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
                self?.presentAlbumMessage(title: "已加入“\(album.title)”", message: "可以在时光页补上一句共同注脚。")
            } catch {
                self?.presentAlbumMessage(title: "加入失败", message: error.localizedDescription)
            }
        }
    }

    private func presentAlbumMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
