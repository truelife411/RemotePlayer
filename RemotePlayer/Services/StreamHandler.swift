//
//  StreamHandler.swift
//  RemotePlayer
//
//  处理 VLCKit 发来的单个 HTTP 流式请求。
//
//  职责：
//  1. 解析 Range 头（"bytes=0-1023"、"bytes=1024-"、"bytes=-1023"）
//  2. 构造 StreamingHTTPResponse（200 全量 / 206 Partial Content）
//  3. 设置 Accept-Ranges: bytes，支持 VLCKit 拖拽进度条
//
//  数据读取：通过 SMBService.readFile 按字节范围拉取，
//  在 StreamingHTTPResponse 的 async provider 中逐块回调写入。
//
//  线程模型：
//  - makeResponse 在 Telegraph workerQueue（后台）调用，只做构造，不触碰可变状态。
//  - provider 是 async 闭包，读取 SMBService 时自动 hop 到其隔离域。
//

import Foundation
import Telegraph

/// 单个文件流式处理器。
/// 不标记 @MainActor：构造和 makeResponse 可在任意线程；
/// 实际 SMB 读取在 provider 的 async 闭包中，会 hop 到 SMBService 的隔离域。
final class StreamHandler {

    let smbPath: String
    let totalSize: Int64
    private let smbService: SMBService

    /// 是否已取消（线程安全）。
    private let cancelLock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return _isCancelled
    }

    init(smbPath: String, totalSize: Int64, smbService: SMBService) {
        self.smbPath = smbPath
        self.totalSize = totalSize
        self.smbService = smbService
    }

    func cancel() {
        cancelLock.lock()
        _isCancelled = true
        cancelLock.unlock()
    }

    // MARK: - 构造响应

    /// 根据请求构造流式响应。
    /// 在 Telegraph workerQueue（后台）中调用，只做无副作用构造。
    func makeResponse(for request: HTTPRequest) -> HTTPResponse {
        let range = Self.parseRange(request.headers["Range"], totalSize: totalSize)

        let status: HTTPStatus
        let contentLength: Int64
        let startByte: Int64
        let endByte: Int64

        if let range {
            status = .partialContent
            startByte = range.lowerBound
            endByte = min(range.upperBound - 1, totalSize - 1)
            contentLength = endByte - startByte + 1
        } else {
            status = .ok
            startByte = 0
            endByte = totalSize - 1
            contentLength = totalSize
        }

        // Range 不合法
        if contentLength <= 0 || startByte >= totalSize {
            let resp = HTTPResponse(.rangeNotSatisfiable)
            resp.headers["Content-Range"] = "bytes */\(totalSize)"
            return resp
        }

        // 构造流式响应：provider 是 async 闭包，逐块从 SMB 读取并写入 stream。
        // smbService 是 @MainActor，readFile 返回 AsyncThrowingStream，
        // 在 provider 的 async 上下文中消费。
        let smbService = self.smbService
        let smbPath = self.smbPath
        let cancelCheck = { [weak self] () -> Bool in self?.isCancelled ?? true }
        let provider: ChunkDataProvider = { write in
            // 取得分块流（readFile 内部会 hop 到 MainActor 拉取数据）
            let stream = await smbService.readFile(smbPath, offset: startByte, length: contentLength)
            do {
                for try await chunk in stream {
                    if cancelCheck() { break }
                    write(chunk)
                }
            } catch {
                // 读取出错：结束 provider。
                // 已写入部分会被 VLCKit 视为截断，它会重发 Range 请求（触发重连）。
            }
        }

        let streamResp = StreamingHTTPResponse(
            status: status,
            contentLength: contentLength,
            startByte: startByte,
            endByte: endByte,
            totalSize: totalSize,
            provider: provider
        )

        // MIME：VLC 对 octet-stream 兼容良好
        streamResp.headers["Content-Type"] = "application/octet-stream"
        streamResp.headers["Accept-Ranges"] = "bytes"
        // 强制关闭连接：异步 body 写入与 keep-alive 复用不兼容，
        // 关闭连接让 VLCKit 对每个 Range 请求建立新连接。
        streamResp.headers["Connection"] = "close"
        if status == .partialContent {
            streamResp.headers["Content-Range"] = "bytes \(startByte)-\(endByte)/\(totalSize)"
        }
        return streamResp
    }

    // MARK: - Range 解析

    /// 解析 HTTP Range 头。
    /// 支持："bytes=0-1023"、"bytes=1024-"、"bytes=-1023"（末尾 N 字节）。
    /// 返回半开区间 Range<Int64>；nil 表示无 Range 头。
    static func parseRange(_ header: String?, totalSize: Int64) -> Range<Int64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let raw = String(header.dropFirst("bytes=".count))
        guard let dash = raw.firstIndex(of: "-") else { return nil }
        let leftStr = String(raw[..<dash]).trimmingCharacters(in: .whitespaces)
        let rightStr = String(raw[raw.index(after: dash)...]).trimmingCharacters(in: .whitespaces)

        let left = Int64(leftStr)
        let right = Int64(rightStr)

        if let left, right == nil {
            // bytes=1024-    从 1024 到末尾
            return left..<totalSize
        } else if left == nil, let right {
            // bytes=-1023   末尾 1023 字节
            let start = max(0, totalSize - right)
            return start..<totalSize
        } else if let left, let right {
            // bytes=0-1023
            return left..<(right + 1)
        }
        return nil
    }
}
