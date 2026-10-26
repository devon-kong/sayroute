import CryptoKit
import Darwin
import Foundation

protocol RecoveryTextStorage: AnyObject {
    func write(_ text: String, id: UUID) throws
    func read(id: UUID) throws -> String
    func remove(id: UUID) throws
    func close()
}

/// Ciphertext survives only as a temporary file; the key is never serialized.
/// Each directory has a live-owner lease so another process cannot remove it.
final class RecoveryDiskCache: RecoveryTextStorage {
    enum CacheError: Error { case unavailable, closed, invalidText }
    let directory: URL
    private var key: SymmetricKey? = SymmetricKey(size: .bits256)
    private var lease: Int32 = -1

    static var defaultBaseDirectory: URL {
        let bundle = Bundle.main.bundleIdentifier ?? "com.doubao.murmur.development"
        let safeBundle = String(bundle.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) })
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doubao Murmur/RecoverySessions", isDirectory: true)
            .appendingPathComponent(safeBundle, isDirectory: true)
    }

    init(baseDirectory: URL = RecoveryDiskCache.defaultBaseDirectory) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        guard try baseDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CacheError.unavailable
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: baseDirectory.path)
        // Cover creation through lease acquisition: cleanup must never see a
        // half-created live session. Fail promptly if another startup owns it.
        let startup = Darwin.open(baseDirectory.appendingPathComponent(".startup-lock").path,
                                  O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard startup >= 0 else { throw CacheError.unavailable }
        defer { Darwin.close(startup) }
        guard flock(startup, LOCK_EX | LOCK_NB) == 0 else { throw CacheError.unavailable }
        defer { _ = flock(startup, LOCK_UN) }
        Self.removeAbandonedSessions(in: baseDirectory)
        directory = baseDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        lease = Darwin.open(directory.appendingPathComponent(".lease").path,
                            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lease >= 0, flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if lease >= 0 { Darwin.close(lease); lease = -1 }
            try? fm.removeItem(at: directory)
            throw CacheError.unavailable
        }
    }

    func write(_ text: String, id: UUID) throws {
        guard let key else { throw CacheError.closed }
        let sealed = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: Data(id.uuidString.utf8))
        guard let data = sealed.combined else { throw CacheError.unavailable }
        let url = file(id)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(id: UUID) throws -> String {
        guard let key else { throw CacheError.closed }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file(id)))
        let plain = try AES.GCM.open(box, using: key, authenticating: Data(id.uuidString.utf8))
        guard let text = String(data: plain, encoding: .utf8) else { throw CacheError.invalidText }
        return text
    }

    func remove(id: UUID) throws {
        guard key != nil else { throw CacheError.closed }
        let url = file(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func close() {
        guard key != nil else { return }
        key = nil
        // If removal fails, later launches can remove the ciphertext; no key survives.
        try? FileManager.default.removeItem(at: directory)
        if lease >= 0 { _ = flock(lease, LOCK_UN); Darwin.close(lease); lease = -1 }
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".sealed") }

    private static func removeAbandonedSessions(in base: URL) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for child in children {
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  let properties = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            // Under the startup lock, a missing lease is an interrupted startup.
            let fd = Darwin.open(child.appendingPathComponent(".lease").path,
                                 O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                try? fm.removeItem(at: child)
                _ = flock(fd, LOCK_UN)
            }
            Darwin.close(fd)
        }
    }

    deinit { close() }
}
