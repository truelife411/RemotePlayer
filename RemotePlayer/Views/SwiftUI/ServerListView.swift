//
//  ServerListView.swift
//  RemotePlayer
//
//  服务器列表页：展示已保存的服务器，支持新增/编辑/删除/连接。
//

import SwiftUI

struct ServerListView: View {

    @Environment(AppCoordinator.self) private var coordinator
    @State private var servers: [ServerConfig] = []
    @State private var editingServer: ServerConfig?
    @State private var showAddSheet = false
    @State private var connectingID: UUID?
    @State private var navigateToBrowser = false

    var body: some View {
        NavigationStack {
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
            .navigationDestination(isPresented: $navigateToBrowser) {
                FileBrowserView()
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
        }
        .task { reload() }
    }

    // MARK: - 子视图

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有服务器", systemImage: "externaldrive.connected.to.line.below")
        } description: {
            Text("点击右上角添加一台 Windows 共享服务器")
        }
    }

    private var serverList: some View {
        List {
            ForEach(servers) { server in
                Button {
                    Task { await connect(to: server) }
                } label: {
                    ServerRow(server: server,
                              isConnecting: connectingID == server.id,
                              isConnected: coordinator.connectedServer?.id == server.id)
                }
                .buttonStyle(.plain)
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
        let ok = await coordinator.connect(to: server)
        if ok {
            navigateToBrowser = true
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
    ServerListView()
        .environment(AppCoordinator())
}
