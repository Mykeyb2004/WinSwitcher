import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import os
import WinSwitcherCore

enum HotkeyEvent: Sendable {
    case triggerOrStep(backwards: Bool)
    case moveDirection(GridDirection)
    case commit
    case cancel
    case closeSelected
    case modifierReleased
}

/// Safe dynamic lookup for macOS `IsSecureEventInputEnabled()` so we automatically pass keys through
/// when password fields, sudo prompts, or System Settings shortcut recorders activate secure input.
private final class SecureInputChecker: @unchecked Sendable {
    static let shared = SecureInputChecker()
    private typealias IsSecureEventInputEnabledFn = @convention(c) () -> DarwinBoolean
    private let fn: IsSecureEventInputEnabledFn?

    private init() {
        let handle = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY)
        if let handle, let sym = dlsym(handle, "IsSecureEventInputEnabled") {
            self.fn = unsafeBitCast(sym, to: IsSecureEventInputEnabledFn.self)
        } else {
            self.fn = nil
        }
    }

    var isSecureInputEnabled: Bool {
        fn?().boolValue ?? false
    }
}

/// Ultra-lightweight state shared between MainActor and the dedicated EventTap thread.
/// Lock hold time is strictly < 2 microseconds (pure value reads/writes, zero IPC/AppKit/allocation).
private struct TapSharedState: Sendable {
    var shortcutMode: ShortcutMode = .optionTab
    var isSessionActive: Bool = false
    var activeSessionModifierRaw: UInt64 = 0
    var isPaused: Bool = false
    var isFrontmostAppExcluded: Bool = false
    var circuitBreaker = TapCircuitBreaker(maxTimeouts: 2, windowSeconds: 10.0)
    var isRunning: Bool = false
}

/// Hardened global hotkey interceptor running on its OWN dedicated real-time thread & CFRunLoop.
///
/// Anti-freeze guarantees:
/// 1. NEVER taps mouse events (`leftMouseDown` is completely excluded; mouse can never freeze).
/// 2. NEVER executes on the Main Thread and NEVER synchronously waits on MainActor, AppKit, or AX IPC.
/// 3. Callback completes in < 50 microseconds and dispatches all events asynchronously to MainActor.
/// 4. Hardware emergency exit (`Ctrl + Option + Command + Esc`) disables tap and exits instantly via `_exit(0)`.
/// 5. Sliding-window Circuit Breaker permanently disables tap if macOS reports repeated timeouts.
/// 6. Auto-passes through during `IsSecureEventInputEnabled()`, pause mode, or excluded apps (e.g., System Settings).
/// 7. Anti-stuck guard: if any `keyDown` arrives while `isSessionActive` is true WITHOUT the trigger modifier held,
///    immediately ends the session and lets the keystroke pass through untouched.
final class HotkeyManager: @unchecked Sendable {
    private let stateLock = OSAllocatedUnfairLock(initialState: TapSharedState())

    private let lifecycleLock = NSLock()
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let callbackLock = NSLock()
    private var _onEvent: (@Sendable (HotkeyEvent) -> Void)?
    private var _onCircuitBreakerTripped: (@Sendable () -> Void)?

    var onEvent: (@Sendable (HotkeyEvent) -> Void)? {
        get { callbackLock.withLock { _onEvent } }
        set { callbackLock.withLock { _onEvent = newValue } }
    }

    var onCircuitBreakerTripped: (@Sendable () -> Void)? {
        get { callbackLock.withLock { _onCircuitBreakerTripped } }
        set { callbackLock.withLock { _onCircuitBreakerTripped = newValue } }
    }

    var isRunning: Bool {
        stateLock.withLock { $0.isRunning }
    }

    var isCircuitBreakerTripped: Bool {
        stateLock.withLock { $0.circuitBreaker.isTripped }
    }

    var activeRequiredModifier: CGEventFlags? {
        stateLock.withLock { state in
            guard state.isSessionActive, state.activeSessionModifierRaw != 0 else { return nil }
            return CGEventFlags(rawValue: state.activeSessionModifierRaw)
        }
    }

    // MARK: - State Sync (Called from MainActor, O(1) non-blocking)

    func updateShortcutMode(_ mode: ShortcutMode) {
        stateLock.withLock { $0.shortcutMode = mode }
    }

    func setPaused(_ paused: Bool) {
        stateLock.withLock { state in
            state.isPaused = paused
            if paused {
                state.isSessionActive = false
                state.activeSessionModifierRaw = 0
            }
        }
    }

