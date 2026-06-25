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
                    gridResults(viewModel: viewModel)
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
