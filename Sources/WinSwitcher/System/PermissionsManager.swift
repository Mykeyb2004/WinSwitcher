import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    @Published private(set) var hasAccessibility: Bool = false
    @Published private(set) var hasScreenRecording: Bool = false

    private var timer: Timer?

    private init() {
        refresh()
        startPolling()
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        if ax != hasAccessibility {
            hasAccessibility = ax
        }
        if sr != hasScreenRecording {
            hasScreenRecording = sr
        }
    }

    func requestAccessibilityPrompt() {
        // Use the literal key string to avoid Swift 6 concurrency warning on global CFString var.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
        refresh()
    }

    func requestScreenRecordingPrompt() {
        _ = CGRequestScreenCaptureAccess()
        openScreenRecordingSettings()
        refresh()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
