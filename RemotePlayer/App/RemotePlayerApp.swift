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

/// 根视图：目前直接展示服务器列表（连接后进入文件浏览）。
struct RootView: View {

    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ServerListView()
    }
}
