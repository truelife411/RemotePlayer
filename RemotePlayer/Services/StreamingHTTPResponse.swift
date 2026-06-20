//
//  StreamingHTTPResponse.swift
//  RemotePlayer
//
//  自定义 Telegraph HTTPResponse，支持大文件分块流式写入。
//
//  背景：Telegraph 的 HTTPResponse.body 是一次性 Data，
//  无法承载数 GB 的视频。本类重写 writeHeader / writeBody
//  （二者均为 HTTPMessage 的 open func，可重写），使其：
//  - writeHeader：写状态行与头部（同步），并启动一个后台 Task
//    异步从数据源拉取分块写入 socket 流（GCDAsyncSocket 线程安全）。
//  - writeBody：空实现（body 由上述 Task 异步推送，不阻塞 socket 队列）。
//
//  注意：HTTPMessage.write(to:headerTimeout:bodyTimeout:) 是 public 非 open，
//  不可重写；但它会依次调用 open 的 writeHeader / writeBody，因此重写这两个即可。
//

import Foundation
import Telegraph

/// 提供分块数据的闭包。
/// - Parameter write: 写入一块数据到 socket。
typealias ChunkDataProvider = (_ write: @escaping (Data) -> Void) async -> Void

final class StreamingHTTPResponse: HTTPResponse {

    /// 流式数据提供者。
    private let provider: ChunkDataProvider

    /// 初始化流式响应。
    /// - Parameters:
    ///   - status: HTTP 状态码
    ///   - contentLength: Content-Length 头的值
    ///   - startByte/endByte/totalSize: 仅用于构造 Content-Range（由 headers 显式设置）
    ///   - provider: 分块数据提供闭包
    init(status: HTTPStatus,
         contentLength: Int64,
         startByte: Int64,
         endByte: Int64,
         totalSize: Int64,
         provider: @escaping ChunkDataProvider) {
        // Swift 要求子类属性在 super.init 前初始化
        self.provider = provider
        // isComplete = false：告诉 HTTPConnection.write 后不要关闭连接，
        // body 由异步 Task 推送，完成后连接由 keep-alive 逻辑处理。
        super.init(status, isComplete: false)
        // 显式设置 Content-Length（父类 prepareForWrite 在 isComplete=false 时跳过设置）
        self.headers["Content-Length"] = "\(contentLength)"
    }

    /// body 写入超时。
    private var bodyTimeout: TimeInterval = 300

    /// 重写头部写入（直接用 super 即可）。
    override func writeHeader(to stream: WriteStream, timeout: TimeInterval) {
        super.writeHeader(to: stream, timeout: timeout)
    }

    /// body 由异步 Task 推送，这里不调用 super（避免写空 body）。
    /// 直接使用传入的 stream 参数（Telegraph 保证 writeHeader 先于 writeBody 调用）。
    ///
    /// 关键：HTTPConnection.send 仅在 `!keepAlive && isComplete` 时才关闭连接，
    /// 而本响应 isComplete=false（避免父类用 body.count 覆盖 Content-Length），
    /// 因此 Telegraph 不会主动关闭连接。必须在数据推送结束后主动关闭 socket，
    /// 否则 VLCKit 收不到流结束信号 → 永远停在 buffering，且 seek 时旧连接的数据
    /// 会与新的 Range 请求交错。这里用 TCPSocket.close(when: .afterWriting)：
    /// GCDAsyncSocket 会先刷完所有已排队的写入，再优雅断开，给出干净的 EOF。
    ///
    /// 说明：GCDAsyncSocket 的 write 不会抛异常，错误通过 delegate 回调上报；
    /// 对端断开时，剩余 write 会被忽略，close(when:) 也是幂等的，故无需 try/catch。
    override func writeBody(to stream: WriteStream, timeout: TimeInterval) {
        self.bodyTimeout = timeout
        let provider = self.provider
        let writeTimeout = self.bodyTimeout

        Task {
            await provider { chunk in
                guard !chunk.isEmpty else { return }
                stream.write(data: chunk, timeout: writeTimeout)
            }
            // 数据已全部排队写入，优雅关闭：等待写队列完成后断开连接
            if let socket = stream as? TCPSocket {
                socket.close(when: .afterWriting)
            }
        }
    }
}