    func setFrontmostAppExcluded(_ excluded: Bool) {
        stateLock.withLock { state in
            state.isFrontmostAppExcluded = excluded
        }
    }

    func setSessionActive(_ active: Bool) {
        stateLock.withLock { state in
            state.isSessionActive = active
            if !active {
                state.activeSessionModifierRaw = 0
            }
        }
    }

    // MARK: - Lifecycle (Dedicated EventTap Thread)

    @discardableResult
    func start(resetCircuitBreaker: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        if resetCircuitBreaker {
            stateLock.withLock { $0.circuitBreaker.reset() }
        }

        if stateLock.withLock({ $0.circuitBreaker.isTripped }) {
            return false
        }

        lifecycleLock.lock()
        if tapThread != nil {
            lifecycleLock.unlock()
            return true
        }

        let startedSemaphore = DispatchSemaphore(value: 0)
        let startSucceeded = OSAllocatedUnfairLock(initialState: false)

        let thread = Thread { [weak self] in
            guard let self else {
                startedSemaphore.signal()
                return
            }

            // ONLY intercept keyboard events — NEVER mouse events!
            let mask =
                (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

            let refcon = Unmanaged.passUnretained(self).toOpaque()
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: hotkeyEventTapCallback,
                userInfo: refcon
            ) else {
                startedSemaphore.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)

            self.lifecycleLock.lock()
            self.eventTap = tap
            self.runLoopSource = source
            self.tapRunLoop = rl
            self.lifecycleLock.unlock()

            self.stateLock.withLock { $0.isRunning = true }
            startSucceeded.withLock { $0 = true }
            startedSemaphore.signal()

            CFRunLoopRun()

            // Cleanup on dedicated thread exit
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)

            self.lifecycleLock.lock()
            self.eventTap = nil
            self.runLoopSource = nil
            self.tapRunLoop = nil
            self.tapThread = nil
            self.lifecycleLock.unlock()

            self.stateLock.withLock { state in
                state.isRunning = false
                state.isSessionActive = false
                state.activeSessionModifierRaw = 0
            }
        }
        thread.name = "com.winswitcher.event-tap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        lifecycleLock.unlock()

        thread.start()
        _ = startedSemaphore.wait(timeout: .now() + 1.0)

