//
//  PlaybackStore.swift
//  RemotePlayer
//
//  断点续播持久化存储。
//  以 [key: PlaybackProgress] 形式持久化到 UserDefaults。
//  key = "服务器ID|文件完整路径"，保证全局唯一。
//

import Foundation

/// 断点续播存储。线程安全的单例。
final class PlaybackStore {

    static let shared = PlaybackStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "com.remoteplayer.playbackProgress"
    private let lock = NSLock()

    private init() {}

    // MARK: - 读写

    /// 生成唯一 key。
    private func key(serverID: UUID, filePath: String) -> String {
        "\(serverID.uuidString)|\(filePath)"
    }

    /// 读取某文件的播放进度。
    func progress(for serverID: UUID, filePath: String) -> PlaybackProgress? {
        lock.lock()
        defer { lock.unlock() }
        return allProgress()[key(serverID: serverID, filePath: filePath)]
    }

    /// 更新播放进度（节流由调用方负责）。
    func update(serverID: UUID, filePath: String,
                position: Double, duration: Double, rate: Float) {
        lock.lock()
        defer { lock.unlock() }
        var dict = allProgress()
        let k = key(serverID: serverID, filePath: filePath)
        let progress = PlaybackProgress(
            key: k,
            position: position,
            duration: duration,
            updatedAt: Date(),
            rate: rate
        )
        dict[k] = progress
        save(dict)
    }

    /// 看完后清除进度。
    func clear(serverID: UUID, filePath: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = allProgress()
        dict.removeValue(forKey: key(serverID: serverID, filePath: filePath))
        save(dict)
    }

    /// 清除某台服务器所有进度。
    func clearAll(for serverID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var dict = allProgress()
        let prefix = serverID.uuidString + "|"
        dict = dict.filter { !$0.key.hasPrefix(prefix) }
        save(dict)
    }

    // MARK: - 持久化

    private func allProgress() -> [String: PlaybackProgress] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PlaybackProgress].self, from: data)) ?? [:]
    }

    private func save(_ dict: [String: PlaybackProgress]) {
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
