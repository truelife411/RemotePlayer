//
//  SettingsView.swift
//  RemotePlayer
//
//  设置页：显示缩略图缓存大小，支持一键清理。
//  从服务器列表页的齿轮按钮进入。
//

import SwiftUI

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    /// 当前缩略图缓存大小（字节）。初始为 nil 表示正在读取。
    @State private var cacheBytes: Int64?
    /// 是否正在清理。
    @State private var isClearing = false
    /// 清理完成提示。
    @State private var showClearedAlert = false

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Form {
            Section("缓存") {
                HStack {
                    Label("缩略图缓存", systemImage: "photo.stack")
                    Spacer()
                    Text(cacheSizeText)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    clearCache()
                } label: {
                    if isClearing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("清理中…")
                        }
                    } else {
                        Label("清理缓存", systemImage: "trash")
                    }
                }
                .disabled(isClearing || (cacheBytes ?? 0) == 0)
            }

            Section {
                LabeledContent("RemotePlayer", value: "v2.2")
            } header: {
                Text("关于")
            } footer: {
                Text("缩略图缓存用于加速文件列表/网格的图片预览。清理后下次浏览会重新从服务器读取。iOS 在存储紧张时也会自动回收此缓存。")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheSize() }
        .alert("已清理", isPresented: $showClearedAlert) {
            Button("好") {}
        } message: {
            Text("缩略图缓存已清空")
        }
    }

    // MARK: - 子视图

    private var cacheSizeText: String {
        guard let bytes = cacheBytes else { return "计算中…" }
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - 动作

    private func refreshCacheSize() async {
        cacheBytes = await ThumbnailService.shared.diskUsage()
    }

    private func clearCache() {
        isClearing = true
        Task {
            await ThumbnailService.shared.clearAll()
            // 清理后再读一次确认
            cacheBytes = await ThumbnailService.shared.diskUsage()
            isClearing = false
            showClearedAlert = true
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
