import CoreGraphics
import Foundation

public typealias WindowID = UInt32
public typealias SpaceID = UInt64

public enum SpaceKind: Equatable, Hashable, Sendable {
    case currentDesktop(index: Int)
    case otherDesktop(index: Int)
    case fullscreen(index: Int?)
    case unknown

    public var isOffCurrentSpace: Bool {
        switch self {
        case .currentDesktop, .unknown:
            return false
        case .otherDesktop, .fullscreen:
            return true
        }
    }

    public var shortBadge: String? {
        switch self {
        case .currentDesktop, .unknown:
            return nil
        case .otherDesktop(let idx):
            return "D\(idx)"
        case .fullscreen:
            return "全屏"
        }
    }

    public var descriptiveLabel: String? {
        switch self {
        case .currentDesktop(let idx):
            return "桌面 \(idx)"
        case .otherDesktop(let idx):
            return "桌面 \(idx)"
        case .fullscreen:
            return "全屏空间"
        case .unknown:
            return nil
        }
    }
}

public struct WindowDescriptor: Equatable, Identifiable, Sendable {
    public let id: WindowID
    public let pid: pid_t
    public let appName: String
    public let bundleIdentifier: String?
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isHidden: Bool
    public let isFullscreen: Bool
    public let spaceID: SpaceID?
    public let spaceKind: SpaceKind

    public init(
        id: WindowID,
        pid: pid_t,
        appName: String,
        bundleIdentifier: String? = nil,
        title: String,
        frame: CGRect = .zero,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        isFullscreen: Bool = false,
        spaceID: SpaceID? = nil,
        spaceKind: SpaceKind = .unknown
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isFullscreen = isFullscreen
        self.spaceID = spaceID
        self.spaceKind = spaceKind
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appName : trimmed
    }

    public var isMinimizedOrHidden: Bool {
        isMinimized || isHidden
    }
}
