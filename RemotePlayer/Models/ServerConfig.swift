//
//  ServerConfig.swift
//  RemotePlayer
//
//  SMB 服务器连接配置模型。
//  持久化于 UserDefaults（通过 JSON 编码）。
//

import Foundation

/// 单台 SMB 服务器的连接配置。
struct ServerConfig: Identifiable, Codable, Hashable {
    /// 唯一标识，自动生成。
    let id: UUID
    /// 用户可读别名，例如"家里PC"。
    var name: String
    /// 主机地址，可以是 IP 或主机名（不含 smb:// 前缀）。
    var host: String
    /// SMB 端口，默认 139（SMB over NetBIOS）。
    var port: UInt16
    /// 共享名称（share name），对应 Windows 共享文件夹名。
    var shareName: String
    /// 登录用户名；匿名访问时为空。
    var username: String
    /// 登录密码；匿名访问时为空。
    var password: String
    /// 上次成功连接时间，用于排序展示。
    var lastConnectedAt: Date?

    init(id: UUID = UUID(),
         name: String,
         host: String,
         port: UInt16 = 139,
         shareName: String,
         username: String = "",
         password: String = "",
         lastConnectedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.shareName = shareName
        self.username = username
        self.password = password
        self.lastConnectedAt = lastConnectedAt
    }

    /// 是否为匿名（Guest）访问。
    var isAnonymous: Bool {
        username.isEmpty
    }

    /// 用于 AMSMB2 连接的 URL，形如 smb://user:pass@host:port
    /// 实际连接时由 SMBService 组装，这里仅作展示用途。
    var displayURL: String {
        "smb://\(host):\(port)/\(shareName)"
    }
}

extension ServerConfig {
    /// 创建一份用于"新增"表单的空配置。
    static func empty() -> ServerConfig {
        ServerConfig(name: "", host: "", shareName: "")
    }
}
