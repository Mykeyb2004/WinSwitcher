import AppKit
import ApplicationServices
import Foundation
import WinSwitcherCore

private struct UncheckedAXBox: @unchecked Sendable {
    let element: AXUIElement?
}

/// Activates or closes a specific macOS window with Windows-style single-window focus, automatic unminimize/unhide,
/// and cross-Space transition. All cross-process AX/SkyLight IPC runs on a dedicated queue with a strict 150ms
/// timeout so a hung or modal target app can NEVER stall the Main Thread.
@MainActor
enum WindowActivator {
    private static let activatorQueue = DispatchQueue(
        label: "com.winswitcher.activator",
        qos: .userInteractive
    )
    private nonisolated static let axTimeoutSeconds: Float = 0.15

    static func activate(
        window: WindowDescriptor,
        axElement: AXUIElement?,
        singleWindowRaise: Bool
    ) {
        let app = NSRunningApplication(processIdentifier: window.pid)

        // 1. Unhide the owning application if it was hidden via Cmd+H (AppKit call on MainActor).
        if let app, app.isHidden {
            app.unhide()
        }

        let boxedAX = UncheckedAXBox(element: axElement)
        let pid = window.pid
        let windowID = window.id
        let isMinimized = window.isMinimized

        activatorQueue.async {
            if let ax = boxedAX.element {
                AXUIElementSetMessagingTimeout(ax, axTimeoutSeconds)
                if isMinimized {
                    AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
            }

            if singleWindowRaise {
                let skyLightOK = SkyLightBridge.shared.focusSingleWindow(pid: pid, windowID: windowID)
                if let ax = boxedAX.element {
                    AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                }
                if !skyLightOK {
                    DispatchQueue.main.async {
                        NSRunningApplication(processIdentifier: pid)?.activate()
                    }
                }
            } else {
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: pid)?.activate()
                }
                if let ax = boxedAX.element {
                    AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
                    AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
                }
            }
        }
    }

    /// Closes a specific window asynchronously via its AXCloseButton (with strict 150ms AX timeout).
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
            AXUIElementSetMessagingTimeout(ax, axTimeoutSeconds)
            var closeButtonRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &closeButtonRef)
            guard err == .success, let button = closeButtonRef else {
                completion?(false)
                return
            }
            let axButton = button as! AXUIElement
            AXUIElementSetMessagingTimeout(axButton, axTimeoutSeconds)
            let ok = (AXUIElementPerformAction(axButton, kAXPressAction as CFString) == .success)
            completion?(ok)
        }
    }
}
