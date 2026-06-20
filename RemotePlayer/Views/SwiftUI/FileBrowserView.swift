//
//  FileBrowserView.swift
//  RemotePlayer
//
//  文件浏览器：展示当前目录，支持进入子目录、播放视频/图片。
//  顶部工具栏：排序、筛选、搜索。
//

import SwiftUI

struct FileBrowserView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @State private var viewModel: FileBrowserViewModel?

    // 播放目标
    @State private var videoToPlay: SMBFile?
    @State private var imageViewerFile: SMBFile?

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel: viewModel)
            } else {
                ProgressView()
                    .task {
                        let vm = FileBrowserViewModel(smbService: coordinator.smbService)
                        viewModel = vm
                        await vm.reload()
                    }
            }
        }
    }

    @ViewBuilder
    private func content(viewModel: FileBrowserViewModel) -> some View {
        List {
            // 当前目录的文件
            ForEach(viewModel.displayedFiles) { file in
                FileRowView(file: file,
                            serverID: coordinator.connectedServer?.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleTap(file, viewModel: viewModel)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(viewModel.currentDirName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                sortMenu(viewModel: viewModel)
                filterMenu(viewModel: viewModel)
            }
            ToolbarItem(placement: .topBarLeading) {
                if !viewModel.isAtRoot {
                    Button {
                        Task { await viewModel.goBack() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
            }
        }
        .searchable(text: Binding(
            get: { viewModel.searchText },
            set: { viewModel.searchText = $0 }
        ), prompt: "搜索文件名")
        .refreshable {
            await viewModel.reload()
        }
        .overlay {
            if viewModel.isLoading && viewModel.rawFiles.isEmpty {
                ProgressView("正在读取目录…")
            } else if viewModel.displayedFiles.isEmpty && !viewModel.isLoading {
                ContentUnavailableView.search(text: viewModel.searchText)
            }
        }
        .alert("读取失败", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("重试") { Task { await viewModel.reload() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        // 视频播放（sheet 全屏）
        .sheet(item: $videoToPlay) { file in
            PlayerContainerView(file: file, serverID: coordinator.connectedServer?.id)
        }
        // 图片浏览
        .sheet(item: $imageViewerFile) { file in
            ImageViewerView(currentFile: file,
                            siblings: viewModel.imageFiles(),
                            serverID: coordinator.connectedServer?.id)
        }
    }

    // MARK: - 工具栏菜单

    @ViewBuilder
    private func sortMenu(viewModel: FileBrowserViewModel) -> some View {
        Menu {
            ForEach(FileSortOption.allCases) { option in
                Button {
                    viewModel.sortOption = option
                } label: {
                    Label(option.localizedName, systemImage: viewModel.sortOption == option ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    @ViewBuilder
    private func filterMenu(viewModel: FileBrowserViewModel) -> some View {
        Menu {
            Picker("筛选", selection: Binding(
                get: { viewModel.filter },
                set: { viewModel.filter = $0 }
            )) {
                ForEach(FileFilter.allCases) { f in
                    Text(f.localizedName).tag(f)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
    }

    // MARK: - 点击处理

    private func handleTap(_ file: SMBFile, viewModel: FileBrowserViewModel) {
        if file.isDirectory {
            Task { await viewModel.enter(directory: file) }
        } else {
            switch file.kind {
            case .video:
                videoToPlay = file
            case .image:
                imageViewerFile = file
            case .other:
                // 其他类型不支持打开
                break
            }
        }
    }
}

#Preview {
    NavigationStack {
        FileBrowserView()
            .environment(AppCoordinator())
    }
}
