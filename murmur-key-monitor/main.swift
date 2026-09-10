import AppKit
import ApplicationServices
import Darwin
import Foundation

private let defaultDurationSeconds = 600
private let minimumDurationSeconds = 60
private let maximumDurationSeconds = 600
private let maximumLogBytes = 1_048_576

private enum MonitorError: LocalizedError {
    case invalidArguments(String)
    case outputDirectory(String)
    case outputFile(String)
    case eventTapUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): return message
        case let .outputDirectory(path): return "无法创建日志目录：\(path)"
        case let .outputFile(path): return "无法创建日志文件（不会覆盖既有文件）：\(path)"
        case .eventTapUnavailable: return "无法创建只监听键盘事件的 Input Monitoring event tap。"
        }
    }
}

private struct Configuration {
    let durationSeconds: Int
    let outputURL: URL?
    let selfTest: Bool

    static func parse(arguments: [String]) throws -> Configuration {
        var durationSeconds = defaultDurationSeconds
        var outputURL: URL?
        var selfTest = false
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--self-test":
                guard !selfTest else { throw MonitorError.invalidArguments("--self-test 不能重复使用。") }
                selfTest = true
                index += 1
            case "--duration-seconds":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]) else {
                    throw MonitorError.invalidArguments("--duration-seconds 需要整数参数。")
                }
                guard (minimumDurationSeconds...maximumDurationSeconds).contains(value) else {
                    throw MonitorError.invalidArguments("--duration-seconds 必须在 \(minimumDurationSeconds) 到 \(maximumDurationSeconds) 秒之间。")
                }
                durationSeconds = value
                index += 2
            case "--output":
                guard index + 1 < arguments.count, outputURL == nil else {
                    throw MonitorError.invalidArguments("--output 需要一个且只能有一个文件路径。")
                }
                outputURL = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
                index += 2
            case "--help", "-h":
                throw MonitorError.invalidArguments(usage)
            default:
                throw MonitorError.invalidArguments("不支持的参数：\(arguments[index])\n\n\(usage)")
            }
        }

        if selfTest, outputURL != nil {
            throw MonitorError.invalidArguments("--self-test 不接受 --output，也不会创建日志文件。")
        }
        return Configuration(durationSeconds: durationSeconds, outputURL: outputURL, selfTest: selfTest)
    }
}

private let usage = """
用法：murmur-key-monitor [--duration-seconds 60...600] [--output /完整/日志路径]
      murmur-key-monitor --self-test
默认采集 600 秒；仅记录 Command、V、删除和回车相关的键盘元数据，不记录输入文字或剪贴板。
"""

private enum ObservedKey: UInt16 {
    case leftCommand = 55
    case rightCommand = 54
    case v = 9
    case delete = 51
    case forwardDelete = 117
    case `return` = 36
    case enter = 76

    static func isAllowed(_ keyCode: UInt16) -> Bool {
        ObservedKey(rawValue: keyCode) != nil
    }
}

private struct DiagnosticEvent: Encodable {
    let timestampUTC: String
    let monotonicNanoseconds: UInt64
    let eventType: String
    let rawEventType: UInt32
    let keyCode: UInt16
    let rawFlags: UInt64
    let commandFlag: Bool
    let sourcePID: Int64
    let sourceStateID: Int64
    let keyboardType: Int64
    let frontmostBundleIdentifier: String?
}

private final class BoundedJSONLWriter {
    enum WriteResult {
        case written
        case sizeCapReached
        case failed
    }

    private let handle: FileHandle
    private let maximumBytes: Int
    private let lock = NSLock()
    private var bytesWritten = 0

    private init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    deinit {
        try? handle.close()
    }

    static func create(at url: URL, maximumBytes: Int) throws -> BoundedJSONLWriter {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MonitorError.outputDirectory(directory.path)
        }

        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw MonitorError.outputFile(url.path) }
        return BoundedJSONLWriter(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), maximumBytes: maximumBytes)
    }

    func append(_ event: DiagnosticEvent) -> WriteResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(event) else { return .failed }
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        guard bytesWritten + data.count <= maximumBytes else { return .sizeCapReached }
        do {
            try handle.write(contentsOf: data)
            bytesWritten += data.count
            return .written
        } catch {
            return .failed
        }
    }
}

