import Foundation

public enum GridDirection: Sendable {
    case left
    case right
    case up
    case down
}

/// Pure, deterministic Windows 10/11 Alt+Tab MRU ordering & switching session state machine.
///
/// Key invariants (1:1 Windows fidelity):
/// 1. `orderedIDs` is strictly ordered by window-level Most Recently Used (index 0 = active window).
/// 2. Minimizing or hiding a window sends it to the tail of `orderedIDs` (when `sinkMinimizedToEnd` is enabled),
///    so an immediate `Alt+Tab` never bounces back to the window just minimized.
/// 3. Starting an Alt+Tab session freezes `orderedIDs` into `sessionSnapshot` for the entire hold duration.
/// 4. Initial selection is index `1` (previous window) if the currently focused window is index `0` and count >= 2;
///    otherwise index `0` (e.g., when Desktop or a windowless app is focused).
/// 5. Releasing the modifier commits the switch and immediately promotes the target window to index `0`.
/// 6. Pressing Escape cancels without changing `orderedIDs`.
public struct MRUOrderEngine: Sendable {
    public private(set) var orderedIDs: [WindowID] = []
    public private(set) var minimizedOrHiddenIDs: Set<WindowID> = []

    public private(set) var isSessionActive: Bool = false
    public private(set) var sessionSnapshot: [WindowID] = []
    public private(set) var selectedIndex: Int = 0

    public var sinkMinimizedToEnd: Bool

    public init(sinkMinimizedToEnd: Bool = true) {
        self.sinkMinimizedToEnd = sinkMinimizedToEnd
    }

    /// Reconciles the engine with a freshly enumerated snapshot of live windows.
    /// `discoveredWindows` should be ordered roughly front-to-back (visual Z-order) as a fallback for brand-new windows.
    public mutating func sync(
        discoveredWindows: [WindowDescriptor],
        focusedWindowID: WindowID?
    ) {
        let liveSet = Set(discoveredWindows.map(\.id))
        let byID = Dictionary(uniqueKeysWithValues: discoveredWindows.map { ($0.id, $0) })

        // 1. Prune closed windows from MRU order and minimized set.
        orderedIDs.removeAll { !liveSet.contains($0) }
        minimizedOrHiddenIDs = minimizedOrHiddenIDs.intersection(liveSet)

        // 2. Initial seed if MRU is empty.
        if orderedIDs.isEmpty {
            var visible: [WindowID] = []
            var sunken: [WindowID] = []
            for win in discoveredWindows {
                if win.isMinimizedOrHidden {
                    minimizedOrHiddenIDs.insert(win.id)
                    sunken.append(win.id)
                } else {
                    visible.append(win.id)
                }
            }
            orderedIDs = sinkMinimizedToEnd ? (visible + sunken) : discoveredWindows.map(\.id)
            if let focused = focusedWindowID, liveSet.contains(focused) {
                moveToFront(focused)
                minimizedOrHiddenIDs.remove(focused)
            }
            return
        }

        // 3. Detect newly minimized/hidden or unminimized transitions among existing windows.
        var newlySunken: [WindowID] = []
        for id in orderedIDs {
            guard let info = byID[id] else { continue }
            let wasMinimizedOrHidden = minimizedOrHiddenIDs.contains(id)
            if info.isMinimizedOrHidden && !wasMinimizedOrHidden {
                minimizedOrHiddenIDs.insert(id)
                newlySunken.append(id)
            } else if !info.isMinimizedOrHidden && wasMinimizedOrHidden {
                minimizedOrHiddenIDs.remove(id)
            }
        }
        if sinkMinimizedToEnd && !newlySunken.isEmpty {
            moveGroupToBack(newlySunken)
        }

        // 4. Insert newly created/discovered windows without scrambling existing MRU order.
        let existingSet = Set(orderedIDs)
        let newWindows = discoveredWindows.filter { !existingSet.contains($0.id) }
        for win in newWindows {
            if win.isMinimizedOrHidden {
                minimizedOrHiddenIDs.insert(win.id)
                orderedIDs.append(win.id)
            } else if win.id == focusedWindowID {
                orderedIDs.insert(win.id, at: 0)
            } else {
                // Background window opened without stealing focus: insert right before minimized tail
                // (and after index 0 if there is an active window).
                let insertPos = insertionIndexForBackgroundVisibleWindow()
                orderedIDs.insert(win.id, at: insertPos)
            }
        }

        // 5. Ensure the genuinely focused window is at index 0 (unless a switcher session is currently frozen).
        if !isSessionActive, let focused = focusedWindowID, liveSet.contains(focused) {
            if let info = byID[focused], !info.isMinimizedOrHidden {
                minimizedOrHiddenIDs.remove(focused)
                if orderedIDs.first != focused {
                    moveToFront(focused)
                }
            }
        }

        // 6. If a session is active, prune any closed windows from the frozen snapshot cleanly.
        if isSessionActive {
            pruneSessionSnapshot(liveSet: liveSet)
        }
    }

