import AppKit
import SwiftUI
import WinSwitcherCore

/// Non-activating floating panel that renders the Windows 11 Alt+Tab overlay
/// across all Spaces and Fullscreen Spaces without stealing focus from any app.
@MainActor
final class SwitcherHUDPanel: NSPanel {
    private let hostingView: NSHostingView<SwitcherHUDView>

    init(
        viewModel: SwitcherViewModel,
        onSelectIndex: @escaping (Int) -> Void,
        onCloseWindow: @escaping (WindowID) -> Void
    ) {
        let rootView = SwitcherHUDView(
            viewModel: viewModel,
            thumbnails: ThumbnailManager.shared,
            settings: AppSettings.shared,
            onSelectIndex: onSelectIndex,
            onCloseWindow: onCloseWindow
        )
        self.hostingView = NSHostingView(rootView: rootView)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.animationBehavior = .none

        self.hostingView.wantsLayer = true
        self.hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = hostingView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showHUD(metrics: SwitcherGridMetrics, targetScreen: NSScreen?) {
        updateFrame(for: metrics, targetScreen: targetScreen)
        orderFrontRegardless()
    }

    func updateFrame(for metrics: SwitcherGridMetrics, targetScreen: NSScreen?) {
        let screen = targetScreen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = metrics.panelWidth
        let height = metrics.panelHeight
        let originX = visible.midX - width / 2.0
        let originY = visible.midY - height / 2.0

        setFrame(NSRect(x: originX.rounded(), y: originY.rounded(), width: width, height: height), display: true)
    }

    func hideHUD() {
        orderOut(nil)
    }
}
