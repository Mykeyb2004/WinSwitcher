import AppKit
import ServiceManagement
import SwiftUI
import WinSwitcherCore

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var controller = SwitcherController.shared
    @ObservedObject var conflictDetector = ConflictDetector.shared

    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?
    @State private var newExcludedBundleID: String = ""

    var body: some View {
        Form {
            if controller.isCircuitBreakerTripped {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("热键保护熔断器已触发")
                                .font(.headline)
                            Text("系统检测到事件拦截连续超时，为防止键鼠卡死已自动停用快捷键监听。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("重置并恢复") {
                            controller.resetCircuitBreaker()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section("触发快捷键") {
                Picker("切换窗口快捷键", selection: $settings.shortcutMode) {
                    ForEach(ShortcutMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(
                    settings.shortcutMode == .optionTab
                        ? "使用 Option + Tab 触发 Windows 风格窗口切换（保留系统 Cmd + Tab）。按住 Option 期间可用 Shift+Tab、方向键导航，W 关闭，Esc 取消。"
                        : "接管系统 Command + Tab，以 Windows 窗口级 MRU 顺序替代原生应用切换。按住 Command 期间可用 Shift+Tab、方向键导航，W 关闭，Esc 取消。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if conflictDetector.conflicts.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("未检测到其他主动拦截全局键盘的第三方程序")
                            .font(.callout)
                        Spacer()
                        Button("重新检测") {
                            conflictDetector.scan()
                        }
                        .controlSize(.small)
                    }
                } else {
                    ForEach(conflictDetector.conflicts) { conflict in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: conflict.riskLevel == .high ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(conflict.riskLevel == .high ? .orange : .blue)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(conflict.appName)
                                        .font(.body.weight(.medium))
                                    Text(conflict.tapLevelLabel)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(
                                                conflict.riskLevel == .high
                                                    ? Color.orange.opacity(0.18)
                                                    : Color.secondary.opacity(0.14)
                                            )
                                        )
                                }
                                Text(conflict.reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }

                    HStack {
                        Text("建议：若快捷键无响应或重叠，可在上方切换 ⌥Tab / ⌘Tab，或关闭冲突软件中相同的快捷键。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重新检测") {
                            conflictDetector.scan()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("热键冲突检测（实时）")
            }

            Section("Windows 切换逻辑") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("面板弹出延迟（快切防闪烁）")
                        Spacer()
                        Text("\(Int(settings.showDelayMs)) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.showDelayMs, in: 0...300, step: 10)
                    Text("在此时间内快速按放快捷键会直接完成最近两窗口（A ⇄ B）切换而不闪出预览面板；按第二次 Tab 会立即弹出面板。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("最小化 / 隐藏窗口沉底至队列末尾（Windows 标准）", isOn: $settings.sinkMinimizedToEnd)
                Toggle("跨所有桌面与全屏 Space 统一列表", isOn: $settings.includeAllSpaces)
                Toggle("单窗口独立置顶（不连带拉起同应用其他窗口）", isOn: $settings.singleWindowRaise)
            }

            Section("防卡死与自动透传保护") {
                Toggle("在「系统设置」中自动暂停快捷键拦截（推荐）", isOn: $settings.pauseInSystemSettings)

                VStack(alignment: .leading, spacing: 8) {
                    Text("自动透传应用列表（焦点位于以下应用时自动放行快捷键，适合远程桌面 / 虚拟机）")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                        HStack {
                            Text(bundleID)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                settings.excludedBundleIDs.removeAll { $0 == bundleID }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("输入 Bundle ID（如 com.apple.Terminal）", text: $newExcludedBundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        Button("添加") {
                            let trimmed = newExcludedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty && !settings.excludedBundleIDs.contains(trimmed) {
                                settings.excludedBundleIDs.append(trimmed)
                                newExcludedBundleID = ""
                            }
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "lifepreserver")
                        .foregroundStyle(.secondary)
                    Text("安全保障：独立实时线程拦截（绝不拦截鼠标）+ 连续超时自动熔断 + 随时可按 ⌃⌥⌘Esc 强制立即退出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Windows 11 外观与多屏") {
                Picker("切换面板显示位置", selection: $settings.hudDisplayTarget) {
                    ForEach(HUDDisplayTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }

                Toggle("为其他桌面 / 全屏窗口显示空间角标", isOn: $settings.showSpaceBadge)
            }

            Section("系统权限与启动") {
                permissionRow(
                    title: "辅助功能（必需）",
                    subtitle: "用于拦截全局快捷键、读取窗口 MRU 状态、跨 Space 置顶与还原最小化窗口。",
                    granted: permissions.hasAccessibility,
                    actionTitle: "前往授权",
                    action: { permissions.requestAccessibilityPrompt() }
                )

                permissionRow(
                    title: "屏幕录制（推荐）",
                    subtitle: "用于在 Windows 11 卡片中显示窗口实时缩略图及最小化前快照。",
                    granted: permissions.hasScreenRecording,
                    actionTitle: "前往授权",
                    action: { permissions.requestScreenRecordingPrompt() }
                )

                Toggle("登录 macOS 时自动启动", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }
                ))

                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
        .onAppear {
            permissions.refresh()
            conflictDetector.scan()
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Text("已授权")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        launchError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            launchError = "设置开机自启失败（请确保从 WinSwitcher.app 运行）：\(error.localizedDescription)"
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
