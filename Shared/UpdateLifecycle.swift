import AppKit
import Darwin
import Foundation

struct UpdatePlan: Codable {
    let nonce: UUID
    let parentPID: Int32
    let target: URL
    let incoming: URL
    let current: UpdateIdentity
    let candidate: UpdateIdentity
    var stage: URL { incoming.deletingLastPathComponent() }
    var receiptURL: URL { stage.appendingPathComponent("ready.json") }

    func validatePaths() throws {
        guard parentPID > 1, target.isFileURL, incoming.isFileURL,
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(".sayroute-update-".count))) == nonce else {
            throw SafeUpdateError.unsafePath
        }
        try UpdatePaths.validate(target: target, incoming: incoming)
    }
    func validatePackages() throws {
        try validatePaths()
        let old = try UpdateSignature.identity(at: target), new = try UpdateSignature.identity(at: incoming)
        guard old == current, new == candidate else { throw SafeUpdateError.identityMismatch }
        try UpdatePolicy.validate(current: old, candidate: new, expectedVersion: candidate.version)
    }
}

struct UpdateLaunchReceipt: Codable {
    let nonce: UUID
    let pid: Int32
    let appPath: String
    let bundleID: String
    let version: String
    let build: String
    func matches(nonce: UUID, pid: Int32, target: URL, identity: UpdateIdentity) -> Bool {
        self.nonce == nonce && self.pid == pid && appPath == target.path && bundleID == identity.bundleID
            && version == identity.version && build == identity.build
    }
}

enum UpdateStartupReceipt {
    @discardableResult
    static func writeIfRequested(arguments: [String] = CommandLine.arguments, bundle: Bundle = .main) -> Bool {
        guard let index = arguments.firstIndex(of: "--sayroute-update-stage"), index + 1 < arguments.count,
              let tokenIndex = arguments.firstIndex(of: "--sayroute-update-nonce"), tokenIndex + 1 < arguments.count,
              let nonce = UUID(uuidString: arguments[tokenIndex + 1]) else { return false }
        let stage = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        do {
            try UpdatePaths.requireNoSymlinks(stage)
            guard stage.lastPathComponent == ".sayroute-update-" + nonce.uuidString,
                  stage.deletingLastPathComponent().standardizedFileURL.path == bundle.bundleURL.deletingLastPathComponent().standardizedFileURL.path else { return false }
            let plan = try JSONDecoder().decode(UpdatePlan.self, from: Data(contentsOf: stage.appendingPathComponent("plan.json")))
            try plan.validatePaths()
            guard plan.nonce == nonce, plan.target.standardizedFileURL.path == bundle.bundleURL.standardizedFileURL.path,
                  bundle.bundleIdentifier == plan.candidate.bundleID,
                  bundle.infoDictionary?["CFBundleVersion"] as? String == plan.candidate.build,
                  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == plan.candidate.version else { return false }
            let receipt = UpdateLaunchReceipt(nonce: nonce, pid: getpid(), appPath: bundle.bundleURL.path,
                bundleID: plan.candidate.bundleID, version: plan.candidate.version, build: plan.candidate.build)
            try JSONEncoder().encode(receipt).write(to: plan.receiptURL, options: .atomic)
            return true
        } catch { return false }
    }
}

