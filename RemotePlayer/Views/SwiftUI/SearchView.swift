//
//  SearchView.swift
//  RemotePlayer
//
//  独立的搜索页面（fullScreenCover 呈现）。
//
//  与浏览页分离：进入即默认全部类型，跨整个共享搜索，结果带文件所在目录路径。
//  关闭后回到原浏览页，浏览状态不受影响。
//

import SwiftUI

struct SearchView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSizeClass

    @State private var viewModel: SearchViewModel?
    @State private var videoToPlay: SMBFile?
    @State private var imageViewerFile: SMBFile?
    /// 搜索框聚焦（进入页面自动聚焦）。
    @FocusState private var searchFocused: Bool
    /// iPad 上网格/列表切换。
    @State private var isGridView = true

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    content(viewModel: viewModel)
                } else {
                    ProgressView()
                        .task {
                            viewModel = SearchViewModel(searchIndex: coordinator.searchIndex)
                        }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                if viewModel != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // 重建索引按钮
                        Button {
                            if let serverID = coordinator.connectedServer?.id.uuidString {
                                coordinator.searchIndex.reset(serverID: serverID)
                                coordinator.searchIndex.startBuilding(
                                    smbService: coordinator.smbService, serverID: serverID)
                            }
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        if hSizeClass == .regular {
                            Button {
                                isGridView.toggle()
                            } label: {
                                Image(systemName: isGridView ? "list.bullet" : "square.grid.2x2")
                            }
                        }
                        sortMenu(viewModel: viewModel!)
                        filterMenu(viewModel: viewModel!)
                    }
                }
            }
        }
        // 媒体呈现：fullScreenCover 保证 iPad 也全屏
        .fullScreenCover(item: $videoToPlay) { file in
            PlayerContainerView(file: file, serverID: coordinator.connectedServer?.id)
        }
        .fullScreenCover(item: $imageViewerFile) { file in
            // 搜索结果是跨目录扁平列表，图片用单图模式（无左右切换）
            ImageViewerView(currentFile: file,
                            siblings: [file],
                            serverID: coordinator.connectedServer?.id)
        }
        .onAppear {
            // 进入页面自动聚焦搜索框
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchFocused = true
            }
            // 首次进入：没建过索引（idle + 无 checkpoint），自动开始构建
            let idx = coordinator.searchIndex
            if case .idle = idx.state, idx.files.isEmpty,
               let serverID = coordinator.connectedServer?.id.uuidString {
                idx.startBuilding(smbService: coordinator.smbService, serverID: serverID)
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private func content(viewModel: SearchViewModel) -> some View {
        VStack(spacing: 0) {
            // 搜索框
            searchBar(viewModel: viewModel)
            // 索引进度
            if let status = viewModel.indexStatusText {
                indexBanner(text: status)
            }
            // 结果列表/网格
            if viewModel.results.isEmpty {
                emptyState(viewModel: viewModel)
            } else {
                if hSizeClass == .regular {
                    if isGridView {
                        gridResults(viewModel: viewModel)
                    } else {
                        iPadListResults(viewModel: viewModel)
                    }
                } else {
                    listResults(viewModel: viewModel)
                }
            }
        }
    }

    // MARK: - 搜索框

    @ViewBuilder
    private func searchBar(viewModel: SearchViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索整个共享", text: Binding(
                get: { viewModel.searchText },
                set: { viewModel.searchText = $0 }
            ))
            .focused($searchFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
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
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - 索引进度条

    @ViewBuilder
    private func indexBanner(text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemBackground).opacity(0.5))
    }

    // MARK: - 结果列表（iPhone）

    @ViewBuilder
    private func listResults(viewModel: SearchViewModel) -> some View {
        List {
            ForEach(viewModel.results) { file in
                FileRowView(file: file,
                            serverID: coordinator.connectedServer?.id,
                            subtitle: file.parentPath.isEmpty ? "根目录" : file.parentPath)
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(file) }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - iPad 结果列表（带列头）

    @ViewBuilder
    private func iPadListResults(viewModel: SearchViewModel) -> some View {
        List {
            ForEach(viewModel.results) { file in
                FileRowView(file: file,
                            serverID: coordinator.connectedServer?.id,
                            subtitle: file.parentPath.isEmpty ? "根目录" : file.parentPath)
                    .contentShape(Rectangle())
                    .onTapGesture { handleTap(file) }
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
    private func sortHeader(viewModel: SearchViewModel) -> some View {
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
                             viewModel: SearchViewModel) -> some View {
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

    // MARK: - 结果网格（iPad）

    @ViewBuilder
    private func gridResults(viewModel: SearchViewModel) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)],
                      spacing: 14) {
                ForEach(viewModel.results) { file in
                    FileGridCell(file: file,
                                 serverID: coordinator.connectedServer?.id,
                                 subtitle: file.parentPath.isEmpty ? "根目录" : file.parentPath)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(file) }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 空态

    @ViewBuilder
    private func emptyState(viewModel: SearchViewModel) -> some View {
        let kw = viewModel.searchText.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty {
            // 空关键词但无结果：索引为空或还没建好
            ContentUnavailableView {
                Label("暂无文件", systemImage: "tray")
            } description: {
                Text(viewModel.indexStatusText ?? "索引为空，请确认共享里有文件")
            }
        } else {
            ContentUnavailableView.search(text: kw)
        }
    }

    // MARK: - 工具栏菜单

    @ViewBuilder
    private func sortMenu(viewModel: SearchViewModel) -> some View {
        Menu {
            ForEach(FileSortOption.allCases) { option in
                Button {
                    viewModel.sortOption = option
                } label: {
                    Label(option.localizedName,
                          systemImage: viewModel.sortOption == option ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }

    @ViewBuilder
    private func filterMenu(viewModel: SearchViewModel) -> some View {
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

    // MARK: - 点击

    private func handleTap(_ file: SMBFile) {
        switch file.kind {
        case .video:
            videoToPlay = file
        case .image:
            imageViewerFile = file
        case .other:
            break
        }
    }
}

#Preview {
    SearchView()
        .environment(AppCoordinator())
}