private final class KeyMonitor {
    enum StopReason: String {
        case durationElapsed = "达到设定时长"
        case logSizeCap = "达到 1 MiB 日志上限（为保护隐私而停止）"
        case logWriteFailure = "日志写入失败（已停止，避免无日志运行）"
        case tapDisabledByTimeout = "监听 tap 因超时被系统禁用；采集可能缺失，已停止。请重新运行诊断。"
        case tapDisabledByUserInput = "监听 tap 被系统因用户输入禁用；采集可能缺失，已停止。请重新运行诊断。"
    }

    private let configuration: Configuration
    private let writer: BoundedJSONLWriter
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    private var tap: CFMachPort?
    private var stopped = false
    private(set) var stopReason: StopReason?

    init(configuration: Configuration, writer: BoundedJSONLWriter) {
        self.configuration = configuration
        self.writer = writer
    }

    func start() throws {
        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
            | CGEventMask(1) << CGEventType.keyUp.rawValue
            | CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: keyMonitorCallback,
            userInfo: info
        ) else {
            throw MonitorError.eventTapUnavailable
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        let currentSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoop = currentRunLoop
        source = currentSource
        self.tap = tap
        CFRunLoopAddSource(currentRunLoop, currentSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(configuration.durationSeconds)) { [weak self] in
            self?.stop(.durationElapsed)
        }
    }

    func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            stop(.tapDisabledByTimeout)
            return
        case .tapDisabledByUserInput:
            stop(.tapDisabledByUserInput)
            return
        default:
            break
        }
        guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard ObservedKey.isAllowed(keyCode) else { return }

        let flags = UInt64(event.flags.rawValue)
        let diagnosticEvent = DiagnosticEvent(
            timestampUTC: Self.utcTimestamp(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            eventType: Self.eventName(for: type),
            rawEventType: UInt32(type.rawValue),
            keyCode: keyCode,
            rawFlags: flags,
            commandFlag: event.flags.contains(.maskCommand),
            sourcePID: event.getIntegerValueField(.eventSourceUnixProcessID),
            sourceStateID: event.getIntegerValueField(.eventSourceStateID),
            keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType),
            frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )

        switch writer.append(diagnosticEvent) {
        case .written: return
        case .sizeCapReached: stop(.logSizeCap)
        case .failed: stop(.logWriteFailure)
        }
    }

    func stop(_ reason: StopReason) {
        guard !stopped else { return }
        stopped = true
        stopReason = reason
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            if let runLoop {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        if let tap {
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
    }

    private static func eventName(for type: CGEventType) -> String {
        switch type {
        case .keyDown: return "keyDown"
        case .keyUp: return "keyUp"
        case .flagsChanged: return "flagsChanged"
        default: return "unknown"
        }
    }

    private static func utcTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private let keyMonitorCallback: CGEventTapCallBack = { _, type, event, userInfo in
    if let userInfo {
        Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue().handle(type: type, event: event)
    }
    // A listen-only tap must always pass the original event through unchanged.
    return Unmanaged.passUnretained(event)
}

private enum SelfTest {
    static func run() throws {
        let valid = try Configuration.parse(arguments: ["--duration-seconds", "60"])
        try require(valid.durationSeconds == 60 && !valid.selfTest, "有效时长参数未通过。")
        try require(throws: { _ = try Configuration.parse(arguments: ["--duration-seconds", "59"]) }, "下界校验缺失。")
        try require(throws: { _ = try Configuration.parse(arguments: ["--unknown"]) }, "未知参数校验缺失。")
        try require(ObservedKey.isAllowed(54) && ObservedKey.isAllowed(9) && ObservedKey.isAllowed(51), "允许键码缺失。")
        try require(!ObservedKey.isAllowed(0), "任意键过滤失效。")

        let event = DiagnosticEvent(
            timestampUTC: "2026-01-01T00:00:00.000Z",
            monotonicNanoseconds: 1,
            eventType: "keyDown",
            rawEventType: 10,
            keyCode: 9,
            rawFlags: 1 << 20,
            commandFlag: true,
            sourcePID: 42,
            sourceStateID: 1,
            keyboardType: 0,
            frontmostBundleIdentifier: "com.example.target"
        )
        let encoded = try String(decoding: JSONEncoder().encode(event), as: UTF8.self).lowercased()
        for forbidden in ["text", "clipboard", "window", "character", "hash"] {
            try require(!encoded.contains(forbidden), "隐私边界序列化包含禁止字段：\(forbidden)")
        }
        try require(encoded.contains("keycode") && encoded.contains("commandflag"), "诊断元数据序列化缺失。")

        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-key-monitor-self-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let writer = try BoundedJSONLWriter.create(at: temporaryURL, maximumBytes: 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)[.posixPermissions] as? NSNumber
        try require(permissions?.intValue == 0o600, "日志文件权限不是 0600。")
        try require(writer.append(event) == .sizeCapReached, "日志上限未生效。")
        guard let syntheticEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            throw MonitorError.invalidArguments("自检失败：无法创建合成事件。")
        }
        let disabledTapMonitor = KeyMonitor(configuration: valid, writer: writer)
        disabledTapMonitor.handle(type: .tapDisabledByTimeout, event: syntheticEvent)
        try require(disabledTapMonitor.stopReason == .tapDisabledByTimeout, "tap 超时禁用未 fail-closed。")
        try require(minimumDurationSeconds <= defaultDurationSeconds && defaultDurationSeconds <= maximumDurationSeconds, "默认时长越界。")
        print("SELF-TEST PASS: 参数、键码白名单、JSONL 隐私边界、大小/时长上限和 tap 失效 fail-closed 均已验证；未请求 Input Monitoring 权限。")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MonitorError.invalidArguments("自检失败：\(message)") }
    }

    private static func require(throws operation: () throws -> Void, _ message: String) throws {
        do {
            try operation()
        } catch {
            return
        }
        throw MonitorError.invalidArguments("自检失败：\(message)")
    }
}