    /// Record that a specific window just gained focus.
    public mutating func recordFocus(windowID: WindowID) {
        minimizedOrHiddenIDs.remove(windowID)
        // Do not mutate the frozen snapshot while session is open,
        // and ignore focus bounce if the switcher itself is active.
        guard !isSessionActive else { return }
        moveToFront(windowID)
    }

    /// Record that a window was explicitly minimized by the user.
    public mutating func recordMinimized(windowID: WindowID) {
        guard orderedIDs.contains(windowID) else { return }
        minimizedOrHiddenIDs.insert(windowID)
        if sinkMinimizedToEnd {
            moveToBack(windowID)
        }
    }

    /// Record that an application (with one or more windows) was hidden via Cmd+H.
    public mutating func recordAppHidden(windowIDs: [WindowID]) {
        let existing = orderedIDs.filter { windowIDs.contains($0) }
        guard !existing.isEmpty else { return }
        for id in existing {
            minimizedOrHiddenIDs.insert(id)
        }
        if sinkMinimizedToEnd {
            moveGroupToBack(existing)
        }
    }

    /// Record that a window was restored (unminimized / unhidden).
    public mutating func recordRestored(windowID: WindowID, isFocused: Bool) {
        minimizedOrHiddenIDs.remove(windowID)
        if isFocused && !isSessionActive {
            moveToFront(windowID)
        }
    }

    /// Record that a window was closed/destroyed.
    public mutating func recordClosed(windowID: WindowID) {
        orderedIDs.removeAll { $0 == windowID }
        minimizedOrHiddenIDs.remove(windowID)
        if isSessionActive {
            removeFromSessionSnapshot(windowID: windowID)
        }
    }

    // MARK: - Switcher Session Lifecycle

    /// Begins a frozen Alt+Tab session.
    /// - Parameters:
    ///   - activeFocusedWindowID: The currently focused window ID (or `nil` if Desktop / windowless app is focused).
    ///   - backwards: `true` if started with `Shift + Alt + Tab`.
    /// - Returns: `true` if there is at least 1 window to switch among.
    @discardableResult
    public mutating func beginSession(
        activeFocusedWindowID: WindowID?,
        backwards: Bool = false,
        allowedWindowIDs: Set<WindowID>? = nil
    ) -> Bool {
        // Ensure the currently focused window is at index 0 right before snapshotting
        if let activeID = activeFocusedWindowID,
           orderedIDs.contains(activeID),
           !minimizedOrHiddenIDs.contains(activeID),
           orderedIDs.first != activeID {
            moveToFront(activeID)
        }

        let candidates: [WindowID]
        if let allowedWindowIDs {
            candidates = orderedIDs.filter { allowedWindowIDs.contains($0) }
        } else {
            candidates = orderedIDs
        }

        guard !candidates.isEmpty else {
            isSessionActive = false
            sessionSnapshot = []
            selectedIndex = 0
            return false
        }

        isSessionActive = true
        sessionSnapshot = candidates

        if sessionSnapshot.count == 1 {
            selectedIndex = 0
        } else {
            let activeIsAtFront = (activeFocusedWindowID != nil && activeFocusedWindowID == sessionSnapshot.first)
            if backwards {
                // Shift+Alt+Tab wraps to the last item
                selectedIndex = sessionSnapshot.count - 1
            } else if activeIsAtFront {
                // Classic Windows: immediately highlight index 1 (previous window)
                selectedIndex = 1
            } else {
                // Desktop or windowless app focused: highlight index 0 (most recent window)
                selectedIndex = 0
            }
        }
        return true
    }

