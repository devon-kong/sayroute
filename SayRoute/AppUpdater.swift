import AppKit

@MainActor
final class AppUpdater: NSObject {
    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var progressWindow: NSWindow?
    private var progressBar: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var continuation: CheckedContinuation<URL, Error>?
    private var installationTask: Task<Void, Never>?
    private var isUpdating = false

    func downloadAndInstall(update: UpdateChecker.UpdateInfo) {
        guard !isUpdating else { return }
        isUpdating = true
        installationTask = Task {
            defer {
                isUpdating = false
                installationTask = nil
                downloadTask = nil
                session?.finishTasksAndInvalidate()
                session = nil
            }
            var downloadURL: URL?
            var staged: UpdatePlan?
            var helperStarted = false
            defer {
                if let downloadURL { try? FileManager.default.removeItem(at: downloadURL) }
                if let staged, !helperStarted { try? FileManager.default.removeItem(at: staged.stage) }
            }
            do {
                guard update.isTrustedReleaseReference else { throw SafeUpdateError.identityMismatch }
                let currentURL = Bundle.main.bundleURL
                try UpdatePolicy.requireTrustedRelease(UpdateSignature.identity(at: currentURL))
                showProgressWindow(version: update.version)
                let zipURL = try await download(url: update.assetURL)
                downloadURL = zipURL
                try Task.checkCancellation()
                updateStatus("正在验证签名并准备可回退更新…")
                let parentPID = ProcessInfo.processInfo.processIdentifier
                let plan = try await Task.detached(priority: .userInitiated) {
                    try UpdatePreparation.prepare(archive: zipURL, currentApp: currentURL,
                                                  expectedVersion: update.version, parentPID: parentPID)
                }.value
                staged = plan
                try Task.checkCancellation()
                let launcher = Process()
                launcher.executableURL = plan.stage.appendingPathComponent("installer")
                launcher.arguments = [plan.stage.appendingPathComponent("plan.json").path]
                try launcher.run()
                helperStarted = true
                NSApp.terminate(nil)
            } catch is CancellationError {
                closeProgressWindow()
            } catch {
                closeProgressWindow()
                let alert = NSAlert()
                alert.messageText = "未安装更新"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                alert.runModal()
            }
        }
    }

    // MARK: - Download

    private func download(url: URL) async throws -> URL {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let config = URLSessionConfiguration.ephemeral
            let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            self.session = session
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    // MARK: - Progress UI

    private func showProgressWindow(version: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "更新 SayRoute"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: window.contentView!.bounds)

        let label = NSTextField(labelWithString: "正在下载 v\(version)...")
        label.frame = NSRect(x: 20, y: 55, width: 300, height: 20)
        label.font = .systemFont(ofSize: 13)
        contentView.addSubview(label)
        self.statusLabel = label

        let progress = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 300, height: 20))
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.doubleValue = 0
        contentView.addSubview(progress)
        self.progressBar = progress

        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancelDownload))
        cancelBtn.frame = NSRect(x: 250, y: 2, width: 70, height: 24)
        cancelBtn.bezelStyle = .rounded
        contentView.addSubview(cancelBtn)

        window.contentView = contentView
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.progressWindow = window
    }

    private func updateStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
    }

    @objc private func cancelDownload() {
        installationTask?.cancel()
        downloadTask?.cancel()
        session?.invalidateAndCancel()
        closeProgressWindow()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

}

// MARK: - URLSessionDownloadDelegate

extension AppUpdater: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let percent = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100
            : 0
        let writtenMB = Double(totalBytesWritten) / 1_048_576
        let totalMB = Double(totalBytesExpectedToWrite) / 1_048_576
        MainActor.assumeIsolated {
            guard self.downloadTask === downloadTask, continuation != nil else { return }
            guard totalBytesWritten <= UpdateArchive.maximumArchiveBytes,
                  totalBytesExpectedToWrite <= UpdateArchive.maximumArchiveBytes else {
                continuation?.resume(throwing: SafeUpdateError.unsafeArchive)
                continuation = nil
                downloadTask.cancel()
                return
            }
            progressBar?.doubleValue = percent
            statusLabel?.stringValue = String(format: "正在下载... %.1f / %.1f MB", writtenMB, totalMB)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host,
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard self.downloadTask === downloadTask, continuation != nil else { return }
            do {
                guard let response = downloadTask.response as? HTTPURLResponse,
                      response.statusCode == 200, response.url?.scheme == "https",
                      let host = response.url?.host,
                      ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host),
                      let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= UpdateArchive.maximumArchiveBytes else { throw SafeUpdateError.unsafeArchive }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("sayroute-download-\(UUID()).zip")
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
            } catch {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error = error else { return }
        MainActor.assumeIsolated {
            guard self.downloadTask === task else { return }
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
