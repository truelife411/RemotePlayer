//
//  FileGridCell.swift
//  RemotePlayer
//
//  文件网格格子（iPad / regular 宽度布局用）。
//  复用 FileRowView 的缩略图与续播进度加载逻辑，但改为竖向紧凑布局：
//  顶部大图标/缩略图 + 下方文件名 + 大小/日期。
//

import SwiftUI

struct FileGridCell: View {

    let file: SMBFile
    let serverID: UUID?
    /// 搜索结果用：显示文件所在目录路径（灰色小字）。浏览模式下为 nil 不显示。
    var subtitle: String? = nil

    @Environment(AppCoordinator.self) private var coordinator
    @State private var thumbnail: UIImage?
    @State private var progress: Double = 0 // 0 表示无续播

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 图标区：用 GeometryReader 拿到确定宽度，
            // 配合固定高度 + clipped，彻底裁掉 scaledToFill 缩略图的溢出。
            // 之前 iconView 自己加 frame 会和外层嵌套、裁剪层级混乱导致溢出，
            // 现在统一在这里用确定尺寸 + clipped 收口。
            GeometryReader { geo in
                iconView
                    .frame(width: geo.size.width, height: 110)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .frame(height: 110)
            .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                // 所在目录路径（仅搜索结果显示）
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !file.isDirectory {
                    Text(file.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 断点续播进度条
                if progress > 0 && progress < 0.97 {
                    ProgressView(value: progress)
                        .tint(.accentColor)
                        .frame(height: 3)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
        .task(id: file.id) {
            await loadThumbnail()
            loadProgress()
        }
    }

    // MARK: - 图标

    @ViewBuilder
    private var iconView: some View {
        if file.isDirectory {
            // 目录：图标居中，背景填满
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.12))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Color.accentColor)
                }
        } else if let thumbnail {
            // 缩略图：scaledToFill 会溢出，裁剪交给外层 body 的 frame+clipped 统一处理。
            // 这里不要自己加 frame，否则和外层 frame 形成嵌套、裁剪层级混乱导致溢出。
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
                .overlay {
                    Image(systemName: file.kind.systemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - 数据加载（与 FileRowView 一致的逻辑）

    private func loadThumbnail() async {
        guard !file.isDirectory else { return }
        switch file.kind {
        case .image:
            // 图片缩略图：读取 SMB 原图 → 缩放 → 缓存（内存+磁盘）
            let thumb = await ThumbnailService.shared.imageThumbnail(
                smbService: coordinator.smbService,
                filePath: file.path,
                size: CGSize(width: 240, height: 240)
            )
            self.thumbnail = thumb
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
