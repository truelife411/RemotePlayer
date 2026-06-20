# RemotePlayer · SMB 远程媒体播放器

一款轻量、纯粹的局域网流媒体播放器，专注于通过 SMB/CIFS 协议远程浏览和播放 Windows 共享目录下的视频与图片。**不包含文件下载、本地存储或远程文件修改功能**。

## ✨ 功能特性

### 网络连接
- 多服务器管理，支持别名、一键连接、匿名/账密登录
- 自动记忆最近连接

### 文件浏览（只读）
- 排序：名称 / 大小 / 修改时间（升降序）
- 筛选：全部 / 仅视频 / 仅图片
- 关键词模糊搜索
- 视频缩略图、断点续播进度条

### 视频播放（UIKit + VLCKit）
- 全格式解码：MKV / AVI / RMVB / FLV / TS / MP4 等
- 倍速播放 0.5x – 2.0x
- 单帧前进 / 后退
- 断点续播
- 精准进度条拖拽跳转
- 字幕：内嵌轨道切换 + 同目录同名外挂 SRT/ASS/SSA/VTT 自动加载
- 手势：
  - 左右滑动快进快退
  - 左侧上下滑动调亮度
  - 右侧上下滑动调音量
  - 双指缩放画面（放大后可拖拽）
  - 单击显隐控制层、双击播放/暂停

### 图片浏览（SwiftUI）
- 渐进式加载：先显示低清模糊图，后台加载原图无缝替换
- 双指缩放、双击放大/还原
- 左右滑动切换

## 🏗️ 架构

### 数据流（视频播放）
```
用户点击视频
  → PlayerViewModel.prepare()
      → SMBService.attributes()            获取文件大小
      → SMBService.findExternalSubtitle()  查找外挂字幕
      → ProxyServer.registerStream()       注册本地代理路由
  → VLCMedia(url: http://127.0.0.1:{port}/stream/{token})
  → VLCKit 发起 HTTP GET（含 Range 头）
  → ProxyServer 路由命中 → StreamHandler.makeResponse()
  → StreamingHTTPResponse.writeBody 启动异步 Task
  → SMBService.readFile(offset, length)    按字节范围拉取
  → 分块写入 socket → VLCKit 解码播放
```

### 核心设计：本地 HTTP 代理桥接
VLCKit 需要 URL 才能播放，但 SMB 文件没有 URL。方案：
1. Telegraph 在 `127.0.0.1` 启动本地 HTTP 服务
2. 每次播放注册一个 token 路由
3. 自定义 `StreamingHTTPResponse` 重写 `writeBody`，异步从 SMB 分块拉取并写入 socket
4. 完整支持 HTTP Range（206 Partial Content），进度条拖拽即字节范围请求

> 该方案完美支持 GB 级视频流式播放，**不把整个文件读入内存**。

### 技术栈
| 组件 | 选型 | 说明 |
|------|------|------|
| UI 框架 | SwiftUI + UIKit | SwiftUI 做列表/浏览，UIKit 做播放器（手势/控制层） |
| SMB 协议 | AMSMB2 4.x | 基于 libsmb2，async API |
| 播放内核 | MobileVLCKit 4.x | 全格式解码 |
| 本地代理 | Telegraph 0.40 | Swift 原生 HTTP 服务器 |
| 状态管理 | `@Observable`（iOS 17+） | 无第三方依赖 |
| 包管理 | CocoaPods（统一） | AMSMB2 + VLCKit + Telegraph |
| 工程生成 | XcodeGen | `project.yml` → `.xcodeproj` |

## 📦 目录结构
```
RemotePlayer/
├── project.yml                  # XcodeGen 配置
├── Podfile                      # CocoaPods 依赖
└── RemotePlayer/
    ├── App/                     # @main 入口
    ├── Models/                  # ServerConfig / SMBFile / PlaybackState / AppError
    ├── Services/                # SMBService / ProxyServer / StreamHandler / ...
    ├── ViewModels/              # AppCoordinator / FileBrowserVM / PlayerVM
    └── Views/
        ├── SwiftUI/             # 列表/浏览/图片查看/播放器桥接
        └── UIKit/               # PlayerViewController / Overlay / Gesture
```

## 🚀 构建指南

### 环境要求
- macOS 14+
- Xcode 16+
- iOS 17.0+ 部署目标
- 已安装：CocoaPods、XcodeGen

```bash
# 1. 安装工具（如尚未安装）
brew install cocoapods xcodegen

# 2. 生成 Xcode 工程
cd RemotePlayer
xcodegen generate

# 3. 安装依赖（AMSMB2 / MobileVLCKit / Telegraph）
pod install

# 4. 打开 workspace 构建（注意是 .xcworkspace，不是 .xcodeproj）
open RemotePlayer.xcworkspace
```

### 重要配置
- **开发团队**：在 Xcode → Signing & Capabilities 设置 `DEVELOPMENT_TEAM`
- **Info.plist**：已配置 `NSAllowsLocalNetworking`（本地代理必需）、`NSLocalNetworkUsageDescription`
- **Bridging Header**：已配置，引入 `MobileVLCKit`

### 首次使用
1. 在 Windows 上右键文件夹 → 共享 → 设置共享名
2. 确认 SMB 服务已开启（控制面板 → 程序 → 启用 SMB 1.0/CIFS）
3. App 内添加服务器：填入 IP、共享名、账号密码
4. 点击连接 → 浏览 → 播放

## ⚠️ 已知约束
- AMSMB2 不支持 SPM（仅 CocoaPods/Accio），故全部依赖统一用 CocoaPods
- VLCKit 4.x 移除了 3.x 所有废弃 API，代码已按 4.x API 编写
- 视频缩略图依赖播放器首帧截图（首次播放后生成）

## 📄 许可
本应用仅供学习交流。VLCKit 遵循 LGPLv2.1，AMSMB2 遵循 MIT，Telegraph 遵循 MIT。
