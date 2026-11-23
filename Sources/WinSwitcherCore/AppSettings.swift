import Foundation

public enum ShortcutMode: String, CaseIterable, Identifiable, Sendable {
    case optionTab = "optionTab"
    case commandTab = "commandTab"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .optionTab:
            return "Option + Tab (⌥⇥)"
        case .commandTab:
            return "Command + Tab (⌘⇥)"
        }
    }

    public var shortLabel: String {
        switch self {
        case .optionTab:
            return "⌥ + Tab"
        case .commandTab:
            return "⌘ + Tab"
        }
    }
}

public enum HUDDisplayTarget: String, CaseIterable, Identifiable, Sendable {
    case activeWindowScreen = "activeWindowScreen"
    case mouseScreen = "mouseScreen"
    case primaryScreen = "primaryScreen"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .activeWindowScreen:
            return "当前焦点窗口所在屏幕"
        case .mouseScreen:
            return "鼠标指针所在屏幕"
        case .primaryScreen:
            return "主显示器"
        }
    }
}

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Keys {
        static let shortcutMode = "shortcutMode"
        static let showDelayMs = "showDelayMs"
        static let sinkMinimizedToEnd = "sinkMinimizedToEnd"
        static let includeAllSpaces = "includeAllSpaces"
        static let singleWindowRaise = "singleWindowRaise"
        static let hudDisplayTarget = "hudDisplayTarget"
        static let showSpaceBadge = "showSpaceBadge"
        static let pauseInSystemSettings = "pauseInSystemSettings"
        static let excludedBundleIDs = "excludedBundleIDs"
    }

    @Published public var shortcutMode: ShortcutMode {
        didSet { defaults.set(shortcutMode.rawValue, forKey: Keys.shortcutMode) }
    }

    /// Delay in milliseconds before showing the HUD panel (Windows 10/11 fast-switch anti-flicker).
    @Published public var showDelayMs: Double {
        didSet { defaults.set(showDelayMs, forKey: Keys.showDelayMs) }
    }

    /// Windows standard behavior: actively minimizing or hiding a window sends it to the end of the MRU list.
    @Published public var sinkMinimizedToEnd: Bool {
        didSet { defaults.set(sinkMinimizedToEnd, forKey: Keys.sinkMinimizedToEnd) }
    }

    /// Unify windows across all Spaces and Fullscreen Spaces in one list.
    @Published public var includeAllSpaces: Bool {
        didSet { defaults.set(includeAllSpaces, forKey: Keys.includeAllSpaces) }
    }

    /// Raise only the target window without pulling sibling windows of the same application to the front.
    @Published public var singleWindowRaise: Bool {
        didSet { defaults.set(singleWindowRaise, forKey: Keys.singleWindowRaise) }
    }

    @Published public var hudDisplayTarget: HUDDisplayTarget {
        didSet { defaults.set(hudDisplayTarget.rawValue, forKey: Keys.hudDisplayTarget) }
    }

    @Published public var showSpaceBadge: Bool {
        didSet { defaults.set(showSpaceBadge, forKey: Keys.showSpaceBadge) }
    }

    /// Automatically pass all hotkeys through when macOS System Settings is focused (prevents conflicts while configuring system shortcuts).
    @Published public var pauseInSystemSettings: Bool {
        didSet { defaults.set(pauseInSystemSettings, forKey: Keys.pauseInSystemSettings) }
    }

    /// Bundle identifiers of apps where WinSwitcher automatically passes hotkeys through (e.g., Remote Desktop, VMs, games).
    @Published public var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Keys.excludedBundleIDs) }
    }

    public func isBundleExcluded(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        if pauseInSystemSettings && bundleIdentifier == "com.apple.systempreferences" {
            return true
        }
        return excludedBundleIDs.contains(bundleIdentifier)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.shortcutMode),
           let mode = ShortcutMode(rawValue: raw) {
            self.shortcutMode = mode
        } else {
            self.shortcutMode = .optionTab
        }

        if defaults.object(forKey: Keys.showDelayMs) != nil {
            self.showDelayMs = defaults.double(forKey: Keys.showDelayMs)
        } else {
            self.showDelayMs = 120
        }

        if defaults.object(forKey: Keys.sinkMinimizedToEnd) != nil {
            self.sinkMinimizedToEnd = defaults.bool(forKey: Keys.sinkMinimizedToEnd)
        } else {
            self.sinkMinimizedToEnd = true
        }

        if defaults.object(forKey: Keys.includeAllSpaces) != nil {
            self.includeAllSpaces = defaults.bool(forKey: Keys.includeAllSpaces)
        } else {
            self.includeAllSpaces = true
        }

        if defaults.object(forKey: Keys.singleWindowRaise) != nil {
            self.singleWindowRaise = defaults.bool(forKey: Keys.singleWindowRaise)
        } else {
            self.singleWindowRaise = true
        }

        if let raw = defaults.string(forKey: Keys.hudDisplayTarget),
           let target = HUDDisplayTarget(rawValue: raw) {
            self.hudDisplayTarget = target
        } else {
            self.hudDisplayTarget = .activeWindowScreen
        }

        if defaults.object(forKey: Keys.showSpaceBadge) != nil {
            self.showSpaceBadge = defaults.bool(forKey: Keys.showSpaceBadge)
        } else {
            self.showSpaceBadge = true
        }

        if defaults.object(forKey: Keys.pauseInSystemSettings) != nil {
            self.pauseInSystemSettings = defaults.bool(forKey: Keys.pauseInSystemSettings)
        } else {
            self.pauseInSystemSettings = true
        }

        if let stored = defaults.stringArray(forKey: Keys.excludedBundleIDs) {
            self.excludedBundleIDs = stored
        } else {
            // Default common remote-desktop / VM apps so Alt+Tab goes straight to the guest OS
            self.excludedBundleIDs = [
                "com.microsoft.rdc.macos",
                "com.parallels.desktop.console",
                "com.vmware.fusion"
            ]
        }
    }
}
