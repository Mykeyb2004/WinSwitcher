import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import WinSwitcherCore

struct CPSProcessSerialNumber {
    var highLongOfPSN: UInt32 = 0
    var lowLongOfPSN: UInt32 = 0
}

struct ManagedSpaceInfo: Sendable {
    let id: SpaceID
    let type: Int // 0 = regular desktop, 4 = fullscreen
    let displayUUID: String
    let isCurrentOnDisplay: Bool
    /// 1-based desktop number for regular desktops; nil for fullscreen spaces.
    let desktopIndex: Int?
}

/// Dynamic FFI bridge to macOS SkyLight & private Accessibility APIs.
/// Uses `dlopen`/`dlsym` so compilation never depends on stripped private `.tbd` stubs in Xcode SDKs.
final class SkyLightBridge: @unchecked Sendable {
    static let shared = SkyLightBridge()

    private typealias SLSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias SLSCopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SLSCopyWindowsWithOptionsAndTagsFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias SLSCopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SLSGetWindowLevelFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias SLSGetWindowBoundsFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias SLSCopyWindowPropertyFn = @convention(c) (
        Int32, UInt32, CFString, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>
    ) -> Int32
    private typealias SLSSetFrontProcessWithOptionsFn = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt32
    ) -> Int32
    private typealias SLPSPostEventRecordToFn = @convention(c) (
        UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>
    ) -> Int32
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutableRawPointer
    ) -> OSStatus
    private typealias AXUIElementGetWindowFn = @convention(c) (
        AXUIElement, UnsafeMutablePointer<CGWindowID>
    ) -> AXError
    private typealias AXUIElementCreateWithRemoteTokenFn = @convention(c) (
        CFData
    ) -> Unmanaged<AXUIElement>?

    private let slsMainConnectionID: SLSMainConnectionIDFn?
    private let slsCopyManagedDisplaySpaces: SLSCopyManagedDisplaySpacesFn?
    private let slsCopyWindowsWithOptionsAndTags: SLSCopyWindowsWithOptionsAndTagsFn?
    private let slsCopySpacesForWindows: SLSCopySpacesForWindowsFn?
    private let slsGetWindowLevel: SLSGetWindowLevelFn?
    private let slsGetWindowBounds: SLSGetWindowBoundsFn?
    private let slsCopyWindowProperty: SLSCopyWindowPropertyFn?
    private let slsSetFrontProcessWithOptions: SLSSetFrontProcessWithOptionsFn?
    private let slpsPostEventRecordTo: SLPSPostEventRecordToFn?
    private let getProcessForPID: GetProcessForPIDFn?
    private let axUIElementGetWindow: AXUIElementGetWindowFn?
    private let axUIElementCreateWithRemoteToken: AXUIElementCreateWithRemoteTokenFn?

    private init() {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let appServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)

        func load<T>(_ handle: UnsafeMutableRawPointer?, _ symbol: String) -> T? {
            guard let handle, let ptr = dlsym(handle, symbol) else { return nil }
            return unsafeBitCast(ptr, to: T.self)
        }

        self.slsMainConnectionID = load(skyLight, "SLSMainConnectionID")
        self.slsCopyManagedDisplaySpaces = load(skyLight, "SLSCopyManagedDisplaySpaces")
        self.slsCopyWindowsWithOptionsAndTags = load(skyLight, "SLSCopyWindowsWithOptionsAndTags")
        self.slsCopySpacesForWindows = load(skyLight, "SLSCopySpacesForWindows")
        self.slsGetWindowLevel = load(skyLight, "SLSGetWindowLevel")
        self.slsGetWindowBounds = load(skyLight, "SLSGetWindowBounds")
        self.slsCopyWindowProperty = load(skyLight, "SLSCopyWindowProperty")
        self.slsSetFrontProcessWithOptions = load(skyLight, "_SLPSSetFrontProcessWithOptions")
        self.slpsPostEventRecordTo = load(skyLight, "SLPSPostEventRecordTo")
        self.getProcessForPID = load(appServices, "GetProcessForPID")
        self.axUIElementGetWindow = load(appServices, "_AXUIElementGetWindow")
        self.axUIElementCreateWithRemoteToken = load(appServices, "_AXUIElementCreateWithRemoteToken")
    }

    var connectionID: Int32 {
        slsMainConnectionID?() ?? 0
    }

    // MARK: - Spaces Enumeration

    func allManagedSpaces() -> [ManagedSpaceInfo] {
        guard let fn = slsCopyManagedDisplaySpaces,
              let rawArray = fn(connectionID)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }

        var result: [ManagedSpaceInfo] = []
        var globalDesktopCounter = 0

        for displayDict in rawArray {
            let displayUUID = displayDict["Display Identifier"] as? String ?? ""
            let currentSpaceDict = displayDict["Current Space"] as? [String: Any]
            let currentSpaceID = (currentSpaceDict?["id64"] as? NSNumber)?.uint64Value
                ?? (currentSpaceDict?["ManagedSpaceID"] as? NSNumber)?.uint64Value

            guard let spaces = displayDict["Spaces"] as? [[String: Any]] else { continue }
            for spaceDict in spaces {
                let id = (spaceDict["id64"] as? NSNumber)?.uint64Value
                    ?? (spaceDict["ManagedSpaceID"] as? NSNumber)?.uint64Value
                    ?? 0
                let type = (spaceDict["type"] as? NSNumber)?.intValue ?? 0
                let isCurrent = (id != 0 && id == currentSpaceID)
                var desktopIdx: Int?
                if type == 0 {
                    globalDesktopCounter += 1
                    desktopIdx = globalDesktopCounter
                }
                result.append(ManagedSpaceInfo(
                    id: id,
                    type: type,
                    displayUUID: displayUUID,
                    isCurrentOnDisplay: isCurrent,
                    desktopIndex: desktopIdx
                ))
            }
        }
        return result
    }

    /// Returns all window IDs belonging to the given space IDs (ordered front-to-back per Space).
    func windowIDs(inSpaces spaceIDs: [SpaceID]) -> [WindowID] {
        guard !spaceIDs.isEmpty, let fn = slsCopyWindowsWithOptionsAndTags else { return [] }
        let cfSpaces = spaceIDs.map { NSNumber(value: $0) } as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        // options = 0x2 includes minimized / hidden windows on those spaces
        guard let raw = fn(connectionID, 0, cfSpaces, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return raw.map { $0.uint32Value }
    }

    /// Returns the Space IDs that a given window belongs to (selector 0x7 = all user + fullscreen spaces).
    func spaceIDs(forWindow windowID: WindowID) -> [SpaceID] {
        guard let fn = slsCopySpacesForWindows else { return [] }
        let cfWins = [NSNumber(value: windowID)] as CFArray
        guard let raw = fn(connectionID, 0x7, cfWins)?.takeRetainedValue() as? [NSNumber] else {
            return []
        }
        return raw.map { $0.uint64Value }
    }

    func windowLevel(for windowID: WindowID) -> Int32? {
        guard let fn = slsGetWindowLevel else { return nil }
        var level: Int32 = 0
        let err = fn(connectionID, windowID, &level)
        return err == 0 ? level : nil
    }

    func windowBounds(for windowID: WindowID) -> CGRect? {
        guard let fn = slsGetWindowBounds else { return nil }
        var rect = CGRect.zero
        let err = fn(connectionID, windowID, &rect)
        return err == 0 ? rect : nil
    }

    func windowTitle(for windowID: WindowID) -> String? {
        guard let fn = slsCopyWindowProperty else { return nil }
        var value: Unmanaged<CFTypeRef>?
        let err = fn(connectionID, windowID, "kCGSWindowTitle" as CFString, &value)
        guard err == 0, let retained = value?.takeRetainedValue() else { return nil }
        return retained as? String
    }

    // MARK: - Accessibility Bridge

    func windowID(for element: AXUIElement) -> WindowID? {
        guard let fn = axUIElementGetWindow else { return nil }
        var wid: CGWindowID = 0
        let err = fn(element, &wid)
        return (err == .success && wid != 0) ? wid : nil
    }

    /// Resolves off-Space `AXUIElement` objects for a PID using macOS's remote token mechanism.
    /// This allows reading attributes and performing AXRaise/AXClose on windows residing on other Spaces.
    func discoverRemoteAXWindows(
        forPID pid: pid_t,
        targetWindowIDs: Set<WindowID>,
        maxElementID: UInt64 = 600,
        timeBudgetSeconds: TimeInterval = 0.025
    ) -> [WindowID: AXUIElement] {
        guard !targetWindowIDs.isEmpty,
              let createFn = axUIElementCreateWithRemoteToken,
              let getWinFn = axUIElementGetWindow else {
            return [:]
        }

        var found: [WindowID: AXUIElement] = [:]
        var remaining = targetWindowIDs
        var tokenBytes = Data(count: 20)
        var pidLE = pid.littleEndian
        var magicLE = UInt32(0x636f636f).littleEndian // "coco"

        tokenBytes.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            memcpy(base, &pidLE, 4)
            memset(base.advanced(by: 4), 0, 4)
            memcpy(base.advanced(by: 8), &magicLE, 4)
        }

        let deadline = CFAbsoluteTimeGetCurrent() + timeBudgetSeconds
        for elementID in 0..<maxElementID {
            if remaining.isEmpty { break }
            if (elementID & 0x3f) == 0 && CFAbsoluteTimeGetCurrent() > deadline {
                break
            }

            var eidLE = elementID.littleEndian
            tokenBytes.withUnsafeMutableBytes { buf in
                guard let base = buf.baseAddress else { return }
                memcpy(base.advanced(by: 12), &eidLE, 8)
            }

            guard let element = createFn(tokenBytes as CFData)?.takeRetainedValue() else {
                continue
            }
            var wid: CGWindowID = 0
            if getWinFn(element, &wid) == .success, wid != 0, remaining.contains(wid) {
                found[wid] = element
                remaining.remove(wid)
            }
        }
        return found
    }

    // MARK: - Single-Window Focus (Windows-style raise without lifting sibling windows)

    /// Activates ONLY the specified window of `pid` (and automatically transitions macOS to its Space).
    @discardableResult
    func focusSingleWindow(pid: pid_t, windowID: WindowID) -> Bool {
        guard let getPSN = getProcessForPID,
              let setFront = slsSetFrontProcessWithOptions,
              let postEvent = slpsPostEventRecordTo else {
            return false
        }

        var psn = CPSProcessSerialNumber()
        return withUnsafeMutableBytes(of: &psn) { psnBuf -> Bool in
            guard let psnPtr = psnBuf.baseAddress else { return false }
            guard getPSN(pid, psnPtr) == noErr else { return false }

            // kCPSUserGenerated = 0x200
            let kCPSUserGenerated: UInt32 = 0x200
            let frontStatus = setFront(psnPtr, windowID, kCPSUserGenerated)

            // Post synthetic key-window focus events targeting the exact CGWindowID
            var bytes1 = [UInt8](repeating: 0, count: 0xf8)
            bytes1[0x04] = 0xf8
            bytes1[0x08] = 0x01
            bytes1[0x3a] = 0x10
            var widLE = windowID.littleEndian
            withUnsafeBytes(of: &widLE) { raw in
                for i in 0..<4 {
                    bytes1[0x3c + i] = raw[i]
                }
            }
            for i in 0x20..<0x30 {
                bytes1[i] = 0xff
            }

            var bytes2 = bytes1
            bytes2[0x08] = 0x02

            _ = postEvent(psnPtr, &bytes1)
            _ = postEvent(psnPtr, &bytes2)

            return frontStatus == 0
        }
    }
}
