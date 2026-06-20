//
//  AppError.swift
//  RemotePlayer
//
//  统一错误类型，覆盖网络、SMB、播放、代理等场景。
//

import Foundation

/// 应用统一错误。
enum AppError: LocalizedError {
    case smbNotConnected
    case smbConnectFailed(host: String, detail: String)
    case smbAuthFailed(detail: String)
    case smbListFailed(path: String, detail: String)
    case smbReadFailed(path: String, detail: String)
    case smbFileNotFound(path: String)
    case proxyStartFailed(port: UInt16, detail: String)
    case proxyNotRunning
    case playerInitFailed(detail: String)
    case invalidServerConfig(detail: String)
    case networkUnreachable
    case unknown(detail: String)

    var errorDescription: String? {
        switch self {
        case .smbNotConnected:
            return "尚未连接到服务器"
        case .smbConnectFailed(let host, let detail):
            return "连接 \(host) 失败：\(detail)"
        case .smbAuthFailed(let detail):
            return "认证失败：\(detail)\n（请确认用户名为系统短名、密码为登录密码；Mac 可在「共享」里重新开关文件共享）"
        case .smbListFailed(let path, let detail):
            return "读取目录失败：\(path)\n\(detail)"
        case .smbReadFailed(let path, let detail):
            return "读取文件失败：\(path)\n\(detail)"
        case .smbFileNotFound(let path):
            return "文件不存在：\(path)"
        case .proxyStartFailed(let port, let detail):
            return "启动本地代理失败 (端口 \(port))：\(detail)"
        case .proxyNotRunning:
            return "本地代理未运行"
        case .playerInitFailed(let detail):
            return "播放器初始化失败：\(detail)"
        case .invalidServerConfig(let detail):
            return "服务器配置无效：\(detail)"
        case .networkUnreachable:
            return "网络不可达，请检查 WiFi 或局域网连接"
        case .unknown(let detail):
            return detail
        }
    }
}
