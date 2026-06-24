//
//  FileBrowserViewModel.swift
//  RemotePlayer
//
//  文件浏览视图模型。
//  管理：当前路径栈、文件列表、加载状态、排序、筛选、搜索。
//

import SwiftUI

@MainActor
@Observable
final class FileBrowserViewModel {

    private let smbService: SMBService

    /// 全目录搜索索引（由 FileBrowserView 注入，连接后自动后台构建）。
    /// 搜索框非空时用它做全共享搜索；为空时正常浏览当前目录。
    var searchIndex: SearchIndexService?

    /// 当前所在目录（相对共享根）。根为 ""。
    private(set) var currentPath: String = ""

    /// 导航栈（用于返回上一级）。
    private(set) var pathStack: [String] = []

    /// 原始文件列表（未排序/筛选）。
    private(set) var rawFiles: [SMBFile] = []

    /// 加载状态。
    var isLoading = false
    var errorMessage: String?

    // MARK: - 用户偏好

    var sortOption: FileSortOption = .nameAsc
    var filter: FileFilter = .all
    var searchText: String = ""

    init(smbService: SMBService) {
        self.smbService = smbService
    }

    // MARK: - 处理后的列表

    /// 排序 + 筛选 + 搜索后的最终列表。
    ///
    /// 搜索框为空 → 显示当前目录内容（排序/筛选后）。
    /// 搜索框非空 → 全目录搜索结果（查 searchIndex，来自整个共享），
    ///   并对其应用同样的筛选 + 排序，保证搜索结果与浏览模式体验一致。
    var displayedFiles: [SMBFile] {
        // 搜索模式：全目录搜索结果也要过筛选 + 排序
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty,
           let searchIndex {
            return applySortAndFilter(to: searchIndex.search(keyword: searchText))
        }
        // 浏览模式：当前目录
        return applySortAndFilter(to: rawFiles)
    }

    /// 当前是否处于搜索模式（用于 UI 判断：是否显示搜索结果/进度提示）。
    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 对给定列表应用当前 筛选 + 搜索 + 排序，返回最终顺序。
    /// 仅用于浏览模式（当前目录）。搜索模式走 searchIndex，不走这里。
    private func applySortAndFilter(to source: [SMBFile]) -> [SMBFile] {
        var result = source

        // 筛选：类型
        switch filter {
        case .all:
            break
        case .videoOnly:
            result = result.filter { !$0.isDirectory && $0.kind == .video }
        case .imageOnly:
            result = result.filter { !$0.isDirectory && $0.kind == .image }
        }

        // 排序：目录永远在前
        let dirs = result.filter { $0.isDirectory }
        let files = result.filter { !$0.isDirectory }
        return dirs.sorted(by: sortDirsClosure) + files.sorted(by: sortFilesClosure)
    }

    private var sortDirsClosure: (SMBFile, SMBFile) -> Bool {
        switch sortOption {
        case .nameAsc, .sizeAsc, .modifiedAsc:
            return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc, .sizeDesc, .modifiedDesc:
            return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    private var sortFilesClosure: (SMBFile, SMBFile) -> Bool {
        switch sortOption {
        case .nameAsc:      return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:     return { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .sizeAsc:      return { $0.size < $1.size }
        case .sizeDesc:     return { $0.size > $1.size }
        case .modifiedAsc:  return { ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast) }
        case .modifiedDesc: return { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
        }
    }

    // MARK: - 当前目录标题

    /// 用于导航栏标题的目录名。
    var currentDirName: String {
        if currentPath.isEmpty { return "共享根目录" }
        return (currentPath as NSString).lastPathComponent
    }

    /// 是否在根目录（无法返回上一级）。
    var isAtRoot: Bool { pathStack.isEmpty }

    // MARK: - 操作

    /// 加载当前目录。
    func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            rawFiles = try await smbService.listDirectory(at: currentPath)
        } catch {
            errorMessage = error.localizedDescription
            rawFiles = []
        }
        isLoading = false
    }

    /// 进入子目录。
    func enter(directory: SMBFile) async {
        pathStack.append(currentPath)
        currentPath = directory.path
        await reload()
    }

    /// 返回上一级。
    func goBack() async {
        guard let prev = pathStack.popLast() else { return }
        currentPath = prev
        await reload()
    }

    /// 跳转到指定路径（用于搜索后定位等）。
    func navigate(to path: String) async {
        currentPath = path
        await reload()
    }

    /// 收集当前目录下所有图片（用于图片浏览器的左右切换）。
    /// 注意：必须用和浏览网格相同的排序，否则点进去顺序不一致、首张位置错乱。
    func imageFiles() -> [SMBFile] {
        // 复用浏览网格的筛选+排序逻辑（临时把 filter 设成 imageOnly 视角），
        // 但不改变用户当前的筛选/搜索状态——直接对图片子集应用同样的排序。
        let images = rawFiles.filter { !$0.isDirectory && $0.kind == .image }
        // 仅应用排序（目录已过滤掉），保持与网格一致
        return images.sorted(by: sortFilesClosure)
    }
}
