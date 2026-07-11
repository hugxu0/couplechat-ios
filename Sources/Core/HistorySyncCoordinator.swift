import Combine
import Foundation

/// 拥有存储页长任务的 App 级协调器。
/// 页面离开只会停止观察，不会取消同步；只有显式暂停、登出或账号切换才取消。
@MainActor
final class HistorySyncCoordinator: ObservableObject {
    struct HistoryResult: Equatable {
        let remoteTotal: Int?
        let downloaded: Int
        let error: String?
    }

    struct ImageResult: Equatable {
        let total: Int
        let completed: Int
        let failed: Int

        var succeeded: Int { completed - failed }
    }

    enum Operation: Equatable {
        case idle
        case history(name: String, current: Int, total: Int?)
        case images(done: Int, total: Int, failed: Int)

        var isRunning: Bool { self != .idle }
    }

    enum Outcome: Equatable {
        case none
        case paused(String)
        case completed(String)
        case failed(String)

        var text: String? {
            switch self {
            case .none: return nil
            case .paused(let text), .completed(let text), .failed(let text): return text
            }
        }

        var isError: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    typealias HistoryWorker = (
        _ channel: ChatChannel,
        _ onProgress: @escaping (_ current: Int, _ total: Int?) -> Void
    ) async -> HistoryResult
    typealias ImageWorker = (
        _ onProgress: @escaping (_ completed: Int, _ total: Int, _ failed: Int) -> Void
    ) async -> ImageResult

    @Published private(set) var operation: Operation = .idle
    @Published private(set) var outcome: Outcome = .none
    @Published private(set) var remoteCounts: [String: Int] = [:]

    private let isLoggedIn: () -> Bool
    private let historyWorker: HistoryWorker
    private let imageWorker: ImageWorker
    private var operationTask: Task<Void, Never>?
    private var activeToken = UUID()

    init(
        isLoggedIn: @escaping () -> Bool,
        historyWorker: @escaping HistoryWorker,
        imageWorker: @escaping ImageWorker
    ) {
        self.isLoggedIn = isLoggedIn
        self.historyWorker = historyWorker
        self.imageWorker = imageWorker
    }

    func startHistorySync() {
        guard operationTask == nil else { return }
        guard isLoggedIn() else {
            outcome = .failed("当前未登录")
            return
        }
        outcome = .none
        let token = UUID()
        activeToken = token
        operation = .history(name: "两人聊天", current: 0, total: nil)
        operationTask = Task { [weak self] in
            await self?.runHistorySync(token: token)
        }
    }

    func startImageCaching() {
        guard operationTask == nil else { return }
        guard isLoggedIn() else {
            outcome = .failed("当前未登录")
            return
        }
        outcome = .none
        let token = UUID()
        activeToken = token
        operation = .images(done: 0, total: 0, failed: 0)
        operationTask = Task { [weak self] in
            await self?.runImageCaching(token: token)
        }
    }

    func pause() {
        guard let operationTask else { return }
        let pausedOperation = operation
        activeToken = UUID()
        operationTask.cancel()
        self.operationTask = nil
        operation = .idle
        switch pausedOperation {
        case .images:
            outcome = .paused("图片下载已暂停，下次会继续处理未缓存项目")
        case .history:
            outcome = .paused("同步已暂停，下次会从当前位置继续")
        case .idle:
            outcome = .none
        }
    }

    func cancelForLogout() {
        activeToken = UUID()
        operationTask?.cancel()
        operationTask = nil
        operation = .idle
        outcome = .none
        remoteCounts = [:]
    }

    func resetHistoryCounts() {
        remoteCounts = [:]
        outcome = .none
    }

    func showNotice(_ text: String) {
        guard operationTask == nil else { return }
        outcome = .completed(text)
    }

    private func runHistorySync(token: UUID) async {
        var downloaded = 0
        var errors: [String] = []
        let channels: [(ChatChannel, String)] = [(.couple, "两人聊天"), (.ai, "大橘聊天")]

        for (channel, name) in channels {
            guard isActive(token) else { return }
            let result = await historyWorker(channel) { [weak self] current, total in
                guard let self, self.isActive(token) else { return }
                self.operation = .history(name: name, current: current, total: total)
                if let total { self.remoteCounts[channel.rawValue] = total }
            }
            guard isActive(token) else { return }
            downloaded += result.downloaded
            if let total = result.remoteTotal { remoteCounts[channel.rawValue] = total }
            if let error = result.error, error != "同步已暂停" {
                errors.append("\(name)：\(error)")
            }
        }

        guard isActive(token) else { return }
        operationTask = nil
        operation = .idle
        if errors.isEmpty {
            outcome = .completed(
                downloaded > 0 ? "同步完成，本次新增 \(downloaded) 条消息" : "本地聊天记录已是最新")
        } else {
            outcome = .failed(errors.joined(separator: "；"))
        }
    }

    private func runImageCaching(token: UUID) async {
        let result = await imageWorker { [weak self] done, total, failed in
            guard let self, self.isActive(token) else { return }
            self.operation = .images(done: done, total: total, failed: failed)
        }
        guard isActive(token) else { return }
        operationTask = nil
        operation = .idle
        if result.failed == 0 {
            outcome = .completed(
                result.total == 0 ? "当前没有需要下载的聊天图片" : "\(result.succeeded) 张图片已保存在本地")
        } else {
            outcome = .failed("已保存 \(result.succeeded) 张，\(result.failed) 张下载失败，可稍后重试")
        }
    }

    private func isActive(_ token: UUID) -> Bool {
        activeToken == token && !Task.isCancelled
    }
}
