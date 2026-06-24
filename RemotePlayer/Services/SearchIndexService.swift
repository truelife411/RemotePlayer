//
//  SearchIndexService.swift
//  RemotePlayer
//
//  全目录搜索索引（内存缓存）。
//
//  连接服务器后后台 BFS 遍历整个共享，把所有文件信息收进内存数组，
//  搜索时直接在内存里过滤，不再走网络。
//
//  为什么不用 AMSMB2 的 recursive: true？
//  - 它是串行阻塞遍历，无进度回调，几万文件卡几分钟且无法增量查询。
//  - 这里自建 BFS 迭代式遍历：基于现有非递归 listDirectory(at:)，逐层扫描，
//    边扫边塞索引，边更新进度，支持中途取消和增量查询。
//
//  生命周期：内存缓存，断开连接即失效（cancel 清空）。
//

import Foundation

@MainActor
@Observable
final class SearchIndexService {

    /// 索引构建状态。
    enum IndexState: Equatable {
        case idle
        /// 正在构建，已扫描 fileCount 个文件。
        case indexing(fileCount: Int, dirCount: Int)
        /// 构建完成。
        case ready(fileCount: Int)
        /// 构建失败（网络中断等），搜索结果可能不全。
        case failed(String)
    }

    /// 当前状态（供 UI 观察进度）。
    private(set) var state: IndexState = .idle

    /// 索引数据：所有文件（不含目录）。
    private(set) var files: [SMBFile] = []

    /// 后台构建任务，便于取消。
    private var indexTask: Task<Void, Never>?

    // MARK: - 构建

    /// 启动后台 BFS 遍历，构建全共享文件索引。
    /// - 复用共享的 smbService（@MainActor），不新建连接。
    /// - 每次调用先 cancel 旧的索引任务。
    func startBuilding(smbService: SMBService) {
        // 取消旧任务，清空旧数据
        cancel()
        files = []

        indexTask = Task { [weak self] in
            await self?.buildIndex(smbService: smbService)
        }
    }

    private func buildIndex(smbService: SMBService) async {
        // BFS 队列：从共享根开始
        var queue: [String] = [""]
        var scannedFiles = 0
        var scannedDirs = 0

        while !queue.isEmpty {
            if Task.isCancelled { return }

            // 取队首目录（BFS：广度优先，优先展平浅层，让搜索尽早有结果）
            let dir = queue.removeFirst()

            let entries: [SMBFile]
            do {
                entries = try await smbService.listDirectory(at: dir)
            } catch {
                // 单个目录读取失败不中断整体，继续扫其他目录
                continue
            }

            for entry in entries {
                if entry.isDirectory {
                    scannedDirs += 1
                    queue.append(entry.path)
                } else {
                    files.append(entry)
                    scannedFiles += 1
                }
            }

            // 每扫完一个目录更新一次进度
            state = .indexing(fileCount: scannedFiles, dirCount: scannedDirs)
        }

        // 构建完成
        state = .ready(fileCount: scannedFiles)
    }

    // MARK: - 搜索

    /// 在索引中搜索文件名匹配的文件。
    /// - 几万条的 name.contains 过滤是毫秒级。
    /// - 限制返回前 200 条，防极端情况 UI 卡顿。
    func search(keyword: String) -> [SMBFile] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return [] }
        let results = files.filter {
            $0.name.localizedCaseInsensitiveContains(kw)
        }
        // 按名字排序，限制数量
        return results
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(200)
            .map { $0 }
    }

    /// 当前是否已就绪（构建完成，可全量搜索）。
    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// 当前是否正在构建（可搜已扫部分）。
    var isIndexing: Bool {
        if case .indexing = state { return true }
        return false
    }

    // MARK: - 取消

    /// 取消索引构建，清空数据，状态回 idle。
    func cancel() {
        indexTask?.cancel()
        indexTask = nil
        files = []
        state = .idle
    }
}
