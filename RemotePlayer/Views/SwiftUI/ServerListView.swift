//
//  ServerListView.swift
//  RemotePlayer
//
//  服务器列表页（侧边栏）：展示已保存的服务器，支持新增/编辑/删除/连接。
//  作为 NavigationSplitView 的 sidebar 使用——不再自带 NavigationStack，
//  导航与详情列切换交给 RootView 监听 coordinator.connectedServer 驱动。
//

import SwiftUI

struct ServerListView: View {

    /// 外部传入的选中绑定：连接成功后设置它，驱动 NavigationSplitView 在 iPhone 上推出详情列。
    /// 作为 List 的 selection，iPad 上高亮选中行、iPhone 上触发 push。
    @Binding var selection: UUID?

    @Environment(AppCoordinator.self) private var coordinator
    @State private var servers: [ServerConfig] = []
    @State private var editingServer: ServerConfig?
    @State private var showAddSheet = false
    @State private var connectingID: UUID?

    var body: some View {
        Group {
            if servers.isEmpty {
                emptyState
            } else {
                serverList
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ServerEditView(server: nil) { newConfig in
                ServerStore.shared.upsert(newConfig)
                reload()
            }
        }
        .sheet(item: $editingServer) { config in
            ServerEditView(server: config) { updated in
                ServerStore.shared.upsert(updated)
                reload()
            }
        }
        .alert("连接失败",
               isPresented: Binding(get: { coordinator.lastError != nil },
                                    set: { if !$0 { coordinator.clearError() } })) {
            Button("好") { coordinator.clearError() }
        } message: {
            if let err = coordinator.lastError {
                Text(err.errorDescription ?? "未知错误")
            }
        }
        .task { reload() }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有服务器", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text("点击右上角添加一台 SMB 共享服务器")
        }
    }

    private var serverList: some View {
        List(selection: Binding(
            get: { selection },
            set: { selection = $0 }
        )) {
            ForEach(servers) { server in
                // 用 server.id 作 tag，配合 List selection
                ServerRow(server: server,
                          isConnecting: connectingID == server.id,
                          isConnected: coordinator.connectedServer?.id == server.id)
                    .tag(server.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await connect(to: server) }
                    }
                    // 左滑出 编辑/删除
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            delete(server)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            editingServer = server
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 动作

    private func reload() {
        servers = ServerStore.shared.loadAll()
    }

    private func connect(to server: ServerConfig) async {
        connectingID = server.id
        defer { connectingID = nil }
        // 连接成功后：coordinator.connectedServer 被设置 + 设置 selection 触发 SplitView push
        let ok = await coordinator.connect(to: server)
        if ok {
            selection = server.id
        }
    }

    private func delete(_ server: ServerConfig) {
        ServerStore.shared.delete(id: server.id)
        if coordinator.connectedServer?.id == server.id {
            coordinator.disconnect()
        }
        reload()
    }
}

// MARK: - 服务器行

private struct ServerRow: View {
    let server: ServerConfig
    let isConnecting: Bool
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isConnected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: isConnected ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(isConnected ? Color.accentColor : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name.isEmpty ? server.host : server.name)
                    .font(.headline)
                Text(server.displayURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isConnecting {
                ProgressView()
            } else if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ServerListView(selection: .constant(nil))
            .environment(AppCoordinator())
    }
}

