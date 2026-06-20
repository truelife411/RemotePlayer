//
//  SMBService.swift
//  RemotePlayer
//
//  AMSMB2 2.7.1 封装层。职责：
//  1. 建立 / 维持 SMB2/3 连接（init + connectShare）
//  2. 列目录（contentsOfDirectory → [[URLResourceKey]] 字典数组）
//  3. 读取文件属性（attributesOfItem）
//  4. 按字节范围流式读取（contents(atPath:offset:fetchedData:) 回调式，
//     桥接为 AsyncThrowingStream）—— 供本地 HTTP 代理喂给 VLCKit
//  5. 整文件读取（用于图片 / 字幕）
//
//  注意：AMSMB2 2.7.1 所有方法均为 completionHandler 回调式（无 async 重载），
//  本类用 withCheckedThrowingContinuation 桥接为 async/await。
//

import Foundation
import AMSMB2
import os

/// SMB 相关日志（可在 Console.app 用 subsystem=RemotePlayer 过滤）。
private enum SMBLogger {
    static let connect = Logger(subsystem: "RemotePlayer", category: "SMBConnect")
}

@MainActor
final class SMBService: ObservableObject {

    /// 当前连接状态。
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected

    /// AMSMB2 客户端实例；连接成功后赋值。
    private var client: AMSMB2?

    /// 当前已连接的服务器配置。
    private(set) var config: ServerConfig?

    // MARK: - 连接

    /// 连接到指定服务器的共享目录。
    func connect(_ config: ServerConfig) async throws {
        self.state = .connecting
        self.config = config

        guard let url = URL(string: "smb://\(config.host):\(config.port)"),
              let smb = AMSMB2(url: url, credential: makeCredential(for: config)) else {
            self.state = .failed("配置无效")
            throw AppError.invalidServerConfig(detail: "无法解析 SMB 地址")
        }

        // AMSMB2 2.7.1：connectShare 是回调式，桥接为 async
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                smb.connectShare(name: config.shareName, encrypted: false) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            self.state = .failed(error.localizedDescription)
            throw wrapConnectError(error, config: config)
        }

