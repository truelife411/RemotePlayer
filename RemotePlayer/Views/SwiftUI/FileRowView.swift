//
//  FileRowView.swift
//  RemotePlayer
//
//  文件列表的单行：缩略图 + 名称 + 大小/时间 + 断点续播进度。
//

import SwiftUI

struct FileRowView: View {

    let file: SMBFile
    let serverID: UUID?

    @State private var thumbnail: UIImage?
    @State private var progress: Double = 0 // 0 表示无续播

    var body: some View {
        HStack(spacing: 12) {
            // 缩略图 / 图标
            iconView
                .frame(width: 52, height: 52)

            // 文件信息
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)

                if !file.isDirectory {
                    HStack(spacing: 8) {
                        Text(file.formattedSize)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(file.formattedDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 断点续播进度条
                if progress > 0 && progress < 0.97 {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .frame(height: 3)
                }
            }

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .task(id: file.id) {
            await loadThumbnail()
            loadProgress()
        }
    }

    // MARK: - 图标

    @ViewBuilder
    private var iconView: some View {
        if file.isDirectory {
            // 目录统一图标
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                }
        } else if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            // 占位符
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))
                .overlay {
                    Image(systemName: file.kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - 数据加载

    private func loadThumbnail() async {
        guard !file.isDirectory else { return }
        switch file.kind {
        case .image:
            // 通过当前协调器的 smbService 取缩略图（已连接）
            // 这里用环境外获取的方式：通过 ThumbnailService + 传入的服务
            // 为简化，图片缩略图延迟到 ImageViewer；列表用占位符
            return
        case .video:
            if let thumb = await ThumbnailService.shared.videoThumbnail(filePath: file.path) {
                self.thumbnail = thumb
            }
        case .other:
            return
        }
    }

    private func loadProgress() {
        guard file.kind == .video, let serverID else {
            progress = 0
            return
        }
        if let p = PlaybackStore.shared.progress(for: serverID, filePath: file.path) {
            progress = p.progress
        }
    }
}
