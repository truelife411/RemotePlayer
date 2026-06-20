//
//  PlaybackState.swift
//  RemotePlayer
//
//  播放状态与断点续播相关模型。
//

import Foundation

/// 单个视频的播放进度，用于断点续播。
struct PlaybackProgress: Codable, Hashable {
    /// 文件标识：服务器ID + 文件完整路径，保证全局唯一。
    let key: String
    /// 上次播放到的秒数。
    var position: Double
    /// 媒体总时长（秒），可能未知。
    var duration: Double
    /// 上次播放更新时间。
    var updatedAt: Date
    /// 上次播放速率。
    var rate: Float

    /// 完成度 0...1。
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// 是否视为"已看完"（接近结尾），看完后清除进度。
    var isFinished: Bool {
        duration > 0 && position / duration > 0.97
    }
}

/// 字幕轨道描述。
struct SubtitleTrack: Identifiable, Hashable {
    let id: Int32          // VLC 内部 track index
    let name: String       // 显示名称
    let isExternal: Bool   // 是否外挂字幕（同目录 SRT）
}

/// 字幕匹配结果：内嵌轨道 + 同目录外挂文件路径。
struct SubtitleSources {
    /// 外挂字幕文件在 SMB 上的路径（如果有）。
    let externalPath: String?
}