        let didStartTap = startSucceeded.withLock { $0 }
        if !didStartTap {
            lifecycleLock.lock()
            self.tapThread = nil
            lifecycleLock.unlock()
        }
        return didStartTap
    }

    func stop() {
        lifecycleLock.lock()
        let rl = tapRunLoop
        let tap = eventTap
        lifecycleLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl {
            CFRunLoopStop(rl)
        }

        stateLock.withLock { state in
            state.isRunning = false
            state.isSessionActive = false
            state.activeSessionModifierRaw = 0
        }
    }

    // MARK: - Real-Time EventTap Callback (Runs ONLY on com.winswitcher.event-tap thread!)

    fileprivate func handleTapCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        // 1. Timeout / User-disabled safety handling with Circuit Breaker
        if type == .tapDisabledByUserInput {
            // Never fight macOS or user disabling our tap
            return false
        }

        if type == .tapDisabledByTimeout {
            let now = CFAbsoluteTimeGetCurrent()
            let canReenable = stateLock.withLock { state -> Bool in
                let ok = state.circuitBreaker.recordTimeout(at: now)
                if !ok {
                    state.isSessionActive = false
                    state.activeSessionModifierRaw = 0
                    state.isRunning = false
                }
                return ok
            }

            lifecycleLock.lock()
            let tap = eventTap
            let rl = tapRunLoop
            lifecycleLock.unlock()

            if canReenable, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                // Circuit breaker tripped! Permanently disable tap & stop thread so OS input stays 100% responsive.
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: false)
                }
                if let rl {
                    CFRunLoopStop(rl)
                }
                let notifyTrip = onCircuitBreakerTripped
                DispatchQueue.main.async {
                    notifyTrip?()
                }
            }
            return false
        }

        // Extract pure value fields from CGEvent BEFORE acquiring the unfair lock
        let eventFlags = event.flags
        let eventKeyCode: Int64 = (type == .keyDown) ? event.getIntegerValueField(.keyboardEventKeycode) : -1

        // 2. Hard-coded Emergency Hardware Kill Switch: Ctrl + Option + Command + Esc (keyCode 53)
        // Immediately disables tap and terminates process at kernel level — impossible to deadlock!
        if type == .keyDown,
           eventKeyCode == 53,
           eventFlags.contains([.maskControl, .maskAlternate, .maskCommand]) {
            lifecycleLock.lock()
            let tap = eventTap
            lifecycleLock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            Darwin._exit(0)
        }

        // 3. Evaluate lightweight state under < 2µs unfair lock (pure values only)
        enum Decision {
            case passThrough
            case passThroughAndDispatch(HotkeyEvent)
            case consumeAndDispatch(HotkeyEvent)
        }

        let decision: Decision = stateLock.withLock { state -> Decision in
            if state.circuitBreaker.isTripped {
                return .passThrough
            }

            switch type {
            case .flagsChanged:
                guard state.isSessionActive, state.activeSessionModifierRaw != 0 else {
                    return .passThrough
                }
                let requiredFlag = CGEventFlags(rawValue: state.activeSessionModifierRaw)
                if !eventFlags.contains(requiredFlag) {
                    state.isSessionActive = false
                    state.activeSessionModifierRaw = 0
                    return .passThroughAndDispatch(.modifierReleased)
                }
                return .passThrough

            case .keyDown:
                // Anti-stuck session guard: if a session thinks it's active, verify the trigger modifier
                // is STILL physically held. If not, auto-release and let the user's typing pass through!
                if state.isSessionActive {
                    let requiredFlag = CGEventFlags(rawValue: state.activeSessionModifierRaw)
                    if state.activeSessionModifierRaw != 0 && !eventFlags.contains(requiredFlag) {
                        state.isSessionActive = false
                        state.activeSessionModifierRaw = 0
                        return .passThroughAndDispatch(.modifierReleased)
                    }

                    // Active session key navigation (ONLY while trigger modifier is physically held)
                    switch eventKeyCode {
                    case 48: // Tab
                        return .consumeAndDispatch(.triggerOrStep(backwards: eventFlags.contains(.maskShift)))
                    case 53: // Escape
                        state.isSessionActive = false
                        state.activeSessionModifierRaw = 0
                        return .consumeAndDispatch(.cancel)
                    case 123: // Left
                        return .consumeAndDispatch(.moveDirection(.left))
                    case 124: // Right
                        return .consumeAndDispatch(.moveDirection(.right))
                    case 125: // Down
                        return .consumeAndDispatch(.moveDirection(.down))
                    case 126: // Up
                        return .consumeAndDispatch(.moveDirection(.up))
                    case 36, 76, 49: // Return / Enter / Space
                        state.isSessionActive = false
                        state.activeSessionModifierRaw = 0
                        return .consumeAndDispatch(.commit)
                    case 13, 51, 117: // W / Backspace / Forward Delete
                        return .consumeAndDispatch(.closeSelected)
                    default:
                        return .passThrough
                    }
                }

                // Not currently in a session: respect pause, excluded apps (e.g., System Settings), and Secure Input
                if state.isPaused || state.isFrontmostAppExcluded {
                    return .passThrough
                }
                if eventKeyCode != 48 { // Fast exit for 99.9% of normal keystrokes!
                    return .passThrough
                }

                let primaryFlag: CGEventFlags = (state.shortcutMode == .optionTab) ? .maskAlternate : .maskCommand
                let disallowedFlags: CGEventFlags = (state.shortcutMode == .optionTab)
                    ? [.maskCommand, .maskControl]
                    : [.maskAlternate, .maskControl]

                if eventFlags.contains(primaryFlag) && eventFlags.intersection(disallowedFlags).isEmpty {
                    // Check macOS Secure Event Input (passwords / System Settings shortcut recorder) before starting
                    if SecureInputChecker.shared.isSecureInputEnabled {
                        return .passThrough
                    }
                    state.isSessionActive = true
                    state.activeSessionModifierRaw = primaryFlag.rawValue
                    return .consumeAndDispatch(.triggerOrStep(backwards: eventFlags.contains(.maskShift)))
                }

                return .passThrough

            default:
                return .passThrough
            }
        }

        // 4. Dispatch asynchronously to MainActor (NEVER blocks the EventTap thread!)
        switch decision {
        case .passThrough:
            return false
        case .passThroughAndDispatch(let hotkeyEvent):
            if let handler = onEvent {
                DispatchQueue.main.async {
                    handler(hotkeyEvent)
                }
            }
            return false
        case .consumeAndDispatch(let hotkeyEvent):
            if let handler = onEvent {
                DispatchQueue.main.async {
                    handler(hotkeyEvent)
                }
            }
            return true
        }
    }
}

private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    let shouldConsume = manager.handleTapCallback(type: type, event: event)
    return shouldConsume ? nil : Unmanaged.passUnretained(event)
}