        self.client = smb
        self.state = .connected
    }

    /// 断开连接，释放资源。
    func disconnect() {
        client?.disconnectShare(gracefully: false)
        client = nil
        config = nil
        state = .disconnected
    }

    // MARK: - 目录列举

    /// 列出指定路径下的文件与目录。
    /// - Parameter path: 相对共享根的路径，根目录传 ""
    /// - Returns: SMBFile 列表（已转换为应用模型）
    func listDirectory(at path: String) async throws -> [SMBFile] {
        guard let client else { throw AppError.smbNotConnected }
        let entries: [[URLResourceKey: Any]]
        do {
            entries = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[[URLResourceKey: Any]], Error>) in
                client.contentsOfDirectory(atPath: path, recursive: false) { result in
                    switch result {
                    case .success(let val): continuation.resume(returning: val)
                    case .failure(let err): continuation.resume(throwing: err)
                    }
                }
            }
        } catch {
            throw AppError.smbListFailed(path: path, detail: error.localizedDescription)
        }
        return entries.map { convert(attrs: $0, parentPath: path) }
    }

    /// 获取单个文件的属性（大小 / 修改时间 / 是否目录）。
    func attributes(of path: String) async throws -> SMBFile {
        guard let client else { throw AppError.smbNotConnected }
        let attrs: [URLResourceKey: Any]
        do {
            attrs = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[URLResourceKey: Any], Error>) in
                client.attributesOfItem(atPath: path) { result in
                    switch result {
                    case .success(let val): continuation.resume(returning: val)
                    case .failure(let err): continuation.resume(throwing: err)
                    }
                }
            }
        } catch {
            throw AppError.smbListFailed(path: path, detail: error.localizedDescription)
        }
        return convert(attrs: attrs, parentPath: (path as NSString).deletingLastPathComponent)
    }

    // MARK: - 字节流式读取（供 HTTP 代理使用）

    /// 按字节范围读取文件，返回分块异步流。
    ///
    /// 这是"本地 HTTP 代理 → SMB"桥接的核心。
    /// AMSMB2 2.7 提供 `contents(atPath:offset:fetchedData:completionHandler:)` 回调式流读，
    /// `fetchedData` 闭包在 AMSMB2 内部队列逐块回调（返回 false 中止）。
    /// 这里桥接为 AsyncThrowingStream，避免 GB 级视频一次性读入内存。
    ///
    /// - Parameters:
    ///   - path: 文件完整路径
    ///   - offset: 起始字节偏移
    ///   - length: 读取长度；nil 表示读到文件末尾
    /// - Returns: 分块数据的异步流，逐块 yield
    func readFile(_ path: String,
                  offset: Int64,
                  length: Int64?) -> AsyncThrowingStream<Data, Error> {
        let client = self.client
        let limit = length ?? Int64.max

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let client else {
                    continuation.finish(throwing: AppError.smbNotConnected)
                    return
                }

                // 用原子标志位跟踪取消（Task.isCancelled 在 AMSMB2 回调队列上不可靠）
                let cancelled = OSAllocatedUnfairLock(initialState: false)
                continuation.onTermination = { @Sendable _ in
                    cancelled.withLock { $0 = true }
                }

                // 跟踪已发送字节数，在达到 length 后截断并停止
                var sent: Int64 = 0

                client.contents(
                    atPath: path,
                    offset: offset,
                    fetchedData: { _, _, data -> Bool in
                        // 1. 检查取消
                        if cancelled.withLock({ $0 }) { return false }

                        // 2. 检查是否已达到 length 上限
                        if sent >= limit { return false }

                        let remaining = limit - sent
                        if Int64(data.count) <= remaining {
                            // 整块都在范围内
                            continuation.yield(data)
                            sent += Int64(data.count)
                        } else {
                            // 最后一块需要截断
                            let truncated = data.prefix(Int(remaining))
                            continuation.yield(Data(truncated))
                            sent += Int64(truncated.count)
                            return false // 已读完所需长度
                        }
                        return true
                    },
                    completionHandler: { error in
                        if let error {
                            continuation.finish(throwing: AppError.smbReadFailed(
                                path: path, detail: error.localizedDescription))
                        } else {
                            continuation.finish()
                        }
                    }
                )
            }
        }
    }

    /// 读取整个小文件到内存（用于图片浏览、字幕文件）。
    func readEntireFile(_ path: String) async throws -> Data {
        guard let client else { throw AppError.smbNotConnected }
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                client.contents(atPath: path, range: Range<Int64>?.none, progress: nil) { result in
                    switch result {
                    case .success(let data): continuation.resume(returning: data)
                    case .failure(let err): continuation.resume(throwing: err)
                    }
                }
            }
        } catch {
            throw AppError.smbReadFailed(path: path, detail: error.localizedDescription)
        }
    }

    // MARK: - 查找同目录外挂字幕

    /// 在文件所在目录查找同名的 .srt / .ass 等外挂字幕。
    func findExternalSubtitle(for videoPath: String) async throws -> String? {
        let dir = (videoPath as NSString).deletingLastPathComponent
        let baseName = ((videoPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let subtitleExts = ["srt", "ass", "ssa", "sub", "vtt"]

        let entries = try await listDirectory(at: dir)
        for ext in subtitleExts {
            let candidate = baseName + "." + ext
            if let hit = entries.first(where: { $0.name.lowercased() == candidate.lowercased() }) {
                return hit.path
            }
        }
        return nil
    }

    // MARK: - 转换

    /// 将 AMSMB2 的属性字典转换为 SMBFile。
    private func convert(attrs: [URLResourceKey: Any], parentPath: String) -> SMBFile {
        let name = (attrs[.nameKey] as? String) ?? ""
        let fullPath = parentPath.isEmpty ? name : (parentPath + "/" + name)
        let ext = (name as NSString).pathExtension
        let isDir = (attrs[.isDirectoryKey] as? Bool) ?? false
        let size = (attrs[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
        let modified = attrs[.contentModificationDateKey] as? Date

        return SMBFile(
            id: fullPath,
            name: name,
            path: fullPath,
            isDirectory: isDir,
            size: size,
            modifiedDate: modified,
            kind: isDir ? .other : SMBFile.kind(for: ext),
            extension: ext
        )
    }

    // MARK: - 辅助

    /// 构造 AMSMB2 凭据。
    private func makeCredential(for config: ServerConfig) -> URLCredential {
        if config.isAnonymous {
            return URLCredential(user: "Guest", password: "", persistence: .forSession)
        }
        return URLCredential(user: config.username,
                             password: config.password,
                             persistence: .forSession)
    }

    /// 将 AMSMB2 错误转换为 AppError。
    /// 注意：保留底层错误描述（NTSTATUS / NTError），避免笼统的"认证失败"掩盖真实原因。
    private func wrapConnectError(_ error: Error, config: ServerConfig) -> AppError {
        // 把底层 NTStatus / NSError 原始信息记到日志，方便排查
        let raw = error.localizedDescription
        let nsError = (error as NSError)
        SMBLogger.connect.error("SMB connect failed: host=\(config.host, privacy: .public) share=\(config.shareName, privacy: .public) user=\(config.username, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code) desc=\(raw, privacy: .public)")

        let msg = raw.lowercased()
        if msg.contains("logon") || msg.contains("auth") || msg.contains("denied")
            || msg.contains("password") || msg.contains("nt_status_logon")
            || msg.contains("bad username") || msg.contains("ntlm") || msg.contains("nt_status_more_processing") {
            return .smbAuthFailed(detail: raw)
        }
        if msg.contains("unreachable") || msg.contains("timeout") || msg.contains("resolve") || msg.contains("connect") {
            return .networkUnreachable
        }
        return .smbConnectFailed(host: config.host, detail: raw)
    }
}