    public mutating func stepForward() {
        guard isSessionActive, !sessionSnapshot.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % sessionSnapshot.count
    }

    public mutating func stepBackward() {
        guard isSessionActive, !sessionSnapshot.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + sessionSnapshot.count) % sessionSnapshot.count
    }

    public mutating func selectIndex(_ index: Int) {
        guard isSessionActive, sessionSnapshot.indices.contains(index) else { return }
        selectedIndex = index
    }

    public mutating func moveSelection(direction: GridDirection, columns: Int) {
        guard isSessionActive, !sessionSnapshot.isEmpty else { return }
        let count = sessionSnapshot.count
        let cols = max(1, columns)
        selectedIndex = GridLayoutCalculator.nextIndex(
            current: selectedIndex,
            count: count,
            columns: cols,
            direction: direction
        )
    }

    public var currentSelectedWindowID: WindowID? {
        guard isSessionActive, sessionSnapshot.indices.contains(selectedIndex) else { return nil }
        return sessionSnapshot[selectedIndex]
    }

    /// Commits the current session, promotes the chosen window optimistically to MRU index 0, and returns it.
    public mutating func commitSession() -> WindowID? {
        guard isSessionActive else { return nil }
        let target = currentSelectedWindowID
        isSessionActive = false
        sessionSnapshot = []
        selectedIndex = 0

        if let target {
            minimizedOrHiddenIDs.remove(target)
            moveToFront(target)
        }
        return target
    }

    /// Cancels the session (Escape / click outside) without changing MRU order.
    public mutating func cancelSession() {
        isSessionActive = false
        sessionSnapshot = []
        selectedIndex = 0
    }

    // MARK: - Private Helpers

    private mutating func moveToFront(_ id: WindowID) {
        if let idx = orderedIDs.firstIndex(of: id) {
            if idx == 0 { return }
            orderedIDs.remove(at: idx)
            orderedIDs.insert(id, at: 0)
        } else {
            orderedIDs.insert(id, at: 0)
        }
    }

    private mutating func moveToBack(_ id: WindowID) {
        guard let idx = orderedIDs.firstIndex(of: id) else { return }
        orderedIDs.remove(at: idx)
        orderedIDs.append(id)
    }

    private mutating func moveGroupToBack(_ ids: [WindowID]) {
        let idSet = Set(ids)
        let moving = orderedIDs.filter { idSet.contains($0) }
        orderedIDs.removeAll { idSet.contains($0) }
        orderedIDs.append(contentsOf: moving)
    }

    private func insertionIndexForBackgroundVisibleWindow() -> Int {
        guard !orderedIDs.isEmpty else { return 0 }
        if sinkMinimizedToEnd {
            // Place before the minimized tail, but not ahead of the currently active index 0.
            let firstMinimizedIdx = orderedIDs.firstIndex { minimizedOrHiddenIDs.contains($0) } ?? orderedIDs.count
            return min(max(1, firstMinimizedIdx), orderedIDs.count)
        }
        return min(1, orderedIDs.count)
    }

    private mutating func pruneSessionSnapshot(liveSet: Set<WindowID>) {
        guard isSessionActive else { return }
        let previouslySelected = currentSelectedWindowID
        sessionSnapshot.removeAll { !liveSet.contains($0) }
        if sessionSnapshot.isEmpty {
            cancelSession()
            return
        }
        if let prev = previouslySelected, let newIdx = sessionSnapshot.firstIndex(of: prev) {
            selectedIndex = newIdx
        } else {
            selectedIndex = min(selectedIndex, sessionSnapshot.count - 1)
        }
    }

    private mutating func removeFromSessionSnapshot(windowID: WindowID) {
        guard let removedIdx = sessionSnapshot.firstIndex(of: windowID) else { return }
        sessionSnapshot.remove(at: removedIdx)
        if sessionSnapshot.isEmpty {
            cancelSession()
            return
        }
        if removedIdx < selectedIndex {
            selectedIndex -= 1
        } else if selectedIndex >= sessionSnapshot.count {
            selectedIndex = sessionSnapshot.count - 1
        }
    }
}
