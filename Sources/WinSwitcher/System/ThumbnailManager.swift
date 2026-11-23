import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import WinSwitcherCore

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Captures crisp, aspect-preserving window thumbnails via ScreenCaptureKit and caches
/// the last known frame for minimized, hidden, or off-Space windows (like Windows DWM cache).
@MainActor
final class ThumbnailManager: ObservableObject {
    static let shared = ThumbnailManager()

    @Published private(set) var thumbnails: [WindowID: NSImage] = [:]
    private var lastCaptureTime: [WindowID: CFAbsoluteTime] = [:]
    private var inFlight: Set<WindowID> = []
    private var batchTask: Task<Void, Never>?

    private init() {}

    func thumbnail(for windowID: WindowID) -> NSImage? {
        thumbnails[windowID]
    }

    func prune(keeping liveIDs: Set<WindowID>) {
        thumbnails = thumbnails.filter { liveIDs.contains($0.key) }
        lastCaptureTime = lastCaptureTime.filter { liveIDs.contains($0.key) }
    }

    /// Captures/refreshes thumbnails for the given window IDs asynchronously.
    /// Existing cached frames remain displayed immediately while fresher snapshots stream in.
    func refreshThumbnails(for windowIDs: [WindowID], force: Bool = false) {
        guard CGPreflightScreenCaptureAccess(), !windowIDs.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let minInterval: CFAbsoluteTime = force ? 0.35 : 2.0
        let needed = windowIDs.filter { wid in
            if inFlight.contains(wid) { return false }
            if let last = lastCaptureTime[wid], now - last < minInterval, thumbnails[wid] != nil {
                return false
            }
            return true
        }
        guard !needed.isEmpty else { return }

        for wid in needed {
            inFlight.insert(wid)
        }

        batchTask = Task.detached(priority: .userInitiated) { [needed] in
            defer {
                Task { @MainActor in
                    for wid in needed {
                        self.inFlight.remove(wid)
                    }
                }
            }

            do {
                let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let scByID = Dictionary(uniqueKeysWithValues: shareable.windows.map { ($0.windowID, $0) })

                await withTaskGroup(of: (WindowID, CGImage?).self) { group in
                    for wid in needed {
                        guard let scWindow = scByID[wid] else { continue }
                        guard scWindow.frame.width >= 20, scWindow.frame.height >= 20 else { continue }
                        let boxedWindow = UncheckedSendableBox(value: scWindow)

                        group.addTask {
                            let img = await Self.captureSingle(scWindow: boxedWindow.value)
                            return (wid, img)
                        }
                    }

                    for await (wid, cgImage) in group {
                        if let cgImage {
                            await MainActor.run {
                                let nsImage = NSImage(
                                    cgImage: cgImage,
                                    size: NSSize(width: CGFloat(cgImage.width) / 2.0, height: CGFloat(cgImage.height) / 2.0)
                                )
                                self.thumbnails[wid] = nsImage
                                self.lastCaptureTime[wid] = CFAbsoluteTimeGetCurrent()
                            }
                        }
                    }
                }
            } catch {
                // ScreenCaptureKit may fail briefly during Space transitions or when permission is revoked.
            }
        }
    }

    /// Captures a single window right away (e.g., before it loses focus or gets minimized so its DWM-like cache is fresh).
    func captureSnapshot(for windowID: WindowID) {
        refreshThumbnails(for: [windowID], force: true)
    }

    nonisolated private static func captureSingle(scWindow: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()

        let aspect = max(0.25, min(4.0, scWindow.frame.width / max(1, scWindow.frame.height)))
        let maxW: CGFloat = 480
        let maxH: CGFloat = 320

        let targetW: CGFloat
        let targetH: CGFloat
        if aspect >= (maxW / maxH) {
            targetW = maxW
            targetH = maxW / aspect
        } else {
            targetH = maxH
            targetW = maxH * aspect
        }

        config.width = max(32, Int(targetW.rounded()))
        config.height = max(32, Int(targetH.rounded()))
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            return nil
        }
    }
}
