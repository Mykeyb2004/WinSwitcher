import AppKit
import Combine
import SwiftUI
import WinSwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        observeStateForMenu()

        SwitcherController.shared.start()

        if !PermissionsManager.shared.hasAccessibility {
            openSettingsWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SwitcherController.shared.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBarIcon(item: item)
        self.statusItem = item
        rebuildMenu()
    }

    private func updateStatusBarIcon(item: NSStatusItem?) {
        guard let button = item?.button else { return }
        let controller = SwitcherController.shared
        let image: NSImage?
        if controller.isCircuitBreakerTripped {
            image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "WinSwitcher")
        } else if controller.isPaused {
            image = NSImage(systemSymbolName: "pause.rectangle", accessibilityDescription: "WinSwitcher")
        } else {
            let customIcon = Bundle.main.image(forResource: NSImage.Name("MenuBarIcon"))
            customIcon?.accessibilityDescription = "WinSwitcher"
            image = customIcon
                ?? NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "WinSwitcher")
        }
        image?.isTemplate = true
        button.image = image
    }

    private func observeStateForMenu() {
        PermissionsManager.shared.$hasAccessibility
            .combineLatest(
                PermissionsManager.shared.$hasScreenRecording,
                AppSettings.shared.$shortcutMode
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        SwitcherController.shared.$isPaused
            .combineLatest(
                SwitcherController.shared.$isCircuitBreakerTripped,
                ConflictDetector.shared.$conflicts
            )
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.updateStatusBarIcon(item: self?.statusItem)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let perms = PermissionsManager.shared
        let settings = AppSettings.shared
        let controller = SwitcherController.shared
        let conflicts = ConflictDetector.shared.conflicts

        let header = NSMenuItem(title: "WinSwitcher — Windows 11 窗口切换", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        // Primary runtime status
        if controller.isCircuitBreakerTripped {
            let trippedItem = NSMenuItem(
                title: "🛑 热键保护已自动熔断（点击恢复）",
                action: #selector(resetCircuitBreaker),
                keyEquivalent: ""
            )
            trippedItem.target = self
            menu.addItem(trippedItem)
        } else if !perms.hasAccessibility {
            let permItem = NSMenuItem(
                title: "⚠️ 需要「辅助功能」权限以启用快捷键",
                action: #selector(requestAccessibility),
                keyEquivalent: ""
            )
            permItem.target = self
            menu.addItem(permItem)
        } else if controller.isPaused {
            let pausedItem = NSMenuItem(
                title: "⏸ 已暂停热键拦截（点击恢复）",
                action: #selector(togglePause),
                keyEquivalent: ""
            )
            pausedItem.target = self
            menu.addItem(pausedItem)
        } else {
            let statusTitle = perms.hasScreenRecording
                ? "✓ 运行中（\(settings.shortcutMode.shortLabel)）"
                : "✓ 运行中（\(settings.shortcutMode.shortLabel)）· 未开启缩略图权限"
            let statusItemEntry = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
            statusItemEntry.isEnabled = false
            menu.addItem(statusItemEntry)
        }

        // Proactive hotkey conflict warning
        if !conflicts.isEmpty {
            let names = conflicts.prefix(2).map(\.appName).joined(separator: "、")
            let suffix = conflicts.count > 2 ? " 等 \(conflicts.count) 个程序" : ""
            let conflictItem = NSMenuItem(
                title: "⚠️ 检测到键盘拦截：\(names)\(suffix)（点击查看）",
                action: #selector(openSettingsWindow),
                keyEquivalent: ""
            )
            conflictItem.target = self
            menu.addItem(conflictItem)
        }

        menu.addItem(.separator())

        let pauseToggle = NSMenuItem(
            title: controller.isPaused ? "恢复热键拦截" : "暂时暂停热键拦截",
            action: #selector(togglePause),
            keyEquivalent: "p"
        )
        pauseToggle.target = self
        menu.addItem(pauseToggle)

        menu.addItem(.separator())

        let optItem = NSMenuItem(
            title: "快捷键：Option + Tab (⌥⇥)",
            action: #selector(selectOptionTab),
            keyEquivalent: ""
        )
        optItem.target = self
        optItem.state = (settings.shortcutMode == .optionTab) ? .on : .off
        menu.addItem(optItem)

        let cmdItem = NSMenuItem(
            title: "快捷键：Command + Tab (⌘⇥)",
            action: #selector(selectCommandTab),
            keyEquivalent: ""
        )
        cmdItem.target = self
        cmdItem.state = (settings.shortcutMode == .commandTab) ? .on : .off
        menu.addItem(cmdItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(
            title: "立即刷新窗口与冲突检测",
            action: #selector(refreshAll),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let emergencyHint = NSMenuItem(title: "紧急强制退出：⌃⌥⌘Esc", action: nil, keyEquivalent: "")
        emergencyHint.isEnabled = false
        menu.addItem(emergencyHint)

        let quitItem = NSMenuItem(
            title: "退出 WinSwitcher",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func requestAccessibility() {
        PermissionsManager.shared.requestAccessibilityPrompt()
    }

    @objc private func resetCircuitBreaker() {
        SwitcherController.shared.resetCircuitBreaker()
    }

    @objc private func togglePause() {
        SwitcherController.shared.togglePause()
    }

    @objc private func selectOptionTab() {
        AppSettings.shared.shortcutMode = .optionTab
    }

    @objc private func selectCommandTab() {
        AppSettings.shared.shortcutMode = .commandTab
    }

    @objc private func refreshAll() {
        WindowTracker.shared.refreshAll(includeRemoteAXDiscovery: true)
        ConflictDetector.shared.scan()
    }

    @objc func openSettingsWindow() {
        ConflictDetector.shared.scan()

        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "WinSwitcher 偏好设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
