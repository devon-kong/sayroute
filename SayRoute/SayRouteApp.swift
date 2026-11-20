import SwiftUI
import Combine

@main
struct SayRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }.commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var inputMethodSessionManager: InputMethodSessionManager!
    private var overlayPanel: OverlayPanel!
    private var appUpdater: AppUpdater?
    private let appState = AppState.shared
    private var subscriptions = Set<AnyCancellable>()
    private lazy var settingsController = SettingsWindowController(manager: hotkeyManager)
    private var recoveryWindow: RecoveryWindowController?
    private var recoveryNotice: RecoveryNoticePanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Do not run two global hotkey listeners or discard the old app's live drafts.
        let conflicting = NSWorkspace.shared.runningApplications.contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                ($0.bundleIdentifier?.hasPrefix("com.doubao.murmur") == true ||
                 $0.bundleIdentifier == "com.devonkong.sayroute")
        }
        if conflicting {
            let alert = NSAlert()
            alert.messageText = "请先退出旧版或另一份 SayRoute"
            alert.informativeText = "先在旧应用的“最近文字与恢复”中复制需要保留的文字，再退出旧应用并重新打开 SayRoute。旧版恢复文字的密钥不会跨重启保存。"
            alert.addButton(withTitle: "退出 SayRoute")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        LegacyPreferences.migrate()
        print("[AppDelegate] applicationDidFinishLaunching (IME bridge)")
        setupHotkey()
        setupStatusItem()
        setupOverlay()
        setupInputMethodSessionManager()
        appState.drafts.$entries.map { $0.filter { $0.isUnreadFailure }.count }
            .removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshRecoveryStatus()
        }.store(in: &subscriptions)
        let notice = RecoveryNoticePanel()
        notice.onViewRecords = { [weak self] in self?.showRecovery() }
        recoveryNotice = notice
        appState.$recordingState.removeDuplicates().sink { [weak self] state in
            self?.recoveryNotice?.setRecordingBusy(state != .idle)
        }.store(in: &subscriptions)
        appState.$recoveryNotice.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] message in
            guard let self else { return }
            self.recoveryNotice?.present(message)
        }.store(in: &subscriptions)
        print("[AppDelegate] ✅ IME bridge setup complete")
        UpdateStartupReceipt.writeIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputMethodSessionManager?.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = SayRouteMark.menuImage()
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
        let status = hotkeyManager.isListenerReady ? "快捷键已就绪" : "快捷键未监听"
        let statusMenuItem = NSMenuItem(title: "SayRoute · build \(build) · \(status)", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        let count = appState.drafts.unreadFailureCount
        let recoveryItem = NSMenuItem(title: count > 0 ? "最近文字与恢复（\(count)条新失败提醒）" : "最近文字与恢复",
                                      action: #selector(showRecovery), keyEquivalent: "")
        recoveryItem.target = self
        menu.addItem(recoveryItem)
        menu.addItem(NSMenuItem.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let devices = NSMenuItem(title: "设备与端口…", action: #selector(editUUDevices), keyEquivalent: "")
        devices.target = self
        menu.addItem(devices)
        menu.addItem(makeUUPasteModeItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
    }

    @objc func showSettings() { settingsController.show(.general) }

    @objc private func editUUDevices() { settingsController.show(.devices) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    private func makeUUPasteModeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "UU 远程粘贴方式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentMode = PasteRoutingSettings().uuPasteMode
        for mode in UUPasteMode.allCases {
            let modeItem = NSMenuItem(title: mode.menuTitle, action: #selector(uuPasteModeChanged(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == currentMode ? .on : .off
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    @objc private func uuPasteModeChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UUPasteMode(rawValue: rawValue) else { return }
        let settings = PasteRoutingSettings()
        settings.uuPasteMode = mode
        print("[AppDelegate] UU paste mode set to \(mode.rawValue)")
        rebuildMenu()
    }

    private func refreshRecoveryStatus() {
        let count = appState.drafts.unreadFailureCount
        statusItem.button?.title = count > 0 ? " \(count)" : ""
        statusItem.button?.toolTip = count > 0 ? "\(count)条新失败提醒，点击菜单打开最近文字与恢复" : "SayRoute"
        rebuildMenu()
    }

    @objc private func showRecovery() {
        recoveryNotice?.dismissNotice()
        if recoveryWindow == nil { recoveryWindow = RecoveryWindowController(store: appState.drafts) }
        recoveryWindow?.show()
    }

    @objc private func showHelp() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"

        let alert = NSAlert()
        alert.messageText = "SayRoute"
        alert.informativeText = """
        版本: \(appVersion) (\(buildNumber))

        本版本使用本机豆包输入法完成语音输入。

        使用方法:
        1. 确保系统已启用豆包输入法
        2. 按 \(hotkeyManager.shortcutTitle) 开始。热键完全释放、输入框聚焦和豆包输入法就绪后，应用会自动开始语音输入
        3. 说完后手动按一次物理右 Command 停止豆包；输入法下划线消失后，应用才冻结最终文字并按所选模式粘贴
        4. 录音期间重复按开始快捷键 会被忽略；按 ESC 则安全取消，不复制粘贴，并恢复原来的输入法

        “设置 → 通用 → 输入框位置”可选择跟随鼠标坐标或屏幕上方，下次录音生效。鼠标模式请先把鼠标移到目标输入框附近。

        UU 远程可选择兼容模式（UU 正常剪贴板同步）或快速模式（需 Mac mini helper 和端口映射）。

        兼容模式如出现旧剪贴板内容，可在「设置 → 通用 → 剪贴板稳定时间」调大秒数后回车。快速模式请在「设备与端口」给每台 Mac 绑定 UU 本地端口，在目标远控窗口按听写键。若启动时已经全屏，请先退出该窗口的全屏，待设备名显示后再进入全屏。

        等待提交超过1.5秒会提示，15秒仍未确认则停止并保留文字。
        失败或目标未收到内容时，从菜单打开“最近文字与恢复”。历史文字以加密临时文件保存，最多3天，退出后不恢复；复制不会删除。打开窗口会清除已有提醒。
        结果未知时先检查目标，避免重复。已投递按键不代表目标输入框已插入文字。

        如果豆包输入法未安装或未启用，本次会话不会开始。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func checkForUpdates() {
        Task {
            do {
                if let update = try await UpdateChecker.check() {
                    let alert = NSAlert()
                    alert.messageText = "发现新版本"
                    alert.informativeText = "新版本 v\(update.version) 已发布，是否立即更新？"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "立即更新")
                    alert.addButton(withTitle: "稍后再说")
                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let updater = AppUpdater()
                        self.appUpdater = updater
                        updater.downloadAndInstall(update: update)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "检查更新"
                    alert.informativeText = "当前已是最新版本。"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "检查更新失败"
                alert.informativeText = "无法连接到 GitHub，请检查网络连接。\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel(appState: appState)
        print("[AppDelegate] Overlay panel created")
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
        print("[AppDelegate] Hotkey manager created")
    }

    private func setupInputMethodSessionManager() {
        inputMethodSessionManager = InputMethodSessionManager(
            appState: appState,
            overlayPanel: overlayPanel,
            hotkeyManager: hotkeyManager
        )
        inputMethodSessionManager.start()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}
