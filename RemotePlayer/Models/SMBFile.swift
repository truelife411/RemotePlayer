//
//  SMBFile.swift
//  RemotePlayer
//
//  远程文件的统一表示，由 SMBService 从 AMSMB2 枚举结果转换而来。
//

import Foundation

/// 媒体类型分类，用于筛选。
enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case video
    case image
    case other

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        case .other: return "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .image: return "photo"
        case .other: return "doc"
        }
    }
}

/// 文件浏览的排序方式。
enum FileSortOption: String, Codable, CaseIterable, Identifiable {
    case nameAsc
    case nameDesc
    case sizeAsc
    case sizeDesc
    case modifiedAsc
    case modifiedDesc

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .nameAsc:     return "名称 ↑"
        case .nameDesc:    return "名称 ↓"
        case .sizeAsc:     return "大小 ↑"
        case .sizeDesc:    return "大小 ↓"
        case .modifiedAsc: return "修改时间 ↑"
        case .modifiedDesc:return "修改时间 ↓"
        }
    }
}

/// 类型筛选。
enum FileFilter: String, Codable, CaseIterable, Identifiable {
    case all
    case videoOnly
    case imageOnly

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .all:        return "全部"
        case .videoOnly:  return "视频"
        case .imageOnly:  return "图片"
        }
    }
}

/// 远程文件/目录的统一模型。
struct SMBFile: Identifiable, Hashable {
    /// 稳定标识：使用完整路径，路径唯一。
    let id: String
    /// 显示文件名（不含路径）。
    let name: String
    /// 相对共享根的完整路径，使用 `/` 分隔。根目录为空串 ""。
    let path: String
    /// 是否为目录。
    let isDirectory: Bool
    /// 字节大小；目录为 0。
    let size: Int64
    /// 最后修改时间。
    let modifiedDate: Date?
    /// 推断出的媒体类型。
    let kind: MediaKind
    /// 文件扩展名（小写，无点）。
    let `extension`: String

    /// 父目录路径。
    var parentPath: String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<lastSlash])
    }

    /// 人类可读的大小。
    var formattedSize: String {
        guard size > 0 else { return isDirectory ? "—" : "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 人类可读的修改时间。
    var formattedDate: String {
        guard let modifiedDate else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: modifiedDate)
    }
}

extension SMBFile {
    /// 视频扩展名白名单。
    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "flv", "wmv",
        "rmvb", "rm", "ts", "m2ts", "mts", "webm", "3gp",
        "mpg", "mpeg", "vob", "f4v", "ogv"
    ]

    /// 图片扩展名白名单。
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "tiff", "tif"
    ]

    /// 根据扩展名推断媒体类型。
    static func kind(for ext: String) -> MediaKind {
        let lower = ext.lowercased()
        if videoExtensions.contains(lower) { return .video }
        if imageExtensions.contains(lower) { return .image }
        return .other
    }
}
