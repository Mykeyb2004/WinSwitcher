import AppKit
import ApplicationServices
import Foundation
import WinSwitcherCore

struct SendableAXElement: @unchecked Sendable {
    let element: AXUIElement
}

private struct UncheckedAXBox: @unchecked Sendable {
    let element: AXUIElement?
}

/// Activates or closes a specific macOS window with Windows-style single-window focus,
/// single-window unminimize restoration, and cross-Space transition.
///
/// Strict single-window guarantee (`singleWindowRaise == true`):
/// - NEVER calls `NSRunningApplication.activate()`, `kAXFrontmostAttribute`, or `NSWorkspace.openApplication`,
///   all of which cause macOS to bring every open/minimized window of the application to the front.
/// - Exclusively uses SkyLight `_SLPSSetFrontProcessWithOptions(psn, windowID, 0x200)` + `SLPSPostEventRecordTo`
///   scoped to the exact `CGWindowID`, paired with per-window `kAXMinimizedAttribute = false` and `kAXRaiseAction`.
@MainActor
enum WindowActivator {
    private static let activatorQueue = DispatchQueue(
        label: "com.winswitcher.activator",
        qos: .userInteractive
    )
    private nonisolated static let probeTimeoutSeconds: Float = 0.25
    private nonisolated static let restoreTimeoutSeconds: Float = 1.0

