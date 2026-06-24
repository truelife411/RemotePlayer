//
//  RemotePlayerApp.swift
//  RemotePlayer
//
//  应用入口。使用 SwiftUI App 生命周期，注入全局 AppCoordinator。
//

import SwiftUI

@main
struct RemotePlayerApp: App {

    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .preferredColorScheme(.dark)
                .tint(.accentColor)
        }
    }
}

/// 根视图：用 NavigationSplitView 实现自适应布局。
///
/// - iPad（regular size class）：左侧边栏常驻服务器列表，右侧详情列展示文件浏览器。
/// - iPhone（compact size class）：SplitView 自动折叠为 push 栈，
///   点服务器 → 推出 FileBrowser，和单 NavigationStack 行为一致。
///
/// 关键：SplitView 的详情列 push/选择行为由 `selectedServerID` 驱动。
/// 仅靠外部状态（connectedServer）改变详情列内容，在 iPhone compact 下不会自动触发
/// 详情列的推出动画——必须用 selection 绑定，SplitView 才会把它识别为"推出详情"的信号。
/// 连接成功 → 设置 selectedServerID → SplitView push 详情列 → 显示 FileBrowser；
/// 断开/选择清除 → selectedServerID = nil → 详情列回占位。
struct RootView: View {

    @Environment(AppCoordinator.self) private var coordinator
    /// 当前选中的服务器 ID；驱动 NavigationSplitView 详情列的展示。
    /// 非 nil 时 SplitView 在 iPhone 上会推出详情列。
    /// 由 ServerListView.connect 成功时设置；断开连接时清除。
    @State private var selectedServerID: UUID?

    var body: some View {
        NavigationSplitView {
            ServerListView(selection: $selectedServerID)
        } detail: {
            if coordinator.connectedServer != nil, selectedServerID != nil {
                // 已连接且选中了服务器：展示文件浏览器
                FileBrowserView()
            } else {
                // 未连接或未选中：占位
                ContentUnavailableView {
                    Label("选择一台服务器", systemImage: "externaldrive.connected.to.line.below")
                } description: {
                    Text("在左侧选择或添加一台 SMB 服务器开始浏览")
                }
                .navigationTitle("RemotePlayer")
            }
        }
        .navigationSplitViewStyle(.balanced)
        // 断开连接时（删除服务器等）清除选中，详情列回到占位
        .onChange(of: coordinator.connectedServer?.id) { newID in
            if newID == nil {
                selectedServerID = nil
            }
        }
    }
}

