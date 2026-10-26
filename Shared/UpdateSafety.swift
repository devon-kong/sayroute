import Darwin
import Foundation
import Security

struct UpdateIdentity: Codable, Equatable {
    var bundleID: String
    var version: String
    var build: String
    var executable: String
    var teamID: String?
}

enum SafeUpdateError: LocalizedError {
    case manualInstallationRequired, identityMismatch, invalidVersion, invalidSignature
    case unsafeArchive, unsafePath, replacementFailed, rollbackFailed, processStillRunning, startupFailed
    var errorDescription: String? {
        switch self {
        case .manualInstallationRequired: return "当前应用的签名无法验证自动更新的发布者。请使用已核验的安装包手动更新。"
        case .identityMismatch: return "更新包的应用身份、发布者或发布渠道不匹配，原应用未被替换。"
        case .invalidVersion: return "更新包版本不符合本次更新，或不是更高版本。"
        case .invalidSignature: return "更新包签名验证失败，原应用未被替换。"
        case .unsafeArchive: return "更新压缩包的路径、文件类型或大小不安全，已停止安装。"
        case .unsafePath: return "更新路径不符合安全要求，已停止安装。"
        case .replacementFailed: return "无法原子替换应用，原应用仍保留。"
        case .rollbackFailed: return "自动恢复未完成；旧应用仍保留在更新备份目录。"
        case .processStillRunning: return "应用进程未退出，已停止替换；旧包仍保留。"
        case .startupFailed: return "新版未完成启动，已恢复旧版。"
        }
    }
}

enum UpdatePolicy {
    static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return nil }
        return parts.compactMap { Int($0) }
    }
    static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let r = components(remote), let c = components(current) else { return false }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0, b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
    static func requireTrustedRelease(_ identity: UpdateIdentity) throws {
        guard identity.bundleID == "com.devonkong.sayroute", let team = identity.teamID,
              team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            throw SafeUpdateError.manualInstallationRequired
        }
    }
    static func validate(current: UpdateIdentity, candidate: UpdateIdentity, expectedVersion: String) throws {
        try requireTrustedRelease(current)
        guard candidate.bundleID == current.bundleID, candidate.teamID == current.teamID,
              candidate.executable == current.executable else { throw SafeUpdateError.identityMismatch }
        guard candidate.version == expectedVersion, isNewer(candidate.version, than: current.version),
              let build = Int(candidate.build), build > 0 else { throw SafeUpdateError.invalidVersion }
    }
}

enum UpdateSignature {
    static func identity(at app: URL) throws -> UpdateIdentity {
        try UpdatePaths.requireNoSymlinks(app)
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        guard let id = plist?["CFBundleIdentifier"] as? String,
              let version = plist?["CFBundleShortVersionString"] as? String,
              let build = plist?["CFBundleVersion"] as? String,
              let executable = plist?["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), !executable.contains("..") else { throw SafeUpdateError.identityMismatch }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw SafeUpdateError.invalidSignature }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw SafeUpdateError.invalidSignature }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signing = information as? [String: Any], signing[kSecCodeInfoIdentifier as String] as? String == id else {
            throw SafeUpdateError.invalidSignature
        }
        let team = signing[kSecCodeInfoTeamIdentifier as String] as? String
        if let team {
            guard team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else { throw SafeUpdateError.invalidSignature }
            var requirement: SecRequirement?
            let rule = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw SafeUpdateError.invalidSignature }
        }
        return UpdateIdentity(bundleID: id, version: version, build: build, executable: executable, teamID: team)
    }
}

enum UpdatePaths {
    static func requireNoSymlinks(_ path: URL) throws {
        let standard = path.standardizedFileURL
        guard standard.resolvingSymlinksInPath().path == standard.path else { throw SafeUpdateError.unsafePath }
        if FileManager.default.fileExists(atPath: standard.path) {
            guard try standard.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SafeUpdateError.unsafePath }
        }
    }
    static func validate(target: URL, incoming: URL) throws {
        try requireNoSymlinks(target); try requireNoSymlinks(incoming)
        let stage = incoming.deletingLastPathComponent()
        guard target.pathExtension == "app", incoming.pathExtension == "app",
              target.lastPathComponent == incoming.lastPathComponent,
              stage.lastPathComponent.hasPrefix(".sayroute-update-"),
              stage.deletingLastPathComponent().standardizedFileURL.path == target.deletingLastPathComponent().standardizedFileURL.path,
              FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: incoming.path) else {
            throw SafeUpdateError.unsafePath
        }
    }
}

/// Only OS effects (signature, launch/readiness/termination) are replaceable in tests.
/// The actual filesystem transaction is always exercised, including rollback.
enum UpdateSwapTransaction {
    enum Result: String { case installed, rolledBack }
    static func run(target: URL, incoming: URL, validate: () throws -> Void,
                    launch: () throws -> Int32, waitUntilReady: (Int32) -> Bool,
                    stop: (Int32) -> Bool) throws -> Result {
        try UpdatePaths.validate(target: target, incoming: incoming)
        try validate()
        let candidateInode = try FileManager.default.attributesOfItem(atPath: incoming.path)[.systemFileNumber] as? NSNumber
        guard renamex_np(target.path, incoming.path, UInt32(RENAME_SWAP)) == 0 else { throw SafeUpdateError.replacementFailed }
        var launchedPID: Int32?
        do {
            let pid = try launch(); launchedPID = pid
            if waitUntilReady(pid) { return .installed }
        } catch {
            // A failed launch is treated like a missing startup receipt.
        }
        if let pid = launchedPID, !stop(pid) { throw SafeUpdateError.processStillRunning }
        guard let candidateInode,
              (try? FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber) == candidateInode else {
            throw SafeUpdateError.rollbackFailed
        }
        guard renamex_np(target.path, incoming.path, UInt32(RENAME_SWAP)) == 0 else { throw SafeUpdateError.rollbackFailed }
        return .rolledBack
    }
}