    static func activate(
        window: WindowDescriptor,
        axElement: AXUIElement?,
        singleWindowRaise: Bool,
        onResolvedAX: (@Sendable (SendableAXElement) -> Void)? = nil,
        onDidFinish: (@Sendable () -> Void)? = nil
    ) {
        let app = NSRunningApplication(processIdentifier: window.pid)
        let wasHidden = (app?.isHidden ?? false) || window.isHidden

        // Only call unhide() if the application was explicitly hidden via Cmd+H.
        if let app, wasHidden {
            app.unhide()
        }

        let boxedAX = UncheckedAXBox(element: axElement)
        let pid = window.pid
        let windowID = window.id
        let cachedMinimized = window.isMinimized

        activatorQueue.async {
            if wasHidden {
                waitUntilUnhidden(pid: pid, maxWaitMs: 160)
            }

            // 1. Resolve the target window's live AXUIElement.
            var resolvedAX = resolveLiveAXWindow(
                cached: boxedAX.element,
                pid: pid,
                windowID: windowID
            )
            if let resolvedAX {
                onResolvedAX?(SendableAXElement(element: resolvedAX))
            }

            // 2. Check live minimized state on this specific AXUIElement.
            var actuallyMinimized = cachedMinimized
            if let ax = resolvedAX {
                AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
                if let liveMin = readBoolAttribute(ax, kAXMinimizedAttribute) {
                    actuallyMinimized = liveMin
                }
            }

            if singleWindowRaise {
                // 3a. Make target process frontmost scoped strictly to `windowID` via SkyLight.
                // Doing this first also ensures inactive Electron/Chromium processes accept kAXMinimizedAttribute = false
                // without ever activating sibling windows.
                _ = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)

                // If the window was on another Space and AX wasn't resolved yet, try resolving again after Space focus request.
                if resolvedAX == nil {
                    Thread.sleep(forTimeInterval: 0.05)
                    resolvedAX = resolveLiveAXWindow(cached: nil, pid: pid, windowID: windowID)
                    if let resolvedAX {
                        onResolvedAX?(SendableAXElement(element: resolvedAX))
                        if let liveMin = readBoolAttribute(resolvedAX, kAXMinimizedAttribute) {
                            actuallyMinimized = liveMin
                        }
                    }
                }

                // 3b. If this specific window is minimized, unminimize ONLY this AXUIElement.
                if actuallyMinimized, let ax = resolvedAX {
                    unminimizeSingleWindow(ax: ax, pid: pid, windowID: windowID)
                }

                // 3c. Raise ONLY this specific window and lock key-window focus onto `windowID`.
                if let ax = resolvedAX {
                    AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                }
                _ = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)

                if actuallyMinimized || wasHidden {
                    Thread.sleep(forTimeInterval: 0.08)
                    if let ax = resolvedAX {
                        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                    }
                    _ = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)
                }
            } else {
                // Non-single-window mode (macOS standard whole-app activation)
                if actuallyMinimized, let ax = resolvedAX {
                    AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
                    AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    _ = pollUntilUnminimized(ax: ax, maxWaitMs: 250)
                }
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                if let ax = resolvedAX {
                    AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
                    AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                }
            }

            if let onDidFinish {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onDidFinish()
                }
            }
        }
    }

    /// Closes a specific window asynchronously via its AXCloseButton (with strict 250ms AX timeout).
    static func close(axElement: AXUIElement?, completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let axElement else {
            completion?(false)
            return
        }
        let boxedAX = UncheckedAXBox(element: axElement)
        activatorQueue.async {
            guard let ax = boxedAX.element else {
                completion?(false)
                return
            }
            AXUIElementSetMessagingTimeout(ax, probeTimeoutSeconds)
            var closeButtonRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &closeButtonRef)
            guard err == .success, let button = closeButtonRef else {
                completion?(false)
                return
            }
            let axButton = button as! AXUIElement
            AXUIElementSetMessagingTimeout(axButton, probeTimeoutSeconds)
            let ok = (AXUIElementPerformAction(axButton, kAXPressAction as CFString) == .success)
            completion?(ok)
        }
    }

    // MARK: - Background Helpers

    private nonisolated static func resolveLiveAXWindow(
        cached: AXUIElement?,
        pid: pid_t,
        windowID: WindowID
    ) -> AXUIElement? {
        if let cached {
            AXUIElementSetMessagingTimeout(cached, probeTimeoutSeconds)
            if let liveWID = SkyLightBridge.shared.windowID(for: cached), liveWID == windowID {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(cached, kAXRoleAttribute as CFString, &roleRef) == .success {
                    return cached
                }
            }
        }

        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAX, probeTimeoutSeconds)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let axWindows = windowsRef as? [AXUIElement] {
            for win in axWindows {
                if let wid = SkyLightBridge.shared.windowID(for: win), wid == windowID {
                    return win
                }
            }
        }

        let remote = SkyLightBridge.shared.discoverRemoteAXWindows(
            forPID: pid,
            targetWindowIDs: [windowID],
            maxElementID: 1200,
            timeBudgetSeconds: 0.25
        )
        return remote[windowID] ?? cached
    }

    /// Unminimizes ONLY the target `AXUIElement` without activating or restoring any sibling windows.
    private nonisolated static func unminimizeSingleWindow(
        ax: AXUIElement,
        pid: pid_t,
        windowID: WindowID
    ) {
        AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)

        if pollUntilUnminimized(ax: ax, maxWaitMs: 160) {
            return
        }

        // Retry with single-window SkyLight front-process focus (never whole-app activate!)
        _ = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)
        Thread.sleep(forTimeInterval: 0.03)
        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = pollUntilUnminimized(ax: ax, maxWaitMs: 260)
    }

    private nonisolated static func pollUntilUnminimized(ax: AXUIElement, maxWaitMs: Int) -> Bool {
        let stepMs = 25
        var elapsed = 0
        while elapsed < maxWaitMs {
            if let isMin = readBoolAttribute(ax, kAXMinimizedAttribute), !isMin {
                return true
            }
            Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
            elapsed += stepMs
        }
        return (readBoolAttribute(ax, kAXMinimizedAttribute) == false)
    }

    private nonisolated static func readBoolAttribute(_ ax: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private nonisolated static func waitUntilUnhidden(pid: pid_t, maxWaitMs: Int) {
        let stepMs = 15
        var elapsed = 0
        while elapsed < maxWaitMs {
            if NSRunningApplication(processIdentifier: pid)?.isHidden == false {
                return
            }
            Thread.sleep(forTimeInterval: Double(stepMs) / 1000.0)
            elapsed += stepMs
        }
    }
}
