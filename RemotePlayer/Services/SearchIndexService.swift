//
//  SearchIndexService.swift
//  RemotePlayer
//
//  全目录搜索索引（支持断点续做）。
//
//  连接服务器后按需构建：BFS 遍历整个共享，每扫完一个目录存盘一次。
//  下次进入搜索页自动从断点继续，不重扫已完成部分。
//  切换服务器各存各的（按 serverID 区分）。
//

import Foundation

// MARK: - 索引状态

@MainActor
@Observable
final class SearchIndexService {

    enum IndexState: Equatable {
        case idle
        case indexing(fileCount: Int, dirCount: Int)
        case ready(fileCount: Int)
        case failed(String)
    }

    private(set) var state: IndexState = .idle
    private(set) var files: [SMBFile] = []

    private var indexTask: Task<Void, Never>?
    /// 当前正在为哪个服务器建索引。reset() 时会清空，旧 Task 检测到不匹配立即退出。
    private var buildingServerID: String?

    // MARK: - Checkpoint（断点续做）

    private struct Checkpoint: Codable {
        let files: [SMBFile]
        let pendingDirs: [String]
        let serverID: String
        let scannedDirs: Int
    }

    private static func checkpointURL(for serverID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("search_index", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(serverID).checkpoint")
    }

    private func saveCheckpoint(serverID: String, pendingDirs: [String], scannedDirs: Int) {
        let cp = Checkpoint(files: files, pendingDirs: pendingDirs,
                            serverID: serverID, scannedDirs: scannedDirs)
        if let data = try? JSONEncoder().encode(cp) {
            try? data.write(to: Self.checkpointURL(for: serverID), options: .atomic)
        }
    }

    private func loadCheckpoint(serverID: String) -> Checkpoint? {
        let url = Self.checkpointURL(for: serverID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 兼容旧格式 checkpoint（无 scannedDirs 字段）
        if let cp = try? JSONDecoder().decode(Checkpoint.self, from: data) {
            return cp
        }
        // 旧格式解码失败 → 删掉重建
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    private func deleteCheckpoint(serverID: String) {
        try? FileManager.default.removeItem(at: Self.checkpointURL(for: serverID))
    }

    // MARK: - 构建

    /// 启动后台 BFS 遍历。支持断点续做：如果已有该服务器的 checkpoint，加载并从断点继续。
    func startBuilding(smbService: SMBService, serverID: String) {
        cancel()
        files = []
        buildingServerID = serverID

        // 检查是否有断点
        if let cp = loadCheckpoint(serverID: serverID), !cp.pendingDirs.isEmpty {
            files = cp.files
            state = .indexing(fileCount: files.count, dirCount: cp.scannedDirs)
            indexTask = Task { [weak self] in
                await self?.buildIndex(smbService: smbService,
                                       serverID: serverID,
                                       queue: cp.pendingDirs,
                                       scannedDirs: cp.scannedDirs)
            }
        } else {
            // 新构建：从根开始
            state = .indexing(fileCount: 0, dirCount: 0)
            indexTask = Task { [weak self] in
                await self?.buildIndex(smbService: smbService,
                                       serverID: serverID,
                                       queue: [""],
                                       scannedDirs: 0)
            }
        }
    }

    private func buildIndex(smbService: SMBService,
                             serverID: String,
                             queue: [String],
                             scannedDirs: Int) async {
        var q = queue
        var scanned = scannedDirs

        while !q.isEmpty {
            if Task.isCancelled { return }
            // 服务器已切换（reset 清掉了 buildingServerID），立即退出
            if buildingServerID != serverID { return }

            let dir = q.removeFirst()
            let entries: [SMBFile]
            do {
                entries = try await smbService.listDirectory(at: dir)
            } catch {
                continue
            }

            for entry in entries {
                if entry.isDirectory {
                    q.append(entry.path)
                    scanned += 1
                } else {
                    files.append(entry)
                }
            }

            state = .indexing(fileCount: files.count, dirCount: scanned)

            // 每扫完一个目录存一次 checkpoint
            saveCheckpoint(serverID: serverID, pendingDirs: q, scannedDirs: scanned)
        }

        // 构建完成
        saveCheckpoint(serverID: serverID, pendingDirs: [], scannedDirs: scanned)
        state = .ready(fileCount: files.count)
        if buildingServerID == serverID {
            buildingServerID = nil
        }
    }

    // MARK: - 搜索

    func search(keyword: String) -> [SMBFile] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return [] }
        return files
            .filter { $0.name.localizedCaseInsensitiveContains(kw) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .prefix(200)
            .map { $0 }
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    var isIndexing: Bool {
        if case .indexing = state { return true }
        return false
    }

    // MARK: - 取消 / 清空

    /// 停止索引构建，保留 checkpoint 供续做。
    /// 注意：不清理 buildingServerID——旧 Task 用它判断是否被切换。
    func cancel() {
        indexTask?.cancel()
        indexTask = nil
    }

    /// 强制清空（切换服务器或手动重建时）。删 checkpoint + 清内存。
    func reset(serverID: String? = nil) {
        cancel()
        files = []
        state = .idle
        buildingServerID = nil
        if let sid = serverID {
            deleteCheckpoint(serverID: sid)
        }
    }
}
