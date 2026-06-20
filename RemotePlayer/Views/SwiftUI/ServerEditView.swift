//
//  ServerEditView.swift
//  RemotePlayer
//
//  服务器新增 / 编辑表单。
//  校验：名称、主机、共享名必填。
//

import SwiftUI

struct ServerEditView: View {

    /// 编辑目标；nil 表示新增。
    let server: ServerConfig?
    /// 完成回调（保存时触发）。
    var onSave: (ServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = "139"
    @State private var shareName: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showPassword = false
    @State private var testing = false
    @State private var testResult: String?

    init(server: ServerConfig?, onSave: @escaping (ServerConfig) -> Void) {
        self.server = server
        self.onSave = onSave
    }

    private var isEditing: Bool { server != nil }

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !shareName.trimmingCharacters(in: .whitespaces).isEmpty &&
        (UInt16(port) != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("别名（如：家里PC）", text: $name)
                        .textInputAutocapitalization(.never)
                    TextField("主机 IP 或主机名", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("共享名称", text: $shareName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("登录（留空为匿名访问）") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        if showPassword {
                            TextField("密码", text: $password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("密码", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section {
                    Button(testing ? "正在测试…" : "测试连接", action: testConnection)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.caption)
                            .foregroundStyle(testResult.hasPrefix("✓") ? .green : .red)
                    }
                }
                .disabled(!isValid)
            }
            .navigationTitle(isEditing ? "编辑服务器" : "添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                        .bold()
                }
            }
            .onAppear { populate() }
        }
    }

    // MARK: - 动作

    private func populate() {
        guard let server else { return }
        name = server.name
        host = server.host
        port = "\(server.port)"
        shareName = server.shareName
        username = server.username
        password = server.password
    }

    private func save() {
        let config = ServerConfig(
            id: server?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 139,
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username,
            password: password,
            lastConnectedAt: server?.lastConnectedAt
        )
        onSave(config)
        dismiss()
    }

    private func testConnection() {
        guard isValid else { return }
        testing = true
        testResult = nil
        let config = ServerConfig(
            id: UUID(),
            name: name,
            host: host.trimmingCharacters(in: .whitespaces),
            port: UInt16(port) ?? 139,
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username,
            password: password
        )
        // 用临时 SMBService 测试，不影响主连接
        let probe = SMBService()
        Task {
            do {
                try await probe.connect(config)
                await MainActor.run {
                    testResult = "✓ 连接成功"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testResult = "✗ \(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }
}
