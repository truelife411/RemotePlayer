//
//  ServerStore.swift
//  RemotePlayer
//
//  服务器配置的持久化存储（UserDefaults）。
//  线程安全，可作为 @Observable 的数据源。
//

import Foundation

/// 服务器配置存储。
@MainActor
final class ServerStore {

    static let shared = ServerStore()

    private let defaults = UserDefaults.standard
    private let storageKey = "com.remoteplayer.servers"

    private init() {}

    /// 加载所有服务器配置（按最后连接时间降序）。
    func loadAll() -> [ServerConfig] {
        guard let data = defaults.data(forKey: storageKey),
              let servers = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return []
        }
        return servers.sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
    }

    /// 保存整个列表。
    private func save(_ servers: [ServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// 新增或更新（按 id 覆盖）。
    func upsert(_ config: ServerConfig) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == config.id }) {
            all[idx] = config
        } else {
            all.append(config)
        }
        save(all)
    }

    /// 删除。
    func delete(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        save(all)
    }

    /// 标记某服务器最后连接时间。
    func markConnected(id: UUID, at date: Date = Date()) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == id }) {
            all[idx].lastConnectedAt = date
            save(all)
        }
    }
}
