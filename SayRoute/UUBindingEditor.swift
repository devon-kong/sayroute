import SwiftUI

struct UUDeviceSettingsRow: Identifiable {
    let id: String
    var name: String
    var detected: Bool
    var isOnline: Bool?
    var saved: UUBinding?
    var alias: String
    var port: String
    var message: String?
    var checkID: UUID?
    var checkResult: UUDeviceCheck?

    init(id: String, name: String, device: UUDevice?, saved: UUBinding?) {
        self.id = id
        self.name = name
        self.detected = device != nil
        self.isOnline = device?.isOnline
        self.saved = saved
        self.alias = saved?.alias ?? ""
        self.port = saved.map { String($0.port) } ?? ""
    }

    var hasEdits: Bool {
        alias != (saved?.alias ?? "") || port != (saved.map { String($0.port) } ?? "")
    }

    var needsSave: Bool { hasEdits || (saved != nil && saved?.name != name) }

    var availability: String {
        if let isOnline { return isOnline ? "在线" : "离线" }
        return detected ? "在线状态未知" : "UU 列表未确认"
    }

    mutating func clearCheck() {
        checkID = nil
        checkResult = nil
    }
}

struct UUDeviceCheck: Equatable {
    let port: UInt16
    let controlling: Bool?
    let bridge: BridgeStatus

    enum BridgeStatus: Equatable {
        case ready(BridgeHealth)
        case incompatible(Int)
        case invalidResponse
        case unavailable
    }

    var controlText: String {
        switch controlling {
        case true: return "远控已连接"
        case false: return "无活动远控连接"
        default: return "无法读取 UU 连接状态"
        }
    }

    var bridgeText: String {
        switch bridge {
        case let .ready(health):
            let build = health.helperBuild.map { " · \($0)" } ?? ""
            return "Bridge 已连接 · 协议 v\(health.protocolVersion)\(build)"
        case let .incompatible(version):
            return "Bridge 协议 v\(version) 不兼容，需要 v\(RemoteClipboardClient.protocolVersion)"
        case .invalidResponse: return "端口有响应，但未返回有效的 Bridge 健康信息"
        case .unavailable: return "无法连接 Bridge，请核对端口映射和远端服务"
        }
    }

    var accessibilityText: String {
        guard case let .ready(health) = bridge else { return "无法确认" }
        switch health.accessibilityTrusted {
        case true: return "已授权"
        case false: return "未授权，请在被控 Mac 的系统设置中允许 Bridge 使用辅助功能"
        default: return "此 Bridge 未报告"
        }
    }
}

@MainActor
final class UUDeviceSettingsModel: ObservableObject {
    @Published private(set) var rows: [UUDeviceSettingsRow]
    @Published private(set) var refreshing = false
    @Published private(set) var listUnavailable = false

    private let store: UUBindingStore

