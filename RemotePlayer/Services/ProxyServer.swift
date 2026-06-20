//
//  ProxyServer.swift
//  RemotePlayer
//
//  本地 HTTP 代理服务器（基于 Telegraph）。
//
//  作用：VLCKit 需要一个 URL 才能播放，但 SMB 文件没有 URL。
//  本服务在 127.0.0.1 上监听，把 VLCKit 的 HTTP 请求（含 Range）
//  转换为对 SMBService 的字节范围读取，再以 HTTP 响应回写。
//
//  线程模型：
//  - ProxyServer 本身是 @MainActor（注册/注销在主线程）。
//  - Telegraph 路由闭包在 workerQueue（后台并发队列）调用。
//    handlers 字典用 NSLock 保护，路由闭包内可安全读取 handler 引用。
//  - handler.makeResponse 返回 StreamingHTTPResponse，其 provider
//    是 async 闭包，在 MainActor 上通过 SMBService 读取数据。
//

import Foundation
import Telegraph

/// 本地 HTTP 代理服务器。
@MainActor
final class ProxyServer: ObservableObject {

    /// 当前监听端口；启动前为 nil。
    @Published private(set) var port: UInt16?

    /// Telegraph 服务器实例。
    private let server = Server()

    /// 当前注册的流式处理器（按 token 索引）。
    /// 用锁保护，因为路由闭包在后台 workerQueue 访问。
    /// nonisolated(unsafe): 所有访问已通过 handlersLock 保护。
    private nonisolated(unsafe) var handlers: [String: StreamHandler] = [:]
    private let handlersLock = NSLock()

    init() {
        configureRoutes()
    }

    // MARK: - 生命周期

    /// 启动本地服务器（监听 127.0.0.1，系统分配端口）。
    func start() throws {
        guard port == nil else { return }
        try server.start(port: 0, interface: "localhost")
        self.port = UInt16(server.port)
    }

    /// 停止服务器并清理所有路由。
    func stop() {
        handlersLock.lock()
        handlers.values.forEach { $0.cancel() }
        handlers.removeAll()
        handlersLock.unlock()
        server.stop()
        port = nil
    }

    // MARK: - 路由注册

    /// 为一次播放注册一个流式路由。
    /// - Parameters:
    ///   - token: 唯一 token
    ///   - smbPath: SMB 文件完整路径
    ///   - totalSize: 文件总字节数
    ///   - smbService: 用于读取数据的 SMB 服务
    /// - Returns: 供 VLCKit 使用的完整本地 URL
    @discardableResult
    func registerStream(token: String,
                        smbPath: String,
                        totalSize: Int64,
                        smbService: SMBService) -> URL {
        let handler = StreamHandler(smbPath: smbPath,
                                    totalSize: totalSize,
                                    smbService: smbService)
        handlersLock.lock()
        handlers[token] = handler
        handlersLock.unlock()
        return streamURL(forToken: token)
    }

    /// 注销一个流式路由。
    func unregisterStream(token: String) {
        handlersLock.lock()
        handlers[token]?.cancel()
        handlers.removeValue(forKey: token)
        handlersLock.unlock()
    }

    /// 根据 token 返回本地 URL。
    func streamURL(forToken token: String) -> URL {
        let p = port ?? 0
        return URL(string: "http://127.0.0.1:\(p)/stream/\(token)")!
    }

    // MARK: - 路由配置

    /// 配置 Telegraph 路由。
    /// 闭包在 workerQueue（后台并发）调用，通过锁安全取 handler。
    private nonisolated func configureRoutes() {
        server.route(.GET, "/stream/:token") { [weak self] request -> HTTPResponse in
            guard let token = request.params["token"] else {
                return HTTPResponse(.notFound)
            }
            // 取出 handler 引用（handler 本身是 @MainActor class，
            // 但 makeResponse 内部访问的数据通过 provider 异步在 MainActor 执行，
            // 这里只做构造，不触碰 actor 隔离的可变状态）。
            // 由于路由闭包不是 MainActor 上下文，用锁获取引用。
            guard let handler = self?.lockedHandler(for: token) else {
                return HTTPResponse(.notFound)
            }
            return handler.makeResponse(for: request)
        }
    }

    /// 线程安全地取出 handler 引用。
    private nonisolated func lockedHandler(for token: String) -> StreamHandler? {
        handlersLock.lock()
        defer { handlersLock.unlock() }
        return handlers[token]
    }
}