private func defaultOutputURL() -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let filename = "murmur-key-monitor-\(formatter.string(from: Date())).jsonl"
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Doubao Murmur", isDirectory: true)
        .appendingPathComponent(filename, isDirectory: false)
}

private func ensureInputMonitoringPermission() -> Bool {
    if CGPreflightListenEventAccess() { return true }
    print("需要 macOS“输入监控”权限；现在将向系统请求授权。")
    _ = CGRequestListenEventAccess()
    return CGPreflightListenEventAccess()
}

do {
    let configuration = try Configuration.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    if configuration.selfTest {
        try SelfTest.run()
        exit(EXIT_SUCCESS)
    }

    guard ensureInputMonitoringPermission() else {
        fputs("未获得“输入监控”权限。请在 系统设置 > 隐私与安全性 > 输入监控 中允许正在运行此工具的 Terminal，然后重新运行；工具未创建修改型 event tap。\n", stderr)
        exit(2)
    }

    let outputURL = configuration.outputURL ?? defaultOutputURL()
    let writer = try BoundedJSONLWriter.create(at: outputURL, maximumBytes: maximumLogBytes)
    let monitor = KeyMonitor(configuration: configuration, writer: writer)
    try monitor.start()
    print("监听已开始：仅监听、不拦截、不修改键盘事件；将在 \(configuration.durationSeconds) 秒后自动停止。")
    print("日志路径：\(outputURL.path)")
    print("请复现一次快速粘贴后的 Backspace/Return；不会记录文字、剪贴板、窗口标题或辅助功能文本。")
    CFRunLoopRun()

    let reason = monitor.stopReason ?? .durationElapsed
    print("监听已停止：\(reason.rawValue)。日志保留在：\(outputURL.path)")
    exit(reason == .durationElapsed ? EXIT_SUCCESS : EXIT_FAILURE)
} catch {
    fputs("murmur-key-monitor 失败：\(error.localizedDescription)\n\n\(usage)\n", stderr)
    exit(EXIT_FAILURE)
}
