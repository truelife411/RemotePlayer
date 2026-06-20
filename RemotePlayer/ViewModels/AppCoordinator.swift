//
//  AppCoordinator.swift
//  RemotePlayer
//
//  全局应用协调器。
//  负责管理：
//  - 单例 SMBService（当前连接）
//  - 单例 ProxyServer（本地 HTTP 代理）
//  - 连接 / 断开生命周期
//  - 全局错误状态
//
//  作为 @Observable 在 App 根部注入环境，供各页面共享。
//

import SwiftUI

/// 应用全局状态协调器。
@MainActor
@Observable
final class AppCoordinator {

    // MARK: - 共享服务

    /// 当前 SMB 服务实例（每次连接复用）。
    let smbService = SMBService()
    /// 本地 HTTP 代理。
    let proxyServer = ProxyServer()

    // MARK: - 状态

    /// 当前已连接的服务器配置。
    private(set) var connectedServer: ServerConfig?

    /// 全局错误（用于弹窗）。
    var lastError: AppError?

    /// 是否正在连接（镜像 SMBService 状态，供 @Observable 追踪）。
    private(set) var isConnecting = false

    /// 是否已连接。
    var isConnected: Bool { connectedServer != nil }

    // MARK: - 连接管理

    /// 连接到指定服务器。
    @discardableResult
    func connect(to config: ServerConfig) async -> Bool {
        isConnecting = true
        defer { isConnecting = false }
        do {
            try await smbService.connect(config)
            connectedServer = config
            ServerStore.shared.markConnected(id: config.id)
            // 启动本地代理（按需）
            if proxyServer.port == nil {
                try proxyServer.start()
            }
            return true
        } catch let error as AppError {
            lastError = error
            connectedServer = nil
            return false
        } catch {
            lastError = .unknown(detail: error.localizedDescription)
            connectedServer = nil
            return false
        }
    }

    /// 断开当前连接。
    func disconnect() {
        smbService.disconnect()
        connectedServer = nil
        // 代理随连接结束停止（释放端口）
        proxyServer.stop()
    }

    /// 清除错误。
    func clearError() {
        lastError = nil
    }
}
