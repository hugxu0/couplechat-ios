import Foundation

@MainActor
final class MomentsViewModel: ObservableObject {
    static let albumsChanged = Notification.Name("v2AlbumsChanged")
    @Published private(set) var albums: [MomentAlbum] = []
    @Published private(set) var onThisDay: [OnThisDayMoment] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var errorMessage: String?

    private let repository: MomentsRepository
    private var nextCursor: String?
    private var loaded = false

    init(repository: MomentsRepository = MomentsRepository()) {
        self.repository = repository
    }

    func load(token: String, force: Bool = false) async {
        guard !loading, force || !loaded else { return }
        loading = true
        errorMessage = nil
        do {
            async let albumPage = repository.albums(token: token)
            async let memories = repository.onThisDay(token: token)
            let (page, moments) = try await (albumPage, memories)
            albums = page.values
            onThisDay = moments
            nextCursor = page.nextCursor
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func loadMoreIfNeeded(album: MomentAlbum, token: String) async {
        guard albums.last?.id == album.id,
              let cursor = nextCursor,
              !loadingMore else { return }
        loadingMore = true
        do {
            let page = try await repository.albums(cursor: cursor, token: token)
            albums.append(contentsOf: page.values.filter { value in
                !albums.contains(where: { $0.id == value.id })
            })
            nextCursor = page.nextCursor
        } catch {
            errorMessage = error.localizedDescription
        }
        loadingMore = false
    }

    func createAlbum(title: String, note: String?, token: String) async -> Bool {
        do {
            let album = try await repository.createAlbum(title: title, note: note, token: token)
            albums.insert(album, at: 0)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@MainActor
final class AlbumDetailViewModel: ObservableObject {
    @Published private(set) var album: MomentAlbum
    @Published private(set) var assets: [MomentAsset] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    @Published var errorMessage: String?

    private let repository: MomentsRepository
    private var nextCursor: String?
    private var loaded = false

    init(album: MomentAlbum, repository: MomentsRepository = MomentsRepository()) {
        self.album = album
        self.repository = repository
    }

    func load(token: String, force: Bool = false) async {
        guard !loading, force || !loaded else { return }
        loading = true
        do {
            let result = try await repository.album(id: album.id, token: token)
            album = result.0
            assets = result.1.values
            nextCursor = result.1.nextCursor
            loaded = true
        } catch V2RepositoryError.albumConflict(let current) {
            album = current
            errorMessage = V2RepositoryError.albumConflict(current).localizedDescription
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func loadMoreIfNeeded(asset: MomentAsset, token: String) async {
        guard assets.last?.id == asset.id,
              let cursor = nextCursor,
              !loadingMore else { return }
        loadingMore = true
        do {
            let result = try await repository.album(id: album.id, cursor: cursor, token: token)
            assets.append(contentsOf: result.1.values.filter { value in
                !assets.contains(where: { $0.id == value.id })
            })
            nextCursor = result.1.nextCursor
        } catch V2RepositoryError.albumConflict(let current) {
            album = current
            errorMessage = V2RepositoryError.albumConflict(current).localizedDescription
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
        loadingMore = false
    }

    func updateCaption(asset: MomentAsset, caption: String?, token: String) async -> Bool {
        do {
            let note = try await repository.updateCaption(
                assetId: asset.id,
                text: caption ?? "",
                baseVersion: asset.noteVersion,
                token: token)
            if let index = assets.firstIndex(where: { $0.id == asset.id }) {
                assets[index].caption = note.text
                assets[index].noteVersion = note.version
            }
            return true
        } catch V2RepositoryError.server(let code) where code == 409 {
            await load(token: token, force: true)
            errorMessage = "注脚已在另一台设备更新，已载入最新版本"
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateCaption(assets postAssets: [MomentAsset], caption: String?, token: String) async -> Bool {
        var succeeded = true
        for asset in postAssets {
            if !(await updateCaption(asset: asset, caption: caption, token: token)) {
                succeeded = false
                break
            }
        }
        if !succeeded { await load(token: token, force: true) }
        return succeeded
    }

    func addUpload(uploadId: String, takenAt: Int, postId: String, token: String) async -> [MomentAsset] {
        do {
            let added = try await repository.addUpload(
                albumId: album.id, uploadId: uploadId, takenAt: takenAt,
                postId: postId, token: token)
            for asset in added.reversed() where !assets.contains(where: { $0.id == asset.id }) {
                assets.insert(asset, at: 0)
                album.itemCount += 1
            }
            if !added.isEmpty {
                album.version += 1
                NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
            }
            return added
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func updateAlbum(title: String, summary: String, token: String) async -> Bool {
        do {
            album = try await repository.updateAlbum(
                album, title: title, summary: summary, token: token)
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
            return true
        } catch V2RepositoryError.albumConflict(let current) {
            album = current
            errorMessage = V2RepositoryError.albumConflict(current).localizedDescription
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ asset: MomentAsset, token: String) async {
        guard let itemId = asset.albumItemId else {
            errorMessage = "这项内容缺少相册条目标识"
            return
        }
        do {
            try await repository.removeItem(albumId: album.id, itemId: itemId, token: token)
            assets.removeAll { $0.albumItemId == itemId }
            album.itemCount = max(0, album.itemCount - 1)
            album.version += 1
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(assets postAssets: [MomentAsset], token: String) async {
        for asset in postAssets { await remove(asset, token: token) }
    }

    func deleteAlbum(token: String) async -> Bool {
        do {
            try await repository.deleteAlbum(album, token: token)
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
            return true
        } catch V2RepositoryError.albumConflict(let current) {
            album = current
            errorMessage = V2RepositoryError.albumConflict(current).localizedDescription
            NotificationCenter.default.post(name: MomentsViewModel.albumsChanged, object: nil)
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
