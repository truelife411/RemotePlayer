//
//  PlayerViewModel.swift
//  RemotePlayer
//
//  视频播放视图模型。
//  职责：
//  1. 通过 ProxyServer 注册流式路由，生成供 VLCKit 的本地 URL
//  2. 查找并下载同目录外挂字幕到本地（VLC 需本地文件路径）
//  3. 读取断点续播位置
//  4. 周期性保存播放进度
//

import SwiftUI
import Combine

@MainActor
@Observable
final class PlayerViewModel {

    let file: SMBFile
    let serverID: UUID?
    private let coordinator: AppCoordinator

    /// 流式 URL（注册代理后生成）。
    private(set) var streamURL: URL?
    /// 外挂字幕本地路径。
    private(set) var localSubtitleURL: URL?
    /// 断点续播起始位置（秒）。
    private(set) var startPosition: TimeInterval = 0
    /// 文件总大小。
    private(set) var fileSize: Int64 = 0

    /// 当前播放状态（供 SwiftUI 展示）。
    var isPlaying = false
    var isBuffering = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var errorMessage: String?

    /// 本次播放使用的 token（注销时用）。
    private var streamToken: String?

    init(file: SMBFile, serverID: UUID?, coordinator: AppCoordinator) {
        self.file = file
        self.serverID = serverID
        self.coordinator = coordinator
    }

    // MARK: - 准备播放

    /// 注册代理路由 + 获取文件信息 + 下载字幕。
    func prepare() async {
        do {
            // 1. 获取文件大小
            let attr = try await coordinator.smbService.attributes(of: file.path)
            fileSize = attr.size

            // 2. 读取断点续播
            if let serverID,
               let progress = PlaybackStore.shared.progress(for: serverID, filePath: file.path),
               !progress.isFinished {
                startPosition = progress.position
            }

            // 3. 查找并下载外挂字幕
            if let subtitlePath = try? await coordinator.smbService.findExternalSubtitle(for: file.path) {
                localSubtitleURL = await downloadSubtitle(from: subtitlePath)
            }

            // 4. 注册流式路由
            let token = UUID().uuidString
            let url = coordinator.proxyServer.registerStream(
                token: token,
                smbPath: file.path,
                totalSize: fileSize,
                smbService: coordinator.smbService
            )
            streamToken = token
            streamURL = url

        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 下载字幕文件到本地临时目录。
    private func downloadSubtitle(from smbPath: String) async -> URL? {
        do {
            let data = try await coordinator.smbService.readEntireFile(smbPath)
            let fileName = (smbPath as NSString).lastPathComponent
            let localURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("subtitle_\(UUID().uuidString)_\(fileName)")
            try data.write(to: localURL, options: .atomic)
            return localURL
        } catch {
            return nil
        }
    }

    // MARK: - 进度持久化（由 PlayerViewController 回调）

    func onProgressUpdate(position: TimeInterval, duration: TimeInterval, rate: Float) {
        guard let serverID else { return }
        if duration > 0 && position / duration > 0.97 {
            // 看完清除
            PlaybackStore.shared.clear(serverID: serverID, filePath: file.path)
        } else {
            PlaybackStore.shared.update(
                serverID: serverID,
                filePath: file.path,
                position: position,
                duration: duration,
                rate: rate
            )
        }
    }

    // MARK: - 截图注册缩略图

    /// 播放器截图后注册为视频缩略图。
    func registerThumbnail(_ image: UIImage) {
        Task {
            await ThumbnailService.shared.registerVideoThumbnail(filePath: file.path, image: image)
        }
    }

    // MARK: - 清理

    func cleanup() {
        if let token = streamToken {
            coordinator.proxyServer.unregisterStream(token: token)
            streamToken = nil
        }
        // 删除临时字幕
        if let url = localSubtitleURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
