import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import WinSwitcherCore

private struct AppSnapshot: Sendable {
    let pid: pid_t
    let localizedName: String
    let bundleIdentifier: String?
    let isHidden: Bool
}

private struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

private struct AXObserverBox: @unchecked Sendable {
    let observer: AXObserver
}

private struct BackgroundScanResult: Sendable {
    let discovered: [WindowDescriptor]
    let resolvedAX: [WindowID: AXElementBox]
    let focusedWindowID: WindowID?
    let missingOffSpaceByPID: [pid_t: Set<WindowID>]
}

/// Maintains the authoritative cross-Space window catalog and Windows-accurate MRU order.
///
/// Anti-freeze architecture:
/// - ALL cross-process `AXUIElement` and `SkyLight` queries run on a dedicated serial background worker queue.
/// - Every `AXUIElement` gets a strict 150ms messaging timeout (`AXUIElementSetMessagingTimeout`), so a hung
///   or modal app (like System Settings) can NEVER stall our app or WindowServer.
/// - `beginSwitcherSession()` is 100% pure in-memory (0ms, zero AX IPC).
@MainActor
final class WindowTracker: ObservableObject {
    static let shared = WindowTracker()

    @Published private(set) var windowsByID: [WindowID: WindowDescriptor] = [:]
    @Published private(set) var appIconsByPID: [pid_t: NSImage] = [:]

    private(set) var mruEngine: MRUOrderEngine
    private var axElementCache: [WindowID: AXUIElement] = [:]
    private var axObservers: [pid_t: AXObserver] = [:]
    private var observerSetupInFlight: Set<pid_t> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastFocusedWindowID: WindowID?
    private var periodicSyncTimer: Timer?
    private var appSwitchRefreshWorkItem: DispatchWorkItem?
    private var remoteDiscoveryInFlight: Set<pid_t> = []
    private var isScanInFlight: Bool = false
    private var pendingScanNeedsRemoteAX: Bool = false
    private var hasPendingScan: Bool = false

    private let selfPID = ProcessInfo.processInfo.processIdentifier
    private let axWorkerQueue = DispatchQueue(label: "com.winswitcher.ax-worker", qos: .userInitiated)
    private nonisolated static let axTimeoutSeconds: Float = 0.15

    private init() {
        self.mruEngine = MRUOrderEngine(sinkMinimizedToEnd: AppSettings.shared.sinkMinimizedToEnd)
    }

