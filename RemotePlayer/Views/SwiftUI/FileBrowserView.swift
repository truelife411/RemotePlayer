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
    /// 是否展示独立搜索页。
    @State private var showSearch = false
    /// iPad 上网格/列表切换。仅 regular（iPad）下生效，compact（iPhone）永远列表。
    @State private var isGridView = true

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
            // 浏览模式用当前目录的图片兄弟姐妹（可左右切换）。
            let siblings = viewModel?.imageFiles() ?? [file]
            ImageViewerView(currentFile: file,
                            siblings: siblings,
                            serverID: coordinator.connectedServer?.id)
        }
        // 独立搜索页
        .fullScreenCover(isPresented: $showSearch) {
            SearchView()
                .environment(coordinator)
        }
    }

    @ViewBuilder
    private func content(viewModel: FileBrowserViewModel) -> some View {
        // iPhone（compact）：永远列表
        // iPad（regular）：按 isGridView 切换网格/列表
        Group {
            if hSizeClass == .regular {
                if isGridView {
                    gridView(viewModel: viewModel)
                } else {
                    iPadListView(viewModel: viewModel)
                }
            } else {
                listView(viewModel: viewModel)
            }
        }
        .browserChrome(viewModel: viewModel, isGridView: $isGridView, onSearch: { showSearch = true })
    }

    // MARK: - 列表布局（iPhone）

    @ViewBuilder
    private func listView(viewModel: FileBrowserViewModel) -> some View {
        List {
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
    }

    // MARK: - 网格布局（iPad）

    @ViewBuilder
    private func gridView(viewModel: FileBrowserViewModel) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                      spacing: 14) {
                ForEach(viewModel.displayedFiles) { file in
                    FileGridCell(file: file, serverID: coordinator.connectedServer?.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleTap(file, viewModel: viewModel)
                        }
                }
            }
            .padding(16)
        }
    }

    // MARK: - iPad 列表布局（带可点击排序的列头）

    @ViewBuilder
    private func iPadListView(viewModel: FileBrowserViewModel) -> some View {
        List {
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
        // 列表顶部插入可点击排序的列头
        .safeAreaInset(edge: .top, spacing: 0) {
            sortHeader(viewModel: viewModel)
        }
    }

    /// 列头行：名称 | 大小 | 修改时间，点击切换升/降序。
    @ViewBuilder
    private func sortHeader(viewModel: FileBrowserViewModel) -> some View {
        HStack(spacing: 0) {
            sortColumn(title: "名称",
                       asc: .nameAsc, desc: .nameDesc, viewModel: viewModel)
            sortColumn(title: "大小",
                       asc: .sizeAsc, desc: .sizeDesc, viewModel: viewModel)
            sortColumn(title: "修改时间",
                       asc: .modifiedAsc, desc: .modifiedDesc, viewModel: viewModel)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func sortColumn(title: String,
                             asc: FileSortOption, desc: FileSortOption,
                             viewModel: FileBrowserViewModel) -> some View {
        let current = viewModel.sortOption
        let isActive = (current == asc || current == desc)
        let isAsc = (current == asc)

        Button {
            if isActive {
                viewModel.sortOption = isAsc ? desc : asc
            } else {
                viewModel.sortOption = asc
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                if isActive {
                    Image(systemName: isAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(isActive ? .primary : .secondary)
        }
        .buttonStyle(.plain)

        if asc != .modifiedDesc {
            Spacer(minLength: 8)
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
    /// iPad 网格/列表切换。
    @Binding var isGridView: Bool
    let onSearch: () -> Void

    @Environment(\.horizontalSizeClass) private var hSizeClass

    func body(content: Content) -> some View {
        content
            .navigationTitle(viewModel.currentDirName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // 搜索按钮 → 进入独立搜索页
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    // iPad 网格/列表切换（仅 regular 可见）
                    if hSizeClass == .regular {
                        Button {
                            isGridView.toggle()
                        } label: {
                            Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                        }
                    }
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
                    ContentUnavailableView {
                        Label("空文件夹", systemImage: "folder")
                    } description: {
                        Text("此目录没有文件")
                    }
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
    func browserChrome(viewModel: FileBrowserViewModel, isGridView: Binding<Bool>, onSearch: @escaping () -> Void) -> some View {
        modifier(BrowserChrome(viewModel: viewModel, isGridView: isGridView, onSearch: onSearch))
    }
}

#Preview {
    NavigationStack {
        FileBrowserView()
            .environment(AppCoordinator())
    }
}
