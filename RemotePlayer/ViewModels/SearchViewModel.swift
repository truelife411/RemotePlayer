//
//  SearchViewModel.swift
//  RemotePlayer
//
//  独立搜索页的 ViewModel。
//
//  与 FileBrowserViewModel 不同：这里不携带目录导航状态，只负责
//  在已构建的全共享索引（SearchIndexService）上做"关键词搜索 → 筛选 → 排序"。
//  搜索页与浏览页状态完全独立，进搜索页默认全部类型。
//

import Foundation

@MainActor
@Observable
final class SearchViewModel {

    /// 全共享索引（由 AppCoordinator 连接后构建，断开即失效）。
    let searchIndex: SearchIndexService

    /// 搜索词。
    var searchText = ""

    /// 类型筛选，搜索页默认全部（每次进入都重置）。
    var filter: FileFilter = .all

    /// 排序方式，默认名称升序。
    var sortOption: FileSortOption = .nameAsc

    init(searchIndex: SearchIndexService) {
        self.searchIndex = searchIndex
    }

    /// 是否正在建索引（透传给 UI 显示进度）。
    var isIndexing: Bool {
        searchIndex.isIndexing
    }

    /// 索引状态描述（供 UI 显示扫描进度文案）。
    var indexStatusText: String? {
        if case .indexing(let fc, let dc) = searchIndex.state {
            return "正在索引… 已扫描 \(fc) 个文件 / \(dc) 个目录"
        }
        if case .failed(let msg) = searchIndex.state {
            return "索引未完成：\(msg)"
        }
        return nil
    }

    /// 搜索结果（搜索 → 类型筛选 → 排序）。
    /// 注意：SearchIndexService 只索引文件（不含目录），所以这里全是文件。
    ///
    /// 空关键词时直接展示索引里全部文件（用户要求：进入搜索页默认显示全部），
    /// 但全量可能很大，限制返回数量避免 UI 卡顿。
    var results: [SMBFile] {
        let kw = searchText.trimmingCharacters(in: .whitespaces)

        // 1. 取候选：有关键词 → 搜索；无关键词 → 全部（限量）
        let candidates: [SMBFile]
        if kw.isEmpty {
            candidates = Array(searchIndex.files.prefix(maxAllLimit))
        } else {
            candidates = searchIndex.search(keyword: kw)
        }

        // 2. 类型筛选
        var list = candidates
        switch filter {
        case .all:
            break
        case .videoOnly:
            list = list.filter { $0.kind == .video }
        case .imageOnly:
            list = list.filter { $0.kind == .image }
        }

        // 3. 按当前排序选项重排
        return list.sorted(by: sortClosure)
    }

    /// 空关键词时最多展示的文件数（避免几万条全量加载卡顿）。
    private let maxAllLimit = 500

    /// 排序比较闭包（文件排序，无目录混排问题）。
    private var sortClosure: (SMBFile, SMBFile) -> Bool {
        switch sortOption {
        case .nameAsc:
            return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:
            return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeAsc:
            return { $0.size < $1.size }
        case .sizeDesc:
            return { $0.size > $1.size }
        case .modifiedAsc:
            return { ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast) }
        case .modifiedDesc:
            return { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        }
    }
}
