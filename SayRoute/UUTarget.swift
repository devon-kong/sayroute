import AppKit
import ApplicationServices

struct UUBinding: Codable, Equatable {
    let deviceId: String
    let name: String
    let port: UInt16
    let alias: String?

    init(deviceId: String, name: String, port: UInt16, alias: String? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.port = port
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.alias = trimmed?.isEmpty == false ? trimmed : nil
    }

    var displayName: String { alias ?? name }
}

struct UUBindingStore {
    private let defaults: UserDefaults
    private let key = "uuFastDeviceBindings"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var bindings: [UUBinding] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UUBinding].self, from: data)) ?? []
    }

    func save(_ binding: UUBinding) throws {
        var updated = bindings.filter { $0.deviceId != binding.deviceId }
        guard binding.port != 0, !binding.deviceId.isEmpty,
              !updated.contains(where: { $0.port == binding.port }) else {
            throw PasteFailureReason.uuInvalidBinding
        }
        updated.append(binding)
        defaults.set(try JSONEncoder().encode(updated), forKey: key)
    }

    func remove(_ deviceId: String) {
        let updated = bindings.filter { $0.deviceId != deviceId }
        if let data = try? JSONEncoder().encode(updated) { defaults.set(data, forKey: key) }
    }
}

struct UUConnection: Decodable {
    let deviceId: String
    let deviceName: String
    let platform: String
    let connectionState: String
    let isControlling: Bool
    let connectionStartTime: String

    var isActive: Bool { isControlling && connectionState == "connected" }
}

struct UUTarget: Equatable {
    let deviceId: String
    let name: String
    let displayName: String
    let port: UInt16
    private let connectionStartTime: String
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    static func resolve(labels: [String], connections: [UUConnection], bindings: [UUBinding]) throws -> Self {
        let names = Set(labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let matches = connections.filter { $0.isActive && names.contains($0.deviceName) }
        guard matches.count == 1, let connection = matches.first, connection.platform == "mac" else {
            throw PasteFailureReason.uuWindowUnidentified
        }
        let registered = bindings.filter { names.contains($0.name) }
        guard registered.count == 1, let binding = registered.first, binding.deviceId == connection.deviceId,
              binding.name == connection.deviceName,
              binding.port > 0,
              bindings.filter({ $0.port == binding.port }).count == 1 else { throw PasteFailureReason.uuInvalidBinding }
        return Self(deviceId: connection.deviceId, name: connection.deviceName,
                    displayName: binding.displayName, port: binding.port,
                    connectionStartTime: connection.connectionStartTime)
    }

    // Recheck the captured session and configuration. Focus now belongs to the IME
    // or a later session, so it must never select a delivery endpoint here.
    func validate(connections: [UUConnection], bindings: [UUBinding]) throws {
        guard connections.contains(where: { $0.deviceId == deviceId && $0.isActive &&
            $0.connectionStartTime == connectionStartTime }) else { throw PasteFailureReason.uuDisconnected }
        let current = try Self.resolve(labels: [name], connections: connections, bindings: bindings)
        // Display aliases can change while a request is in flight.
        guard current.deviceId == deviceId, current.port == port,
              current.connectionStartTime == connectionStartTime else { throw PasteFailureReason.uuInvalidBinding }
    }
}

enum UUWindowCapture {
    static func isRemoteWindow(title: String, roles: [String]) -> Bool {
        title.isEmpty && roles.contains(kAXImageRole) && roles.contains(kAXStaticTextRole) &&
            !roles.contains(kAXSplitGroupRole) && !roles.contains(kAXToolbarRole) && !roles.contains(kAXScrollAreaRole)
    }

    /// Toolbar order changes with UU's controls and stream statistics. Only
    /// exact registered UU names in direct static labels can select a device.
    static func deviceName(title: String, roles: [String], knownNames: Set<String>,
                           textValue: (Int) -> String?) -> String? {
        guard isRemoteWindow(title: title, roles: roles), !knownNames.isEmpty else { return nil }
        var match: String?
        for index in roles.indices where roles[index] == kAXStaticTextRole {
            guard let text = textValue(index)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  knownNames.contains(text) else { continue }
            if let match, match != text { return nil }
            match = text
        }
        return match
    }

}

struct UUDevice: Decodable {
    let deviceId: String
    let deviceName: String
    let platform: String
    let isOnline: Bool?

    init(deviceId: String, deviceName: String, platform: String, isOnline: Bool? = nil) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.isOnline = isOnline
    }
}

enum UUDevices {
    private struct Reply<T: Decodable>: Decodable { let success: Bool; let data: T }
    private struct Status: Decodable { let connections: [UUConnection] }
    private struct Listing: Decodable { let items: [UUDevice] }

    static func connections() async throws -> [UUConnection] {
        let result: Status = try await query("status")
        return result.connections
    }

    static func devices() async throws -> [UUDevice] {
        let result: Listing = try await query("list")
        return result.items.filter { $0.platform == "mac" }
    }

    // Do not load device account files or block the main actor waiting for UU's XPC reply.
    private static func query<T: Decodable>(_ command: String) async throws -> T {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PasteRouter.uuBundleIdentifier) else {
            throw PasteFailureReason.uuStatusUnavailable
        }
        return try await Task.detached {
            let process = Process()
            process.executableURL = app.appendingPathComponent("Contents/Helpers/uuyc-cli")
            process.arguments = ["device", command, "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw PasteFailureReason.uuStatusUnavailable }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
            defer { timeout.cancel() }
            let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let reply = try? JSONDecoder().decode(Reply<T>.self, from: bytes),
                  reply.success else { throw PasteFailureReason.uuStatusUnavailable }
            return reply.data
        }.value
    }
}