    func start() {
        installWorkspaceObservers()
        refreshAll(includeRemoteAXDiscovery: true)
        attachObserversToAllRegularApps()

        // Gentle fallback reconciliation every 4 seconds (fully off main thread)
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.mruEngine.isSessionActive else { return }
                self.refreshAll(includeRemoteAXDiscovery: true)
            }
        }
    }

    func stop() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
        appSwitchRefreshWorkItem?.cancel()
        appSwitchRefreshWorkItem = nil
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for (_, observer) in axObservers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        axObservers.removeAll()
        observerSetupInFlight.removeAll()
    }

    func updateSettingsFromShared() {
        mruEngine.sinkMinimizedToEnd = AppSettings.shared.sinkMinimizedToEnd
    }

    // MARK: - Public Queries & Mutations

    func orderedWindows() -> [WindowDescriptor] {
        let includeAllSpaces = AppSettings.shared.includeAllSpaces
        return mruEngine.orderedIDs.compactMap { id in
            guard let info = windowsByID[id] else { return nil }
            if !includeAllSpaces && info.spaceKind.isOffCurrentSpace && !info.isMinimizedOrHidden {
                return nil
            }
            return info
        }
    }

    func sessionWindows() -> [WindowDescriptor] {
        mruEngine.sessionSnapshot.compactMap { windowsByID[$0] }
    }

    func axElement(for windowID: WindowID) -> AXUIElement? {
        axElementCache[windowID]
    }

    func cacheAXElement(_ element: AXUIElement, for windowID: WindowID) {
        axElementCache[windowID] = element
    }

    func appIcon(for pid: pid_t) -> NSImage? {
        if let cached = appIconsByPID[pid] {
            return cached
        }
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            appIconsByPID[pid] = icon
            return icon
        }
        return nil
    }

    /// Pure in-memory resolution of the currently active focused window (ZERO AX IPC).
    /// Returns `nil` when the Desktop or a windowless app is frontmost (matching Windows behavior).
    func inferredActiveFocusedWindowID() -> WindowID? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != selfPID,
              frontApp.activationPolicy == .regular else {
            return nil
        }

        let frontPID = frontApp.processIdentifier
        if let lastID = lastFocusedWindowID,
           let info = windowsByID[lastID],
           info.pid == frontPID,
           !info.isMinimizedOrHidden {
            return lastID
        }

        for id in mruEngine.orderedIDs {
            if let info = windowsByID[id], info.pid == frontPID, !info.isMinimizedOrHidden {
                return id
            }
        }
        return nil
    }

    // MARK: - Session Forwarding to MRU Engine (0ms Pure In-Memory!)

    @discardableResult
    func beginSwitcherSession(backwards: Bool) -> Bool {
        mruEngine.sinkMinimizedToEnd = AppSettings.shared.sinkMinimizedToEnd

        // Pure in-memory snapshot — NEVER blocks on cross-process AX IPC when user presses Alt+Tab!
        let activeID = inferredActiveFocusedWindowID()
        let allowedIDs: Set<WindowID>? = AppSettings.shared.includeAllSpaces
            ? nil
            : Set(orderedWindows().map(\.id))

        let started = mruEngine.beginSession(
            activeFocusedWindowID: activeID,
            backwards: backwards,
            allowedWindowIDs: allowedIDs
        )
        if started {
            ThumbnailManager.shared.refreshThumbnails(for: mruEngine.sessionSnapshot, force: false)
        }
        return started
    }

    func stepForward() {
        mruEngine.stepForward()
    }

    func stepBackward() {
        mruEngine.stepBackward()
    }

    func selectIndex(_ index: Int) {
        mruEngine.selectIndex(index)
    }

    func moveSelection(direction: GridDirection, columns: Int) {
        mruEngine.moveSelection(direction: direction, columns: columns)
    }

    func commitSwitcherSession() -> WindowDescriptor? {
        guard let targetID = mruEngine.commitSession(),
              let descriptor = windowsByID[targetID] else {
            return nil
        }
        if descriptor.isMinimized || descriptor.isHidden {
            windowsByID[targetID] = WindowDescriptor(
                id: descriptor.id,
                pid: descriptor.pid,
                appName: descriptor.appName,
                bundleIdentifier: descriptor.bundleIdentifier,
                title: descriptor.title,
                frame: descriptor.frame,
                isMinimized: false,
                isHidden: false,
                isFullscreen: descriptor.isFullscreen,
                spaceID: descriptor.spaceID,
                spaceKind: descriptor.spaceKind
            )
        }
        lastFocusedWindowID = targetID
        return descriptor
    }

    func cancelSwitcherSession() {
        mruEngine.cancelSession()
    }

    func closeWindowInSession(windowID: WindowID, onClosed: @escaping @MainActor () -> Void) {
        let ax = axElementCache[windowID]
        WindowActivator.close(axElement: ax) { [weak self] succeeded in
            Task { @MainActor in
                guard let self, succeeded else { return }
                self.mruEngine.recordClosed(windowID: windowID)
                self.windowsByID.removeValue(forKey: windowID)
                self.axElementCache.removeValue(forKey: windowID)
                onClosed()
            }
        }
    }

    // MARK: - Non-Blocking Cross-Space Window Enumeration (Background Worker)

    func refreshAll(includeRemoteAXDiscovery: Bool) {
        if isScanInFlight {
            hasPendingScan = true
            pendingScanNeedsRemoteAX = pendingScanNeedsRemoteAX || includeRemoteAXDiscovery
            return
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID && !$0.isTerminated
        }
        for app in runningApps where appIconsByPID[app.processIdentifier] == nil {
            if let icon = app.icon {
                appIconsByPID[app.processIdentifier] = icon
            }
        }

        let appSnapshots = runningApps.map {
            AppSnapshot(
                pid: $0.processIdentifier,
                localizedName: $0.localizedName ?? "Unknown",
                bundleIdentifier: $0.bundleIdentifier,
                isHidden: $0.isHidden
            )
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPID: pid_t? = (frontApp != nil && frontApp!.activationPolicy == .regular && frontApp!.processIdentifier != selfPID)
            ? frontApp!.processIdentifier
            : nil

        let cachedAXSnapshot: [WindowID: AXElementBox] = axElementCache.mapValues { AXElementBox(element: $0) }
        let axTrusted = AXIsProcessTrusted()

        isScanInFlight = true

        axWorkerQueue.async { [weak self] in
            let scanResult = Self.performBackgroundScan(
                appSnapshots: appSnapshots,
                frontPID: frontPID,
                cachedAX: cachedAXSnapshot,
                axTrusted: axTrusted
            )

            Task { @MainActor in
                guard let self else { return }
                self.applyScanResult(scanResult, includeRemoteAXDiscovery: includeRemoteAXDiscovery)
                self.isScanInFlight = false

                if self.hasPendingScan {
                    let nextRemote = self.pendingScanNeedsRemoteAX
                    self.hasPendingScan = false
                    self.pendingScanNeedsRemoteAX = false
                    self.refreshAll(includeRemoteAXDiscovery: nextRemote)
                }
            }
        }
    }

    private func applyScanResult(_ result: BackgroundScanResult, includeRemoteAXDiscovery: Bool) {
        let liveIDs = Set(result.discovered.map(\.id))
        windowsByID = Dictionary(uniqueKeysWithValues: result.discovered.map { ($0.id, $0) })

        for (wid, box) in result.resolvedAX {
            axElementCache[wid] = box.element
        }
        axElementCache = axElementCache.filter { liveIDs.contains($0.key) }
        ThumbnailManager.shared.prune(keeping: liveIDs)

        mruEngine.sync(discoveredWindows: result.discovered, focusedWindowID: result.focusedWindowID)
        if let focused = result.focusedWindowID, liveIDs.contains(focused) {
            lastFocusedWindowID = focused
        }

        if includeRemoteAXDiscovery && !result.missingOffSpaceByPID.isEmpty {
            resolveOffSpaceAXElementsInBackground(result.missingOffSpaceByPID)
        }
    }

    private nonisolated static func performBackgroundScan(
        appSnapshots: [AppSnapshot],
        frontPID: pid_t?,
        cachedAX: [WindowID: AXElementBox],
        axTrusted: Bool
    ) -> BackgroundScanResult {
        let appByPID = Dictionary(uniqueKeysWithValues: appSnapshots.map { ($0.pid, $0) })

        // 1. Gather all Spaces across all displays via SkyLight
        let spaces = SkyLightBridge.shared.allManagedSpaces()
        let spaceByID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0) })
        let allSpaceIDs = spaces.map(\.id)

        // 2. Gather cross-Space window IDs in Z-order from SkyLight + CGWindowList
        let slsWindowIDs = SkyLightBridge.shared.windowIDs(inSpaces: allSpaceIDs)
        let cgRawList = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []

        struct CGWinMeta {
            let id: WindowID
            let pid: pid_t
            let layer: Int
            let title: String
            let frame: CGRect
            let alpha: Double
            let isOnscreen: Bool
        }

        var cgMetaByID: [WindowID: CGWinMeta] = [:]
        var cgOrder: [WindowID] = []
        cgMetaByID.reserveCapacity(cgRawList.count)

        for dict in cgRawList {
            guard let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  appByPID[pid] != nil else {
                continue
            }
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            let alpha = (dict[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let isOnscreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let title = (dict[kCGWindowName as String] as? String) ?? ""

            var frame = CGRect.zero
            if let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict, &frame)
            }

            let meta = CGWinMeta(
                id: wid,
                pid: pid,
                layer: layer,
                title: title,
                frame: frame,
                alpha: alpha,
                isOnscreen: isOnscreen
            )
            cgMetaByID[wid] = meta
            cgOrder.append(wid)
        }

        // 3. Gather standard AXUIElement windows for every running regular app (with strict 150ms timeout!)
        struct AXWinMeta {
            let id: WindowID
            let pid: pid_t
            let element: AXUIElement
            let title: String
            let isMinimized: Bool
            let isFullscreen: Bool
            let role: String
            let subrole: String
        }

        var axMetaByID: [WindowID: AXWinMeta] = [:]
        var resolvedAX: [WindowID: AXElementBox] = [:]
        var focusedWindowID: WindowID?

        if axTrusted {
            for app in appSnapshots {
                let appAX = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(appAX, axTimeoutSeconds)

                if app.pid == frontPID {
                    focusedWindowID = queryFocusedWindowID(forAppAX: appAX)
                }

                var windowsRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                      let axWindows = windowsRef as? [AXUIElement] else {
                    continue
                }

                for axWin in axWindows {
                    AXUIElementSetMessagingTimeout(axWin, axTimeoutSeconds)
                    guard let wid = SkyLightBridge.shared.windowID(for: axWin) else { continue }
                    let role = axStringAttribute(axWin, kAXRoleAttribute) ?? ""
                    let subrole = axStringAttribute(axWin, kAXSubroleAttribute) ?? ""

                    guard isAcceptableAXWindow(role: role, subrole: subrole) else { continue }

                    let title = axStringAttribute(axWin, kAXTitleAttribute) ?? ""
                    let minimized = axBoolAttribute(axWin, kAXMinimizedAttribute) ?? false
                    let fullscreen = axBoolAttribute(axWin, "AXFullScreen") ?? false

                    resolvedAX[wid] = AXElementBox(element: axWin)
                    axMetaByID[wid] = AXWinMeta(
                        id: wid,
                        pid: app.pid,
                        element: axWin,
                        title: title,
                        isMinimized: minimized,
                        isFullscreen: fullscreen,
                        role: role,
                        subrole: subrole
                    )
                }
            }
        }

        // 4. Unified candidate IDs in front-to-back order
        var seen = Set<WindowID>()
        var orderedCandidates: [WindowID] = []

        func appendCandidate(_ wid: WindowID) {
            if seen.insert(wid).inserted {
                orderedCandidates.append(wid)
            }
        }

        for wid in cgOrder { appendCandidate(wid) }
        for wid in slsWindowIDs { appendCandidate(wid) }
        for wid in axMetaByID.keys { appendCandidate(wid) }

        // 5. Assemble clean WindowDescriptors across ALL Spaces & Fullscreen Spaces
        var discovered: [WindowDescriptor] = []
        var missingOffSpaceByPID: [pid_t: Set<WindowID>] = [:]

        for wid in orderedCandidates {
            let cgMeta = cgMetaByID[wid]
            let axMeta = axMetaByID[wid]

            guard let pid = axMeta?.pid ?? cgMeta?.pid,
                  let app = appByPID[pid] else {
                continue
            }

            if let cgMeta {
                guard cgMeta.layer == 0 else { continue }
            } else if let slsLevel = SkyLightBridge.shared.windowLevel(for: wid), slsLevel != 0 {
                continue
            }

            let frame = cgMeta?.frame ?? SkyLightBridge.shared.windowBounds(for: wid) ?? .zero
            if axMeta == nil {
                guard frame.width >= 80, frame.height >= 50 else { continue }
                if let cgMeta, cgMeta.alpha <= 0.01 && !app.isHidden {
                    continue
                }
            } else {
                if !(axMeta?.isMinimized ?? false) && (frame.width > 0 && frame.height > 0) {
                    guard frame.width >= 60, frame.height >= 40 else { continue }
                }
            }

            let winSpaceIDs = SkyLightBridge.shared.spaceIDs(forWindow: wid)
            let primarySpaceID = winSpaceIDs.first { spaceByID[$0] != nil } ?? winSpaceIDs.first
            let spaceKind = classifySpace(
                spaceID: primarySpaceID,
                spaceByID: spaceByID,
                isFullscreenAX: axMeta?.isFullscreen ?? false
            )

            var title = axMeta?.title ?? ""
            var isMinimized = axMeta?.isMinimized ?? false
            var isFullscreen = (axMeta?.isFullscreen ?? false) || isFullscreenKind(spaceKind)

            if axMeta == nil, let cachedBox = cachedAX[wid] {
                let cachedEl = cachedBox.element
                AXUIElementSetMessagingTimeout(cachedEl, axTimeoutSeconds)
                if let cachedRole = axStringAttribute(cachedEl, kAXRoleAttribute),
                   let cachedSubrole = axStringAttribute(cachedEl, kAXSubroleAttribute),
                   !isAcceptableAXWindow(role: cachedRole, subrole: cachedSubrole) {
                    continue
                }
                if title.isEmpty {
                    title = axStringAttribute(cachedEl, kAXTitleAttribute) ?? ""
                }
                if let min = axBoolAttribute(cachedEl, kAXMinimizedAttribute) {
                    isMinimized = min
                }
                if let fs = axBoolAttribute(cachedEl, "AXFullScreen"), fs {
                    isFullscreen = true
                }
            } else if axMeta == nil && axTrusted {
                let slsTitle = SkyLightBridge.shared.windowTitle(for: wid) ?? ""
                let fallbackTitle = !slsTitle.isEmpty ? slsTitle : (cgMeta?.title ?? "")
                let belongsToKnownOtherSpace = spaceKind.isOffCurrentSpace
                if !belongsToKnownOtherSpace && !app.isHidden {
                    continue
                }
                title = fallbackTitle
                missingOffSpaceByPID[pid, default: []].insert(wid)
            }

            if title.isEmpty {
                let cgTitle = cgMeta?.title ?? ""
                if !cgTitle.isEmpty {
                    title = cgTitle
                } else if let slsTitle = SkyLightBridge.shared.windowTitle(for: wid), !slsTitle.isEmpty {
                    title = slsTitle
                }
            }

            let descriptor = WindowDescriptor(
                id: wid,
                pid: pid,
                appName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                title: title,
                frame: frame,
                isMinimized: isMinimized,
                isHidden: app.isHidden,
                isFullscreen: isFullscreen,
                spaceID: primarySpaceID,
                spaceKind: isFullscreen ? .fullscreen(index: nil) : spaceKind
            )
            discovered.append(descriptor)
        }

        let liveIDs = Set(discovered.map(\.id))
        let validFocusedID = focusedWindowID.flatMap { liveIDs.contains($0) ? $0 : nil }

        return BackgroundScanResult(
            discovered: discovered,
            resolvedAX: resolvedAX,
            focusedWindowID: validFocusedID,
            missingOffSpaceByPID: missingOffSpaceByPID
        )
    }

    private func resolveOffSpaceAXElementsInBackground(_ missingByPID: [pid_t: Set<WindowID>]) {
        for (pid, targetIDs) in missingByPID {
            guard !remoteDiscoveryInFlight.contains(pid) else { continue }
            remoteDiscoveryInFlight.insert(pid)

            axWorkerQueue.async { [weak self, pid, targetIDs] in
                let resolved = SkyLightBridge.shared.discoverRemoteAXWindows(
                    forPID: pid,
                    targetWindowIDs: targetIDs
                )

                var metadataUpdates: [(WindowID, AXElementBox, String?, Bool?, Bool?)] = []
                for (wid, axEl) in resolved {
                    AXUIElementSetMessagingTimeout(axEl, Self.axTimeoutSeconds)
                    let axTitle = Self.axStringAttribute(axEl, kAXTitleAttribute)
                    let axMin = Self.axBoolAttribute(axEl, kAXMinimizedAttribute)
                    let axFS = Self.axBoolAttribute(axEl, "AXFullScreen")
                    metadataUpdates.append((wid, AXElementBox(element: axEl), axTitle, axMin, axFS))
                }

                Task { @MainActor in
                    guard let self else { return }
                    self.remoteDiscoveryInFlight.remove(pid)
                    for (wid, box, axTitle, axMin, axFS) in metadataUpdates {
                        self.axElementCache[wid] = box.element
                        if let existing = self.windowsByID[wid] {
                            let resolvedTitle = (axTitle?.isEmpty == false) ? axTitle! : existing.title
                            let resolvedMin = axMin ?? existing.isMinimized
                            let resolvedFS = axFS ?? existing.isFullscreen
                            self.windowsByID[wid] = WindowDescriptor(
                                id: existing.id,
                                pid: existing.pid,
                                appName: existing.appName,
                                bundleIdentifier: existing.bundleIdentifier,
                                title: resolvedTitle,
                                frame: existing.frame,
                                isMinimized: resolvedMin,
                                isHidden: existing.isHidden,
                                isFullscreen: resolvedFS,
                                spaceID: existing.spaceID,
                                spaceKind: resolvedFS ? .fullscreen(index: nil) : existing.spaceKind
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - NSWorkspace & AXObserver Real-Time Event Tracking

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.handleAppActivated(app)
                }
            }
        )

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.handleAppHidden(app)
                }
            }
        )

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    self?.handleAppUnhidden(app)
                }
            }
        )

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    if let app, app.activationPolicy == .regular {
                        self?.attachObserver(for: app.processIdentifier)
                        self?.refreshAll(includeRemoteAXDiscovery: false)
                    }
                    ConflictDetector.shared.scan()
                }
            }
        )

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor in
                    if let pid = app?.processIdentifier {
                        self?.detachObserver(for: pid)
                        self?.appIconsByPID.removeValue(forKey: pid)
                        self?.refreshAll(includeRemoteAXDiscovery: false)
                    }
                    ConflictDetector.shared.scan()
                }
            }
        )

        workspaceObservers.append(
            nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.mruEngine.isSessionActive else { return }
                    self.refreshAll(includeRemoteAXDiscovery: true)
                }
            }
        )
    }

    private func handleAppActivated(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != selfPID, app.activationPolicy == .regular else { return }

        if let prevID = lastFocusedWindowID {
            ThumbnailManager.shared.captureSnapshot(for: prevID)
        }

        let pid = app.processIdentifier
        attachObserver(for: pid)

        guard !mruEngine.isSessionActive, AXIsProcessTrusted() else { return }

        // Query newly activated app's focused window asynchronously with 150ms AX timeout (NEVER blocks Main Thread!)
        axWorkerQueue.async { [weak self, pid] in
            let appAX = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appAX, Self.axTimeoutSeconds)
            let wid = Self.queryFocusedWindowID(forAppAX: appAX)

            Task { @MainActor in
                guard let self, !self.mruEngine.isSessionActive, let wid else { return }
                if self.windowsByID[wid] == nil {
                    self.refreshAll(includeRemoteAXDiscovery: false)
                } else {
                    self.mruEngine.recordFocus(windowID: wid)
                    self.lastFocusedWindowID = wid
                    ThumbnailManager.shared.captureSnapshot(for: wid)
                }
            }
        }

        // Fast debounced background scan (~250ms) so apps that don't emit kAXWindowMiniaturizedNotification
        // (such as Chrome/Electron) still have their minimized state detected and sunk promptly.
        appSwitchRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.mruEngine.isSessionActive else { return }
                self.refreshAll(includeRemoteAXDiscovery: false)
            }
        }
        appSwitchRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func handleAppHidden(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != selfPID else { return }
        let pid = app.processIdentifier
        let pidWindowIDs = windowsByID.values.filter { $0.pid == pid }.map(\.id)
        for wid in pidWindowIDs {
            if let existing = windowsByID[wid] {
                windowsByID[wid] = WindowDescriptor(
                    id: existing.id,
                    pid: existing.pid,
                    appName: existing.appName,
                    bundleIdentifier: existing.bundleIdentifier,
                    title: existing.title,
                    frame: existing.frame,
                    isMinimized: existing.isMinimized,
                    isHidden: true,
                    isFullscreen: existing.isFullscreen,
                    spaceID: existing.spaceID,
                    spaceKind: existing.spaceKind
                )
            }
        }
        mruEngine.recordAppHidden(windowIDs: pidWindowIDs)
    }

    private func handleAppUnhidden(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != selfPID else { return }
        refreshAll(includeRemoteAXDiscovery: false)
    }

    func attachObserversToAllRegularApps() {
        guard AXIsProcessTrusted() else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != selfPID {
            attachObserver(for: app.processIdentifier)
        }
    }

    private func attachObserver(for pid: pid_t) {
        guard AXIsProcessTrusted(),
              pid != selfPID,
              axObservers[pid] == nil,
              !observerSetupInFlight.contains(pid) else { return }

        observerSetupInFlight.insert(pid)
        let refconPtr = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())

        axWorkerQueue.async { [weak self, pid, refconPtr] in
            var observer: AXObserver?
            let status = AXObserverCreate(pid, windowTrackerAXCallback, &observer)
            guard status == .success, let observer else {
                Task { @MainActor in
                    self?.observerSetupInFlight.remove(pid)
                }
                return
            }

            let appAX = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appAX, Self.axTimeoutSeconds)

            let refcon = UnsafeMutableRawPointer(bitPattern: refconPtr)
            let notifications: [String] = [
                kAXFocusedWindowChangedNotification,
                kAXMainWindowChangedNotification,
                kAXWindowMiniaturizedNotification,
                kAXWindowDeminiaturizedNotification,
                kAXWindowCreatedNotification,
                kAXUIElementDestroyedNotification,
                kAXTitleChangedNotification
            ]

            for notif in notifications {
                AXObserverAddNotification(observer, appAX, notif as CFString, refcon)
            }

            let boxed = AXObserverBox(observer: observer)
            Task { @MainActor in
                guard let self else { return }
                self.observerSetupInFlight.remove(pid)
                guard self.axObservers[pid] == nil else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(boxed.observer), .defaultMode)
                self.axObservers[pid] = boxed.observer
            }
        }
    }

    private func detachObserver(for pid: pid_t) {
        observerSetupInFlight.remove(pid)
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func handleAXNotification(element: AXUIElement, notification: String) {
        AXUIElementSetMessagingTimeout(element, Self.axTimeoutSeconds)

        switch notification {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            guard !mruEngine.isSessionActive else { return }
            if let wid = SkyLightBridge.shared.windowID(for: element) {
                if let prevID = lastFocusedWindowID, prevID != wid {
                    ThumbnailManager.shared.captureSnapshot(for: prevID)
                }
                if windowsByID[wid] == nil {
                    refreshAll(includeRemoteAXDiscovery: false)
                } else {
                    axElementCache[wid] = element
                    mruEngine.recordFocus(windowID: wid)
                    lastFocusedWindowID = wid
                    ThumbnailManager.shared.captureSnapshot(for: wid)
                }
            }

        case kAXWindowMiniaturizedNotification:
            if let wid = SkyLightBridge.shared.windowID(for: element) {
                axElementCache[wid] = element
                if let existing = windowsByID[wid] {
                    windowsByID[wid] = WindowDescriptor(
                        id: existing.id,
                        pid: existing.pid,
                        appName: existing.appName,
                        bundleIdentifier: existing.bundleIdentifier,
                        title: existing.title,
                        frame: existing.frame,
                        isMinimized: true,
                        isHidden: existing.isHidden,
                        isFullscreen: existing.isFullscreen,
                        spaceID: existing.spaceID,
                        spaceKind: existing.spaceKind
                    )
                }
                mruEngine.recordMinimized(windowID: wid)
            }

        case kAXWindowDeminiaturizedNotification:
            if let wid = SkyLightBridge.shared.windowID(for: element) {
                axElementCache[wid] = element
                if let existing = windowsByID[wid] {
                    windowsByID[wid] = WindowDescriptor(
                        id: existing.id,
                        pid: existing.pid,
                        appName: existing.appName,
                        bundleIdentifier: existing.bundleIdentifier,
                        title: existing.title,
                        frame: existing.frame,
                        isMinimized: false,
                        isHidden: existing.isHidden,
                        isFullscreen: existing.isFullscreen,
                        spaceID: existing.spaceID,
                        spaceKind: existing.spaceKind
                    )
                }
                mruEngine.recordRestored(windowID: wid, isFocused: true)
                ThumbnailManager.shared.captureSnapshot(for: wid)
            }

        case kAXUIElementDestroyedNotification:
            if let wid = SkyLightBridge.shared.windowID(for: element) {
                mruEngine.recordClosed(windowID: wid)
                windowsByID.removeValue(forKey: wid)
                axElementCache.removeValue(forKey: wid)
            } else if !mruEngine.isSessionActive {
                refreshAll(includeRemoteAXDiscovery: false)
            }

        case kAXWindowCreatedNotification:
            if !mruEngine.isSessionActive {
                refreshAll(includeRemoteAXDiscovery: false)
            }

        case kAXTitleChangedNotification:
            if let wid = SkyLightBridge.shared.windowID(for: element),
               windowsByID[wid] != nil {
                let boxed = AXElementBox(element: element)
                axWorkerQueue.async { [weak self, wid, boxed] in
                    AXUIElementSetMessagingTimeout(boxed.element, Self.axTimeoutSeconds)
                    guard let newTitle = Self.axStringAttribute(boxed.element, kAXTitleAttribute) else { return }
                    Task { @MainActor in
                        guard let self, let existing = self.windowsByID[wid] else { return }
                        self.windowsByID[wid] = WindowDescriptor(
                            id: existing.id,
                            pid: existing.pid,
                            appName: existing.appName,
                            bundleIdentifier: existing.bundleIdentifier,
                            title: newTitle,
                            frame: existing.frame,
                            isMinimized: existing.isMinimized,
                            isHidden: existing.isHidden,
                            isFullscreen: existing.isFullscreen,
                            spaceID: existing.spaceID,
                            spaceKind: existing.spaceKind
                        )
                    }
                }
            }

        default:
            break
        }
    }

    // MARK: - Nonisolated AX Helpers (Always Called With 150ms Messaging Timeout!)

    private nonisolated static func queryFocusedWindowID(forAppAX appAX: AXUIElement) -> WindowID? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, attr as CFString, &ref) == .success, let value = ref {
                let winAX = value as! AXUIElement
                if let wid = SkyLightBridge.shared.windowID(for: winAX) {
                    return wid
                }
            }
        }
        return nil
    }

    private nonisolated static func axStringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private nonisolated static func axBoolAttribute(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else { return nil }
        return (ref as? NSNumber)?.boolValue
    }

    private nonisolated static func isAcceptableAXWindow(role: String, subrole: String) -> Bool {
        if role != kAXWindowRole {
            return false
        }
        if subrole.isEmpty {
            return true
        }
        return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
    }

    private nonisolated static func classifySpace(
        spaceID: SpaceID?,
        spaceByID: [SpaceID: ManagedSpaceInfo],
        isFullscreenAX: Bool
    ) -> SpaceKind {
        if isFullscreenAX {
            return .fullscreen(index: nil)
        }
        guard let spaceID, let info = spaceByID[spaceID] else {
            return .unknown
        }
        if info.type == 4 {
            return .fullscreen(index: nil)
        }
        let idx = info.desktopIndex ?? 1
        return info.isCurrentOnDisplay ? .currentDesktop(index: idx) : .otherDesktop(index: idx)
    }

    private nonisolated static func isFullscreenKind(_ kind: SpaceKind) -> Bool {
        if case .fullscreen = kind { return true }
        return false
    }
}

private func windowTrackerAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    let notifName = notification as String
    nonisolated(unsafe) let rawElement = element
    MainActor.assumeIsolated {
        tracker.handleAXNotification(element: rawElement, notification: notifName)
    }
}
