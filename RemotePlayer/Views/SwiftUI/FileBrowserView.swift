//
//  FileBrowserView.swift
//  RemotePlayer
//
//  文件浏览器：展示当前目录，支持进入子目录、播放视频/图片。
//  顶部工具栏：排序、筛选、搜索。
//  自适应布局：regular（iPad / iPhone Plus 横屏）用网格，compact（iPhone）用列表。
//

import SwiftUI

struct FileBrowserView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.horizontalSizeClass) private var hSizeClass
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
                        // 注入全目录搜索索引（连接后已自动后台构建）
                        vm.searchIndex = coordinator.searchIndex
                        viewModel = vm
                        await vm.reload()
                    }
            }
        }
        // 媒体呈现：用 fullScreenCover 保证 iPad 上也全屏（sheet 在 iPad 上会变小窗口）。
        // 绑定挂在外层 Group 上，列表/网格两种布局都能触发。
        .fullScreenCover(item: $videoToPlay) { file in
            PlayerContainerView(file: file, serverID: coordinator.connectedServer?.id)
        }
        .fullScreenCover(item: $imageViewerFile) { file in
            // 搜索模式下文件可能来自任意目录，传 [file] 单图模式（无左右切换）；
            // 浏览模式用当前目录的图片兄弟姐妹（可左右切换）。
            let siblings = (viewModel?.isSearching ?? false)
                ? [file]
                : (viewModel?.imageFiles() ?? [file])
            ImageViewerView(currentFile: file,
                            siblings: siblings,
                            serverID: coordinator.connectedServer?.id)
        }
    }

    @ViewBuilder
    private func content(viewModel: FileBrowserViewModel) -> some View {
        VStack(spacing: 0) {
            // 常驻搜索栏（默认显示，不用下拉）
            searchBar(viewModel: viewModel)
            // 索引构建进度（搜索模式 + 正在建索引时显示）
            indexProgress(viewModel: viewModel)
            // regular（iPad 等）用网格，compact（iPhone 等）用列表
            if hSizeClass == .regular {
                gridView(viewModel: viewModel)
            } else {
                listView(viewModel: viewModel)
            }
        }
        .browserChrome(viewModel: viewModel)
    }

    // MARK: - 索引进度

    @ViewBuilder
    private func indexProgress(viewModel: FileBrowserViewModel) -> some View {
        // 仅在搜索模式下、索引正在构建时显示进度
        let idx = coordinator.searchIndex
        if viewModel.isSearching, idx.isIndexing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                if case .indexing(let fc, let dc) = idx.state {
                    Text("正在索引… 已扫描 \(fc) 个文件 / \(dc) 个目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground).opacity(0.5))
        }
    }

    // MARK: - 搜索栏（常驻显示）

    @ViewBuilder
    private func searchBar(viewModel: FileBrowserViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文件名", text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 列表布局（iPhone）

    @ViewBuilder
    private func listView(viewModel: FileBrowserViewModel) -> some View {
        List {
            ForEach(viewModel.displayedFiles) { file in
                FileRowView(file: file,
                            serverID: coordinator.connectedServer?.id,
                            subtitle: viewModel.isSearching ? file.parentPath : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleTap(file, viewModel: viewModel)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 网格布局（iPad）

    @ViewBuilder
    private func gridView(viewModel: FileBrowserViewModel) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                      spacing: 14) {
                ForEach(viewModel.displayedFiles) { file in
                    FileGridCell(file: file, serverID: coordinator.connectedServer?.id,
                                 subtitle: viewModel.isSearching ? file.parentPath : nil)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleTap(file, viewModel: viewModel)
                        }
                }
            }
            .padding(16)
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

// MARK: - 浏览器外观（标题栏/搜索/工具栏/刷新/空态/错误）

private struct BrowserChrome: ViewModifier {
    let viewModel: FileBrowserViewModel

    func body(content: Content) -> some View {
        content
            .navigationTitle(viewModel.currentDirName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    sortMenu
                    filterMenu
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
    }

    private var sortMenu: some View {
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

    private var filterMenu: some View {
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
}

private extension View {
    func browserChrome(viewModel: FileBrowserViewModel) -> some View {
        modifier(BrowserChrome(viewModel: viewModel))
    }
}

#Preview {
    NavigationStack {
        FileBrowserView()
            .environment(AppCoordinator())
    }
}
