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
/// guaranteed unminimize/unhide restoration, and cross-Space transition.
///
/// All cross-process AX/SkyLight IPC runs on a dedicated background queue so a slow or hung
/// target app can NEVER stall the Main Thread or EventTap.
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
        let bundleURL = app?.bundleURL

        // 1. Unhide owning application first if it was hidden via Cmd+H.
        if let app, wasHidden {
            app.unhide()
        }

        let boxedAX = UncheckedAXBox(element: axElement)
        let pid = window.pid
        let windowID = window.id
        let cachedMinimized = window.isMinimized

        activatorQueue.async {
            // If the app was hidden, give macOS a brief window to finish unhiding its windows before focusing.
            if wasHidden {
                waitUntilUnhidden(pid: pid, maxWaitMs: 180)
            }

            // 2. Always obtain a LIVE AXUIElement (resolving on demand if nil or stale, including off-Space windows).
            let resolvedAX = resolveLiveAXWindow(
                cached: boxedAX.element,
                pid: pid,
                windowID: windowID
            )
            if let resolvedAX {
                onResolvedAX?(SendableAXElement(element: resolvedAX))
            }

            // 3. Check the LIVE kAXMinimizedAttribute (never rely solely on cached descriptor.isMinimized!).
            var actuallyMinimized = cachedMinimized
            if let ax = resolvedAX {
                AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
                if let liveMin = readBoolAttribute(ax, kAXMinimizedAttribute) {
                    actuallyMinimized = liveMin
                }
            }

            // 4. Restore (unminimize) if minimized.
            var didUnminimize = false
            if actuallyMinimized {
                if let ax = resolvedAX {
                    didUnminimize = unminimizeWindow(ax: ax, pid: pid)
                }

                // Fallback for non-standard apps where AXUIElement was unavailable or rejected kAXMinimizedAttribute:
                // sending an open/reopen event matches clicking the Dock icon and unminimizes the window.
                if !didUnminimize, let bundleURL {
                    reopenApplicationFallback(bundleURL: bundleURL)
                    Thread.sleep(forTimeInterval: 0.12)
                } else if didUnminimize {
                    // Brief pause so WindowServer finishes mapping the window out of the Dock before raising/focusing.
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            // 5. Focus and raise the target window.
            performFocusAndRaise(
                pid: pid,
                windowID: windowID,
                ax: resolvedAX,
                singleWindowRaise: singleWindowRaise,
                wasRestoredFromMinimizedOrHidden: actuallyMinimized || wasHidden
            )

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
        // Verify cached AX element is still alive and maps to the exact same CGWindowID.
        if let cached {
            AXUIElementSetMessagingTimeout(cached, probeTimeoutSeconds)
            if let liveWID = SkyLightBridge.shared.windowID(for: cached), liveWID == windowID {
                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(cached, kAXRoleAttribute as CFString, &roleRef) == .success {
                    return cached
                }
            }
        }

        // Fast live lookup via kAXWindowsAttribute (covers all current-Space & Dock-minimized windows).
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

        // Off-Space fallback: discover via macOS remote AX token (covers windows minimized on other Spaces).
        let remote = SkyLightBridge.shared.discoverRemoteAXWindows(
            forPID: pid,
            targetWindowIDs: [windowID],
            maxElementID: 1000,
            timeBudgetSeconds: 0.25
        )
        return remote[windowID] ?? cached
    }

    private nonisolated static func unminimizeWindow(ax: AXUIElement, pid: pid_t) -> Bool {
        AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)

        let firstErr = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if pollUntilUnminimized(ax: ax, maxWaitMs: 180) {
            return true
        }

        // Some macOS / Chromium / Electron apps ignore kAXMinimizedAttribute = false while their process is inactive.
        // Activate the process and retry setting kAXMinimizedAttribute = false.
        activateAppOnMain(pid: pid)
        Thread.sleep(forTimeInterval: 0.04)
        let secondErr = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if pollUntilUnminimized(ax: ax, maxWaitMs: 250) {
            return true
        }

        return firstErr == .success || secondErr == .success
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

    private nonisolated static func performFocusAndRaise(
        pid: pid_t,
        windowID: WindowID,
        ax: AXUIElement?,
        singleWindowRaise: Bool,
        wasRestoredFromMinimizedOrHidden: Bool
    ) {
        if singleWindowRaise {
            let skyLightOK = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)
            raiseAXWindow(ax)

            if wasRestoredFromMinimizedOrHidden {
                // Re-assert focus after the Dock deminiaturize / unhide transition so the restored window
                // never finishes behind the previously active window.
                Thread.sleep(forTimeInterval: 0.07)
                let retryOK = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)
                raiseAXWindow(ax)

                if !skyLightOK && !retryOK {
                    activateAppOnMain(pid: pid)
                    raiseAXWindow(ax)
                } else if !isAppActive(pid: pid) {
                    activateAppOnMain(pid: pid)
                    raiseAXWindow(ax)
                }
            } else if !skyLightOK {
                activateAppOnMain(pid: pid)
                raiseAXWindow(ax)
            }
        } else {
            activateAppOnMain(pid: pid)
            raiseAXWindow(ax)
            if wasRestoredFromMinimizedOrHidden {
                Thread.sleep(forTimeInterval: 0.07)
                raiseAXWindow(ax)
            }
        }
    }

    private nonisolated static func raiseAXWindow(_ ax: AXUIElement?) {
        guard let ax else { return }
        AXUIElementSetMessagingTimeout(ax, restoreTimeoutSeconds)
        AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
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

    private nonisolated static func isAppActive(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.isActive == true
    }

    private nonisolated static func activateAppOnMain(pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAX, restoreTimeoutSeconds)
        AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        DispatchQueue.main.async {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.unhide()
                app.activate()
            }
        }
    }

    private nonisolated static func reopenApplicationFallback(bundleURL: URL) {
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        }
    }
}
