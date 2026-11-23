import AppKit
import CoreGraphics
import Darwin
import Foundation

struct HotkeyConflict: Identifiable, Equatable, Sendable {
    enum RiskLevel: Int, Comparable, Sendable {
        case medium = 1
        case high = 2

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    let id: String
    let pid: pid_t
    let appName: String
    let bundleIdentifier: String?
    let tapLevelLabel: String // "HID 底层" or "会话层"
    let riskLevel: RiskLevel
    let reason: String
}

/// Inspects active macOS `CGEventTap`s via `CGGetEventTapList` to proactively detect
/// other apps actively intercepting keyboard input that may contend for `Option+Tab` or `Command+Tab`.
@MainActor
final class ConflictDetector: ObservableObject {
    static let shared = ConflictDetector()

    @Published private(set) var conflicts: [HotkeyConflict] = []

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    private static let ignoredSystemProcessNames: Set<String> = [
        "WindowServer",
        "Dock",
        "loginwindow",
        "SystemUIServer",
        "universalaccessd",
        "ControlCenter",
        "CoreServicesUIAgent",
        "AccessibilityVisualsAgent",
        "TextInputMenuAgent",
        "TextInputSwitcher",
        "Spotlight",
        "NotificationCenter",
        "WindowManager",
        "Siri"
    ]

    private static let knownHighRiskBundlePrefixes: [String] = [
        "com.lwouis.alt-tab-macos",
        "com.contextsformac",
        "com.manytricks.Witch",
        "com.bahoom.HyperSwitch",
        "com.noteifyapp.Command-Tab",
        "org.pqrs.Karabiner",
        "com.hegenberg.BetterTouchTool",
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
        "org.hammerspoon.Hammerspoon",
        "com.stairways.keyboardmaestro",
        "bobko.aerospace",
        "com.knollsoft.Rectangle",
        "com.crowdcafe.windowmagnet",
        "net.matthewpalmer.Vanilla",
        "com.surteesstudios.Bartender"
    ]

    private static let knownHighRiskNameKeywords: [String] = [
        "alttab",
        "alt-tab",
        "contexts",
        "witch",
        "hyperswitch",
        "karabiner",
        "bettertouchtool",
        "hammerspoon",
        "keyboard maestro",
        "skhd",
        "yabai",
        "aerospace",
        "raycast",
        "alfred"
    ]

    private init() {}

    func scan() {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            conflicts = []
            return
        }

        let capacity = count + 8
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        var actualCount: UInt32 = 0
        guard CGGetEventTapList(capacity, &list, &actualCount) == .success else {
            return
        }

        let keyDownBit = CGEventMask(1) << CGEventType.keyDown.rawValue
        let flagsChangedBit = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let keyboardMask = keyDownBit | flagsChangedBit

        var byPID: [pid_t: HotkeyConflict] = [:]

        for idx in 0..<Int(actualCount) {
            let info = list[idx]
            guard info.enabled else { continue }
            // Only active intercepting taps (.defaultTap) can swallow or contend for hotkeys;
            // passive .listenOnly monitors do not block or steal keys.
            guard info.options == .defaultTap else { continue }
            guard (info.eventsOfInterest & keyboardMask) != 0 else { continue }

            let pid = info.tappingProcess
            guard pid > 0, pid != selfPID else { continue }

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let bundleID = runningApp?.bundleIdentifier
            let resolvedName = runningApp?.localizedName ?? Self.processName(for: pid) ?? "PID \(pid)"

            // Skip built-in macOS Apple system processes
            if let bundleID, bundleID.hasPrefix("com.apple.") {
                continue
            }
            if Self.ignoredSystemProcessNames.contains(resolvedName) {
                continue
            }

            let isHID = (info.tapPoint == .cghidEventTap)
            let tapLabel = isHID ? "HID 底层拦截" : "会话层拦截"

            let isKnownTool = Self.isKnownHotkeyTool(bundleID: bundleID, name: resolvedName)
            let risk: HotkeyConflict.RiskLevel = (isKnownTool || isHID) ? .high : .medium

            let reason: String
            if isKnownTool && isHID {
                reason = "已知热键/窗口管理工具，且位于更底层的 HID 拦截点（优先级高于本应用）"
            } else if isKnownTool {
                reason = "已知热键/窗口管理工具，可能同时监听 Option+Tab 或 Command+Tab"
            } else if isHID {
                reason = "正在以 HID 底层主动拦截键盘事件，可能抢先截获快捷键"
            } else {
                reason = "正在主动拦截全局键盘事件，如快捷键无响应请检查该应用热键设置"
            }

            let candidate = HotkeyConflict(
                id: "\(pid)-\(bundleID ?? resolvedName)",
                pid: pid,
                appName: resolvedName,
                bundleIdentifier: bundleID,
                tapLevelLabel: tapLabel,
                riskLevel: risk,
                reason: reason
            )

            if let existing = byPID[pid] {
                if candidate.riskLevel > existing.riskLevel {
                    byPID[pid] = candidate
                }
            } else {
                byPID[pid] = candidate
            }
        }

        conflicts = byPID.values.sorted { lhs, rhs in
            if lhs.riskLevel != rhs.riskLevel {
                return lhs.riskLevel > rhs.riskLevel
            }
            return lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }

    private static func isKnownHotkeyTool(bundleID: String?, name: String) -> Bool {
        if let bundleID {
            for prefix in knownHighRiskBundlePrefixes where bundleID.hasPrefix(prefix) {
                return true
            }
        }
        let lowerName = name.lowercased()
        return knownHighRiskNameKeywords.contains { lowerName.contains($0) }
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        let slice = buffer.prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self)
    }
}
