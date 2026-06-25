//
//  ThumbnailService.swift
//  RemotePlayer
//
//  缩略图生成与缓存。
//
//  策略：
//  - 图片：通过 SMBService 读取完整文件 → UIImage → 缩放为缩略图。
//  - 视频：本地代理已启动时，用 VLCKit 抓取首帧；或在播放过程中由播放器提供。
//    为保持本服务独立性，视频缩略图优先复用"上次播放截图"，
//    若无则返回 nil（UI 显示占位符）。
//  - 缓存：内存 NSCache + 磁盘 LRU（Caches/thumbnails）。
//

import UIKit
import Foundation
import CommonCrypto

/// 缩略图服务。线程安全的单例。
actor ThumbnailService {

    static let shared = ThumbnailService()

    /// 内存缓存。
    private let memoryCache = NSCache<NSString, UIImage>()

    /// 磁盘缓存目录。
    private let diskCacheDir: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheDir = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
        // 配置内存缓存上限（~20MB）
        memoryCache.totalCostLimit = 20 * 1024 * 1024
    }

    // MARK: - 获取缩略图

    /// 获取图片缩略图（优先走缓存）。
    /// - Parameters:
    ///   - smbService: 已连接的 SMB 服务
    ///   - filePath: 远程图片路径
    ///   - size: 缩略图目标尺寸
    func imageThumbnail(smbService: SMBService, filePath: String, size: CGSize) async -> UIImage? {
        let cacheKey = cacheKey(for: filePath, suffix: "img")

        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }
        if let disk = readDisk(key: cacheKey) {
            memoryCache.setObject(disk, forKey: cacheKey, cost: disk.cost)
            return disk
        }

        // 从 SMB 读取完整图片
        guard let data = try? await smbService.readEntireFile(filePath),
              let image = UIImage(data: data) else {
            return nil
        }

        let thumb = resize(image, to: size)
        memoryCache.setObject(thumb, forKey: cacheKey, cost: thumb.cost)
        writeDisk(key: cacheKey, image: thumb)
        return thumb
    }

    /// 注册一张视频缩略图（由播放器在首帧/截图时调用）。
    func registerVideoThumbnail(filePath: String, image: UIImage) {
        let cacheKey = cacheKey(for: filePath, suffix: "vid")
        memoryCache.setObject(image, forKey: cacheKey, cost: image.cost)
        writeDisk(key: cacheKey, image: image)
    }

    /// 获取视频缩略图（可能为 nil）。
    func videoThumbnail(filePath: String) async -> UIImage? {
        let cacheKey = cacheKey(for: filePath, suffix: "vid")
        if let cached = memoryCache.object(forKey: cacheKey) {
            return cached
        }
        if let disk = readDisk(key: cacheKey) {
            memoryCache.setObject(disk, forKey: cacheKey, cost: disk.cost)
            return disk
        }
        return nil
    }

    // MARK: - 清理

    /// 清空所有缓存。
    func clearAll() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskCacheDir)
        try? FileManager.default.createDirectory(at: diskCacheDir, withIntermediateDirectories: true)
    }

    /// 当前缓存占用磁盘大小（字节）。
    func diskUsage() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskCacheDir,
            includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - 私有

    private func cacheKey(for path: String, suffix: String) -> NSString {
        // 用路径 + 后缀生成稳定的缓存键（跨进程稳定）。
        // 用 SHA-256 的前 16 字符，避免文件名特殊字符问题。
        let raw = "\(suffix):\(path)"
        let hashed = raw.stableHash()
        return hashed as NSString
    }

    /// 缩放图片到指定尺寸（保持原比例，aspectFit）。
    ///
    /// 之前用 draw(in:) 直接拉伸会扭曲非方形图片的比例（缩略图变形）。
    /// 改为 aspectFit：等比缩放到目标内，不足部分留空，图像区域大小不变，
    /// 由调用方决定如何裁剪/填充显示。
    private func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            return image
        }
        let scaleW = size.width / imageSize.width
        let scaleH = size.height / imageSize.height
        let scale = min(scaleW, scaleH) // aspectFit：取较小比例
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        // 居中绘制
        let drawOrigin = CGPoint(x: (size.width - drawSize.width) / 2,
                                 y: (size.height - drawSize.height) / 2)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }

    private func readDisk(key: NSString) -> UIImage? {
        let url = diskCacheDir.appendingPathComponent(key as String)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func writeDisk(key: NSString, image: UIImage) {
        let url = diskCacheDir.appendingPathComponent(key as String)
        // 用 JPEG 节省空间
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension UIImage {
    /// 估算内存占用（字节）。
    var cost: Int {
        Int(size.width * size.height * scale * scale) * 4
    }
}

private extension String {
    /// 跨进程稳定的哈希（基于 SHA-256 前 16 字符的十六进制）。
    func stableHash() -> String {
        let data = data(using: .utf8) ?? Data()
        var digest = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
