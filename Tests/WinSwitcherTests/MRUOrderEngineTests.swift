import XCTest
@testable import WinSwitcherCore

final class MRUOrderEngineTests: XCTestCase {
    private func makeWin(
        _ id: WindowID,
        pid: pid_t = 100,
        app: String = "App",
        minimized: Bool = false,
        hidden: Bool = false,
        space: SpaceKind = .currentDesktop(index: 1)
    ) -> WindowDescriptor {
        WindowDescriptor(
            id: id,
            pid: pid,
            appName: app,
            title: "Win \(id)",
            isMinimized: minimized,
            isHidden: hidden,
            spaceKind: space
        )
    }

    func testPingPongSwitchingBetweenTwoRecentWindows() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3), makeWin(4)],
            focusedWindowID: 1
        )
        XCTAssertEqual(engine.orderedIDs, [1, 2, 3, 4])

        // First Alt+Tab highlights index 1 (window 2)
        XCTAssertTrue(engine.beginSession(activeFocusedWindowID: 1))
        XCTAssertEqual(engine.selectedIndex, 1)
        XCTAssertEqual(engine.currentSelectedWindowID, 2)
        XCTAssertEqual(engine.commitSession(), 2)
        XCTAssertEqual(engine.orderedIDs, [2, 1, 3, 4])

        // Immediate second Alt+Tab highlights index 1 (window 1) -> instant A <-> B ping-pong
        XCTAssertTrue(engine.beginSession(activeFocusedWindowID: 2))
        XCTAssertEqual(engine.selectedIndex, 1)
        XCTAssertEqual(engine.currentSelectedWindowID, 1)
        XCTAssertEqual(engine.commitSession(), 1)
        XCTAssertEqual(engine.orderedIDs, [1, 2, 3, 4])
    }

    func testOrderRemainsFrozenDuringHoldAndCommitsOnRelease() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(10), makeWin(20), makeWin(30), makeWin(40)],
            focusedWindowID: 10
        )

        XCTAssertTrue(engine.beginSession(activeFocusedWindowID: 10))
        XCTAssertEqual(engine.sessionSnapshot, [10, 20, 30, 40])
        XCTAssertEqual(engine.selectedIndex, 1) // 20

        engine.stepForward() // 30
        XCTAssertEqual(engine.currentSelectedWindowID, 30)
        engine.stepForward() // 40
        XCTAssertEqual(engine.currentSelectedWindowID, 40)
        engine.stepForward() // wraps to 10
        XCTAssertEqual(engine.currentSelectedWindowID, 10)
        engine.stepBackward() // wraps back to 40
        XCTAssertEqual(engine.currentSelectedWindowID, 40)
        engine.stepBackward() // 30
        XCTAssertEqual(engine.currentSelectedWindowID, 30)

        // Stray focus notification during active session must not mutate snapshot or orderedIDs
        engine.recordFocus(windowID: 40)
        XCTAssertEqual(engine.sessionSnapshot, [10, 20, 30, 40])
        XCTAssertEqual(engine.orderedIDs, [10, 20, 30, 40])

        // Commit promotes 30 to front, keeping 10, 20, 40 relative order intact
        XCTAssertEqual(engine.commitSession(), 30)
        XCTAssertEqual(engine.orderedIDs, [30, 10, 20, 40])
    }

    func testEscapeCancelDoesNotModifyMRUOrder() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3)],
            focusedWindowID: 1
        )

        engine.beginSession(activeFocusedWindowID: 1)
        engine.stepForward() // selects 3
        XCTAssertEqual(engine.currentSelectedWindowID, 3)

        engine.cancelSession()
        XCTAssertFalse(engine.isSessionActive)
        XCTAssertEqual(engine.orderedIDs, [1, 2, 3])
    }

    func testMinimizedWindowSinksToEndLikeWindows() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3), makeWin(4)],
            focusedWindowID: 1
        )

        // User minimizes active window 1 -> sinks to end, window 2 becomes active
        engine.recordMinimized(windowID: 1)
        engine.recordFocus(windowID: 2)
        XCTAssertEqual(engine.orderedIDs, [2, 3, 4, 1])
        XCTAssertTrue(engine.minimizedOrHiddenIDs.contains(1))

        // Pressing Alt+Tab while on window 2 selects window 3 (NOT the just-minimized window 1!)
        engine.beginSession(activeFocusedWindowID: 2)
        XCTAssertEqual(engine.currentSelectedWindowID, 3)

        // Navigating to minimized window 1 and committing restores it to index 0
        engine.stepForward() // 4
        engine.stepForward() // 1
        XCTAssertEqual(engine.currentSelectedWindowID, 1)
        XCTAssertEqual(engine.commitSession(), 1)
        XCTAssertEqual(engine.orderedIDs, [1, 2, 3, 4])
        XCTAssertFalse(engine.minimizedOrHiddenIDs.contains(1))
    }

    func testHiddenAppWindowsSinkPreservingRelativeOrder() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [
                makeWin(1, pid: 10, app: "Chrome"),
                makeWin(2, pid: 20, app: "VSCode"),
                makeWin(3, pid: 10, app: "Chrome"),
                makeWin(4, pid: 30, app: "Finder")
            ],
            focusedWindowID: 1
        )

        // Cmd+H on Chrome hides windows 1 and 3 -> both sink to tail preserving [1, 3] order
        engine.recordAppHidden(windowIDs: [1, 3])
        XCTAssertEqual(engine.orderedIDs, [2, 4, 1, 3])
    }

    func testDesktopFocusedSelectsIndexZero() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3)],
            focusedWindowID: 1
        )

        // Desktop or windowless app focused -> activeFocusedWindowID is nil -> selects index 0 (window 1)
        XCTAssertTrue(engine.beginSession(activeFocusedWindowID: nil))
        XCTAssertEqual(engine.selectedIndex, 0)
        XCTAssertEqual(engine.currentSelectedWindowID, 1)
    }

    func testShiftAltTabStartsAtLastWindow() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3), makeWin(4)],
            focusedWindowID: 1
        )

        XCTAssertTrue(engine.beginSession(activeFocusedWindowID: 1, backwards: true))
        XCTAssertEqual(engine.selectedIndex, 3)
        XCTAssertEqual(engine.currentSelectedWindowID, 4)
    }

    func testCrossSpaceUnifiedOrderAndMinimizedInitialSeed() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [
                makeWin(1, space: .currentDesktop(index: 1)),
                makeWin(2, minimized: true, space: .currentDesktop(index: 1)),
                makeWin(3, space: .otherDesktop(index: 2)),
                makeWin(4, space: .fullscreen(index: nil))
            ],
            focusedWindowID: 1
        )
        // Minimized window 2 seeded at the tail, while off-Space windows 3 and 4 stay in MRU order
        XCTAssertEqual(engine.orderedIDs, [1, 3, 4, 2])
    }

    func testCloseWindowInsideActiveSessionClampsSelectionCleanly() {
        var engine = MRUOrderEngine(sinkMinimizedToEnd: true)
        engine.sync(
            discoveredWindows: [makeWin(1), makeWin(2), makeWin(3)],
            focusedWindowID: 1
        )

        engine.beginSession(activeFocusedWindowID: 1)
        engine.stepForward() // index 2 (window 3)
        XCTAssertEqual(engine.currentSelectedWindowID, 3)

        engine.recordClosed(windowID: 3)
        XCTAssertTrue(engine.isSessionActive)
        XCTAssertEqual(engine.sessionSnapshot, [1, 2])
        XCTAssertEqual(engine.selectedIndex, 1)
        XCTAssertEqual(engine.currentSelectedWindowID, 2)
    }

    func testGrid2DArrowNavigationWrapping() {
        // 7 items in 3 columns:
        // [0] [1] [2]
        // [3] [4] [5]
        // [6]
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 0, count: 7, columns: 3, direction: .down), 3)
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 3, count: 7, columns: 3, direction: .down), 6)
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 6, count: 7, columns: 3, direction: .down), 0)
        // Row 1 col 2 (index 5) pressing down jumps to last item (6) since row 2 has fewer columns
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 5, count: 7, columns: 3, direction: .down), 6)
        // Row 0 col 1 (index 1) pressing up wraps to bottom-most item in col 1 (index 4)
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 1, count: 7, columns: 3, direction: .up), 4)
        // Row 0 col 0 (index 0) pressing up wraps to index 6
        XCTAssertEqual(GridLayoutCalculator.nextIndex(current: 0, count: 7, columns: 3, direction: .up), 6)
    }
}