    init(store: UUBindingStore = UUBindingStore()) {
        self.store = store
        rows = store.bindings.map {
            UUDeviceSettingsRow(id: $0.deviceId, name: $0.name, device: nil, saved: $0)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func refresh(fetch: () async throws -> [UUDevice] = UUDevices.devices) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let devices = try? await fetch()
        guard !Task.isCancelled else { return }
        listUnavailable = devices == nil
        let previous = rows
        var merged = [String: UUDeviceSettingsRow]()
        for saved in store.bindings {
            merged[saved.deviceId] = UUDeviceSettingsRow(id: saved.deviceId, name: saved.name, device: nil, saved: saved)
        }
        for device in devices ?? [] where device.platform == "mac" {
            merged[device.deviceId] = UUDeviceSettingsRow(id: device.deviceId, name: device.deviceName,
                                                         device: device, saved: merged[device.deviceId]?.saved)
        }
        for old in previous {
            // A refresh can finish while the user is typing, including when UU
            // temporarily omits the device. Keep the editable row in that case.
            if merged[old.id] == nil, old.hasEdits || devices == nil {
                merged[old.id] = UUDeviceSettingsRow(id: old.id, name: old.name, device: nil, saved: nil)
            }
            if devices == nil { merged[old.id]?.name = old.name }
            if old.hasEdits {
                merged[old.id]?.alias = old.alias
                merged[old.id]?.port = old.port
            }
            if merged[old.id]?.port == old.port {
                merged[old.id]?.checkID = old.checkID
                merged[old.id]?.checkResult = old.checkResult
                merged[old.id]?.message = old.message
            }
        }
        rows = merged.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func edit(_ id: String, field: WritableKeyPath<UUDeviceSettingsRow, String>, value: String) {
        guard let index = index(of: id), rows[index][keyPath: field] != value else { return }
        rows[index][keyPath: field] = value
        rows[index].message = nil
        if field == \UUDeviceSettingsRow.port { rows[index].clearCheck() }
    }

    private func index(of id: String) -> Int? { rows.firstIndex { $0.id == id } }

    private func validatedPort(at index: Int) -> UInt16? {
        let row = rows[index]
        guard let port = UInt16(row.port.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
            rows[index].message = "请输入 1 到 65535 之间的本地端口。"
            return nil
        }
        if store.bindings.contains(where: { $0.deviceId != row.id && $0.port == port }) {
            rows[index].message = "此端口已绑定其他设备，请核对 UU 映射。"
            return nil
        }
        return port
    }

    func save(_ id: String) {
        guard let index = index(of: id), let port = validatedPort(at: index) else { return }
        let row = rows[index]
        let alias = row.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let binding = UUBinding(deviceId: id, name: row.name, port: port, alias: alias.isEmpty ? nil : alias)
        do {
            try store.save(binding)
            rows[index].saved = binding
            rows[index].alias = alias
            rows[index].port = String(port)
            rows[index].message = nil
        } catch {
            rows[index].message = "无法保存绑定，请核对设备和端口后重试。"
        }
    }

    func remove(_ id: String) {
        guard let index = index(of: id) else { return }
        store.remove(id)
        if rows[index].detected {
            rows[index].saved = nil
            rows[index].alias = ""
            rows[index].port = ""
            rows[index].message = nil
            rows[index].clearCheck()
        } else {
            rows.remove(at: index)
        }
    }

    func check(_ id: String, connections: () async throws -> [UUConnection] = UUDevices.connections,
               health: (UInt16) async throws -> BridgeHealth = { port in
                   try await RemoteClipboardClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!).health()
               }) async {
        guard let index = index(of: id), let port = validatedPort(at: index) else { return }
        let token = UUID()
        rows[index].message = nil
        rows[index].checkResult = nil
        rows[index].checkID = token
        async let currentConnections = try? connections()
        let bridge: UUDeviceCheck.BridgeStatus
        do {
            bridge = .ready(try await health(port))
        } catch RemoteClipboardClientError.unsupportedProtocol(let version) {
            bridge = .incompatible(version)
        } catch is URLError {
            bridge = .unavailable
        } catch {
            bridge = .invalidResponse
        }
        let controlling = await currentConnections?.contains { $0.deviceId == id && $0.platform == "mac" && $0.isActive }
        guard let current = self.index(of: id), rows[current].checkID == token else { return }
        rows[current].checkID = nil
        rows[current].checkResult = UUDeviceCheck(port: port, controlling: controlling, bridge: bridge)
    }
}

@MainActor
struct UUDeviceSettingsView: View {
    @ObservedObject var model: UUDeviceSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("UU 快速模式设备").font(.title2.bold())
                    Spacer()
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(model.refreshing ? "刷新中…" : "刷新设备", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.refreshing)
                }
                Text("设备名由 UU 自动读取。为每台 Mac 填写本地映射端口，可另设听写时显示的名称。")
                    .foregroundStyle(.secondary)
                if model.listUnavailable {
                    Label("无法读取 UU 设备列表，请确认 UU 已启动后刷新。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if model.rows.isEmpty && !model.refreshing {
                    Text("未发现被控 Mac。请先在 UU 中添加设备，再刷新列表。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rows) { row in
                    deviceCard(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task { await model.refresh() }
    }

    private func input(_ field: WritableKeyPath<UUDeviceSettingsRow, String>, for row: UUDeviceSettingsRow) -> Binding<String> {
        Binding(get: { model.rows.first { $0.id == row.id }?[keyPath: field] ?? "" },
                set: { model.edit(row.id, field: field, value: $0) })
    }

    private func deviceCard(_ row: UUDeviceSettingsRow) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(row.saved?.alias ?? row.name, systemImage: "desktopcomputer").font(.headline)
                    Spacer()
                    Text(row.availability).foregroundStyle(.secondary)
                }
                if row.saved?.alias != nil || model.rows.contains(where: { $0.id != row.id && $0.name == row.name }) {
                    Text("UU 设备名：\(row.name)  ·  ID 尾号 \(row.id.suffix(6))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("显示名")
                        TextField(row.name, text: input(\.alias, for: row))
                            .accessibilityLabel("显示名")
                    }
                    GridRow {
                        Text("本地端口")
                        TextField("1–65535", text: input(\.port, for: row))
                            .accessibilityLabel("本地端口")
                    }
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button(row.saved == nil ? "保存绑定" : (row.needsSave ? "保存更改" : "已保存")) {
                        model.save(row.id)
                    }
                    .disabled(!row.needsSave)
                    Button(row.checkID == nil ? "检查连接" : "检查中…") {
                        Task { await model.check(row.id) }
                    }
                    .disabled(row.checkID != nil || row.port.isEmpty)
                    Spacer()
                    if row.saved != nil {
                        Button("解除绑定", role: .destructive) { model.remove(row.id) }
                    }
                }
                if let message = row.message {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                }
                if let result = row.checkResult {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("上次检查").font(.caption).foregroundStyle(.secondary)
                        Text("UU：\(result.controlText)")
                        Text("端口 \(String(result.port))：\(result.bridgeText)")
                        Text("远端辅助功能：\(result.accessibilityText)")
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
