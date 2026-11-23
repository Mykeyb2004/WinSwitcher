import AppKit
import Combine
import CoreGraphics
import Foundation
import WinSwitcherCore

@MainActor
final class SwitcherViewModel: ObservableObject {
    @Published var windows: [WindowDescriptor] = []
    @Published var selectedIndex: Int = 0
    @Published var hoveredWindowID: WindowID?
    @Published var gridMetrics: SwitcherGridMetrics = GridLayoutCalculator.compute(
        itemCount: 1,
        screenSize: CGSize(width: 1440, height: 900)
    )

    var selectedWindow: WindowDescriptor? {
        guard windows.indices.contains(selectedIndex) else { return nil }
        return windows[selectedIndex]
    }
}

/// Orchestrates hardened EventTap hotkeys, Windows fast-switch delay, MRU session state,
/// passive outside-click cancellation, physical modifier failsafe watchdog, HUD presentation, and window activation.
@MainActor
final class SwitcherController: ObservableObject {
    static let shared = SwitcherController()

    let viewModel = SwitcherViewModel()

    @Published private(set) var isPaused: Bool = false
    @Published private(set) var isCircuitBreakerTripped: Bool = false

    private let hotkeyManager = HotkeyManager()
    private let tracker = WindowTracker.shared
    private var hudPanel: SwitcherHUDPanel?
    private var showDelayWorkItem: DispatchWorkItem?
    private var globalMouseMonitor: Any?
    private var modifierWatchdogTimer: Timer?
    private var frontmostAppObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        wireHotkeyManager()
        observePermissionsAndSettings()
    }

    func start() {
        hotkeyManager.updateShortcutMode(AppSettings.shared.shortcutMode)
        hotkeyManager.setPaused(isPaused)
        syncFrontmostAppExclusion()
        installFrontmostAppObserver()

        tracker.start()
        _ = hotkeyManager.start()
        ConflictDetector.shared.scan()
    }

    func stop() {
        cancelShowDelay()
        stopModifierWatchdog()
        removeGlobalMouseMonitor()
        if let obs = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            frontmostAppObserver = nil
        }
        hudPanel?.hideHUD()
        hotkeyManager.stop()
        tracker.stop()
    }

    var isHotkeyTapActive: Bool {
        hotkeyManager.isRunning
    }

    // MARK: - Safety & Pause Controls

    func togglePause() {
        setPaused(!isPaused)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        hotkeyManager.setPaused(paused)
        if paused && tracker.mruEngine.isSessionActive {
            cancelCurrentSession()
        }
    }

    func resetCircuitBreaker() {
        isCircuitBreakerTripped = false
        let started = hotkeyManager.start(resetCircuitBreaker: true)
        if !started {
            isCircuitBreakerTripped = hotkeyManager.isCircuitBreakerTripped
        }
    }

    // MARK: - Actions from UI (Mouse Click / Close Button)

    func commitByClicking(index: Int) {
        guard tracker.mruEngine.isSessionActive else { return }
        tracker.selectIndex(index)
        commitCurrentSession()
    }

    func closeWindowFromHUD(_ windowID: WindowID) {
        guard tracker.mruEngine.isSessionActive else { return }
        tracker.closeWindowInSession(windowID: windowID) { [weak self] in
            guard let self else { return }
            if !self.tracker.mruEngine.isSessionActive {
                self.cancelShowDelay()
                self.stopModifierWatchdog()
                self.removeGlobalMouseMonitor()
                self.hotkeyManager.setSessionActive(false)
                self.hudPanel?.hideHUD()
            } else {
                self.syncViewModelFromSession()
                if self.hudPanel?.isVisible == true {
                    self.hudPanel?.updateFrame(for: self.viewModel.gridMetrics, targetScreen: self.resolveTargetScreen())
                }
            }
        }
    }

    // MARK: - Private Wiring

    private func wireHotkeyManager() {
        hotkeyManager.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleHotkeyEvent(event)
            }
        }
        hotkeyManager.onCircuitBreakerTripped = { [weak self] in
            Task { @MainActor in
                self?.handleCircuitBreakerTripped()
            }
        }
    }

    private func handleCircuitBreakerTripped() {
        isCircuitBreakerTripped = true
        cancelCurrentSession()
        ConflictDetector.shared.scan()
    }

    private func observePermissionsAndSettings() {
        PermissionsManager.shared.$hasAccessibility
            .removeDuplicates()
            .sink { [weak self] granted in
                guard let self, granted else { return }
                if !self.hotkeyManager.isRunning && !self.isCircuitBreakerTripped {
                    _ = self.hotkeyManager.start()
                }
                self.tracker.attachObserversToAllRegularApps()
                self.tracker.refreshAll(includeRemoteAXDiscovery: true)
                ConflictDetector.shared.scan()
            }
            .store(in: &cancellables)

        AppSettings.shared.$shortcutMode
            .sink { [weak self] mode in
                self?.hotkeyManager.updateShortcutMode(mode)
            }
            .store(in: &cancellables)

        AppSettings.shared.$sinkMinimizedToEnd
            .dropFirst()
            .sink { [weak self] _ in
                self?.tracker.updateSettingsFromShared()
            }
            .store(in: &cancellables)

        AppSettings.shared.$pauseInSystemSettings
            .combineLatest(AppSettings.shared.$excludedBundleIDs)
            .sink { [weak self] _, _ in
                self?.syncFrontmostAppExclusion()
            }
            .store(in: &cancellables)
    }

    private func installFrontmostAppObserver() {
        guard frontmostAppObserver == nil else { return }
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncFrontmostAppExclusion()
            }
        }
    }

    private func syncFrontmostAppExclusion() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let excluded = AppSettings.shared.isBundleExcluded(bundleID)
        hotkeyManager.setFrontmostAppExcluded(excluded)
    }

    // MARK: - Passive Click-Outside Monitor & Modifier Failsafe Watchdog

    /// Installs a PASSIVE, non-blocking NSEvent monitor only while HUD is visible.
    /// Unlike CGEventTap, this can NEVER block or freeze macOS mouse input.
    private func installGlobalMouseMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.tracker.mruEngine.isSessionActive,
                      let panel = self.hudPanel,
                      panel.isVisible else { return }
                let mousePt = NSEvent.mouseLocation
                if !panel.frame.contains(mousePt) {
                    self.cancelCurrentSession()
                }
            }
        }
    }

    private func removeGlobalMouseMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }

    /// Every 250ms while a session is active, verifies via HID system state that the physical
    /// trigger modifier key is still held. Self-heals if macOS ever dropped a `flagsChanged` event.
    private func startModifierWatchdog() {
        stopModifierWatchdog()
        modifierWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tracker.mruEngine.isSessionActive else {
                    self?.stopModifierWatchdog()
                    return
                }
                guard let requiredFlag = self.hotkeyManager.activeRequiredModifier else {
                    self.commitCurrentSession()
                    return
                }
                let hidFlags = CGEventSource.flagsState(.hidSystemState)
                if !hidFlags.contains(requiredFlag) {
                    self.commitCurrentSession()
                }
            }
        }
    }

    private func stopModifierWatchdog() {
        modifierWatchdogTimer?.invalidate()
        modifierWatchdogTimer = nil
    }

    // MARK: - Event Handling

    private func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .triggerOrStep(let backwards):
            if !tracker.mruEngine.isSessionActive {
                guard tracker.beginSwitcherSession(backwards: backwards) else {
                    hotkeyManager.setSessionActive(false)
                    return
                }
                syncViewModelFromSession()
                startModifierWatchdog()
                scheduleOrShowHUD()
            } else {
                if backwards {
                    tracker.stepBackward()
                } else {
                    tracker.stepForward()
                }
                syncViewModelFromSession()
                showHUDImmediately()
            }

        case .moveDirection(let direction):
            guard tracker.mruEngine.isSessionActive else { return }
            tracker.moveSelection(direction: direction, columns: viewModel.gridMetrics.columns)
            syncViewModelFromSession()
            showHUDImmediately()

        case .closeSelected:
            guard tracker.mruEngine.isSessionActive,
                  let selected = viewModel.selectedWindow else { return }
            closeWindowFromHUD(selected.id)

        case .commit, .modifierReleased:
            commitCurrentSession()

        case .cancel:
            cancelCurrentSession()
        }
    }

    private func syncViewModelFromSession() {
        let items = tracker.sessionWindows()
        let screen = resolveTargetScreen()
        let screenSize = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        viewModel.windows = items
        viewModel.selectedIndex = tracker.mruEngine.selectedIndex
        viewModel.gridMetrics = GridLayoutCalculator.compute(
            itemCount: items.count,
            screenSize: screenSize
        )
    }

    private func scheduleOrShowHUD() {
        cancelShowDelay()
        let delayMs = AppSettings.shared.showDelayMs
        if delayMs <= 5 {
            showHUDImmediately()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.tracker.mruEngine.isSessionActive else { return }
                self.showHUDImmediately()
            }
        }
        showDelayWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: item)
    }

    private func showHUDImmediately() {
        cancelShowDelay()
        if hudPanel == nil {
            hudPanel = SwitcherHUDPanel(
                viewModel: viewModel,
                onSelectIndex: { [weak self] idx in
                    self?.commitByClicking(index: idx)
                },
                onCloseWindow: { [weak self] wid in
                    self?.closeWindowFromHUD(wid)
                }
            )
        }
        hudPanel?.showHUD(metrics: viewModel.gridMetrics, targetScreen: resolveTargetScreen())
        installGlobalMouseMonitor()
    }

    private func commitCurrentSession() {
        cancelShowDelay()
        stopModifierWatchdog()
        removeGlobalMouseMonitor()
        hotkeyManager.setSessionActive(false)
        hudPanel?.hideHUD()

        guard let target = tracker.commitSwitcherSession() else { return }
        let axElement = tracker.axElement(for: target.id)
        WindowActivator.activate(
            window: target,
            axElement: axElement,
            singleWindowRaise: AppSettings.shared.singleWindowRaise
        )
    }

    private func cancelCurrentSession() {
        cancelShowDelay()
        stopModifierWatchdog()
        removeGlobalMouseMonitor()
        hotkeyManager.setSessionActive(false)
        hudPanel?.hideHUD()
        tracker.cancelSwitcherSession()
    }

    private func cancelShowDelay() {
        showDelayWorkItem?.cancel()
        showDelayWorkItem = nil
    }

    private func resolveTargetScreen() -> NSScreen? {
        switch AppSettings.shared.hudDisplayTarget {
        case .primaryScreen:
            return NSScreen.screens.first
        case .mouseScreen:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        case .activeWindowScreen:
            if let first = viewModel.windows.first, first.frame.width > 0, first.frame.height > 0 {
                if let primaryHeight = NSScreen.screens.first?.frame.height {
                    let centerCG = CGPoint(x: first.frame.midX, y: first.frame.midY)
                    let centerAppKit = CGPoint(x: centerCG.x, y: primaryHeight - centerCG.y)
                    if let matched = NSScreen.screens.first(where: { $0.frame.contains(centerAppKit) }) {
                        return matched
                    }
                }
            }
            return NSScreen.main ?? NSScreen.screens.first
        }
    }
}
