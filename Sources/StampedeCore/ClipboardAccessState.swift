/// The system's clipboard-read policy, separate from whether capture is enabled or paused.
public enum ClipboardAccessState: Equatable, Sendable {
    case allowed
    case notDetermined
    case ask
    case denied
    case unknown

    public var summary: String {
        switch self {
        case .allowed: "Allowed — Stampede can read new copies."
        case .notDetermined: "Not yet requested — check access to let macOS request permission if needed."
        case .ask: "Ask Each Time — continuous history needs Always Allow."
        case .denied: "Blocked — allow Stampede to read the clipboard in System Settings."
        case .unknown: "The clipboard access status could not be determined."
        }
    }

    public var needsPermissionProbe: Bool {
        self == .notDetermined || self == .ask
    }
}