enum UpdatePreparation {
    static func prepare(archive: URL, currentApp: URL, expectedVersion: String, parentPID: Int32) throws -> UpdatePlan {
        let current = try UpdateSignature.identity(at: currentApp)
        try UpdatePolicy.requireTrustedRelease(current)
        guard let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= UpdateArchive.maximumArchiveBytes else { throw SafeUpdateError.unsafeArchive }
        let root = try UpdateArchive.applicationRoot(in: Data(contentsOf: archive))
        let fm = FileManager.default, nonce = UUID()
        let stage = currentApp.deletingLastPathComponent().appendingPathComponent(".sayroute-update-" + nonce.uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var prepared = false
        defer { if !prepared { try? fm.removeItem(at: stage) } }
        let unpacked = stage.appendingPathComponent("unpacked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, unpacked.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SafeUpdateError.unsafeArchive }
        let extracted = unpacked.appendingPathComponent(root)
        let candidate = try UpdateSignature.identity(at: extracted)
        try UpdatePolicy.validate(current: current, candidate: candidate, expectedVersion: expectedVersion)
        let incoming = stage.appendingPathComponent(currentApp.lastPathComponent)
        try fm.moveItem(at: extracted, to: incoming)
        let plan = UpdatePlan(nonce: nonce, parentPID: parentPID, target: currentApp, incoming: incoming, current: current, candidate: candidate)
        try plan.validatePackages()
        // Copy the already signed installer out of the bundle before swapping it.
        try fm.copyItem(at: currentApp.appendingPathComponent("Contents/Helpers/sayroute-updater"), to: stage.appendingPathComponent("installer"))
        try JSONEncoder().encode(plan).write(to: stage.appendingPathComponent("plan.json"), options: .atomic)
        prepared = true
        return plan
    }
}

enum UpdateRunner {
    static func run(planURL: URL) throws -> UpdateSwapTransaction.Result {
        try UpdatePaths.requireNoSymlinks(planURL)
        guard planURL.lastPathComponent == "plan.json" else { throw SafeUpdateError.unsafePath }
        let plan = try JSONDecoder().decode(UpdatePlan.self, from: Data(contentsOf: planURL))
        guard planURL.deletingLastPathComponent().standardizedFileURL.path == plan.stage.standardizedFileURL.path else { throw SafeUpdateError.unsafePath }
        try plan.validatePackages()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while kill(plan.parentPID, 0) == 0 || errno == EPERM {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SafeUpdateError.processStillRunning }
            Thread.sleep(forTimeInterval: 0.1)
        }
        var running: NSRunningApplication?
        let result = try UpdateSwapTransaction.run(target: plan.target, incoming: plan.incoming,
            validate: { try plan.validatePackages() }, launch: {
                running = try NSWorkspace.shared.launchApplication(at: plan.target, options: [.newInstance], configuration: [
                    .arguments: ["--sayroute-update-stage", plan.stage.path, "--sayroute-update-nonce", plan.nonce.uuidString]
                ])
                guard let pid = running?.processIdentifier else { throw SafeUpdateError.startupFailed }
                return pid
            }, waitUntilReady: { pid in
                let deadline = ProcessInfo.processInfo.systemUptime + 20
                while ProcessInfo.processInfo.systemUptime < deadline {
                    guard let app = running, !app.isTerminated else { return false }
                    if let data = try? Data(contentsOf: plan.receiptURL),
                       let receipt = try? JSONDecoder().decode(UpdateLaunchReceipt.self, from: data),
                       receipt.matches(nonce: plan.nonce, pid: pid, target: plan.target, identity: plan.candidate) {
                        RunLoop.current.run(until: Date().addingTimeInterval(1))
                        return !app.isTerminated
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                return false
            }, stop: { pid in
                guard let app = running, app.processIdentifier == pid,
                      app.bundleURL?.standardizedFileURL.path == plan.target.standardizedFileURL.path else { return false }
                if app.isTerminated { return true }
                _ = app.terminate()
                let limit = ProcessInfo.processInfo.systemUptime + 3
                while !app.isTerminated && ProcessInfo.processInfo.systemUptime < limit {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                // Do not forcibly kill an unresponsive app or discard user work.
                return app.isTerminated
            })
        let record = ["result": result.rawValue, "backupPath": plan.incoming.path, "target": plan.target.path]
        try? JSONSerialization.data(withJSONObject: record).write(to: plan.stage.appendingPathComponent("result.json"), options: .atomic)
        if result == .rolledBack {
            _ = try NSWorkspace.shared.launchApplication(at: plan.target, options: [.newInstance], configuration: [:])
        }
        return result
    }
}
