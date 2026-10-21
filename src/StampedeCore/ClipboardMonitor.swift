import Foundation

public enum ClipboardRead: Equatable, Sendable {
    case text(String)
    case image(ImageCandidate)
    case rejectedImage(String)
    case excluded
    case unavailable
}

@MainActor public protocol ClipboardClient: AnyObject {
    var revision: Int { get }

    var canReadInBackground: Bool { get }

    func read() -> ClipboardRead

    func write(_ text: String) -> Bool

    func writeImage(_ image: ClipboardImage) -> Bool

    func clear() -> Int
}

extension ClipboardClient {
    public func writeImage(_ image: ClipboardImage) -> Bool { false }
}

@MainActor public final class ClipboardMonitor {
    private let clipboard: any ClipboardClient
    public private(set) var processedRevision: Int?
    private var pendingRevision: Int?
    private var attempts = 0
    private var nextAttempt = Date.distantPast
    /// A writer's clearContents, setString, and concealed-marker calls share one revision, so timer polls wait this
    /// long after first seeing it. Shorter than the app's 0.5 s timer minus its 0.15 s tolerance, so the next tick
    /// reads it.
    static let settleDelay: TimeInterval = 0.25
    public var onImage: ((ImageCandidate, Int) -> Void)?
    public var onImageRejected: ((String) -> Void)?
    public var onCapture: ((String) -> Void)?
    public var onInactive: (() -> Void)?
    public var onAccessRequired: (() -> Void)?

    public init(clipboard: any ClipboardClient) { self.clipboard = clipboard }

    public func baseline() {
        processedRevision = clipboard.revision
        pendingRevision = nil
        attempts = 0
        onInactive?()
    }

    /// `foreground` polls (menu open, entry selection) skip only the settle delay; `userInitiated` also skips the
    /// background-access check.
    public func poll(userInitiated: Bool = false, foreground: Bool = false, now: Date = Date()) {
        guard userInitiated || clipboard.canReadInBackground else {
            onAccessRequired?()
            onInactive?()
            return
        }
        let before = clipboard.revision
        guard before != processedRevision else { return }
        if before != pendingRevision {
            pendingRevision = before
            attempts = 0
            nextAttempt = now.addingTimeInterval(Self.settleDelay)
        }
        guard now >= nextAttempt || ((userInitiated || foreground) && attempts == 0) else { return }
        let result = clipboard.read()
        guard clipboard.revision == before else { return }
        switch result {
        case .text(let text):
            processedRevision = before
            pendingRevision = nil
            if text.isEmpty || text.utf8.count > History.maximumEntryBytes { onInactive?() } else { onCapture?(text) }
        case .image(let candidate):
            processedRevision = before
            pendingRevision = nil
            onInactive?()
            onImage?(candidate, before)
        case .rejectedImage(let message):
            processedRevision = before
            pendingRevision = nil
            onInactive?()
            onImageRejected?(message)
        case .excluded:
            processedRevision = before
            pendingRevision = nil
            onInactive?()
        case .unavailable:
            onInactive?()
            attempts += 1
            nextAttempt = now.addingTimeInterval(pow(2, Double(attempts - 1)))
            if attempts >= 4 {
                processedRevision = before
                pendingRevision = nil
            }
        }
    }

    /// Explicit user action: bypass revision/retry gating so an unchanged clipboard can request access.
    /// Discard the payload; checking permission must not capture, promote, or modify the clipboard.
    public func probeAccess() {
        _ = clipboard.read()
    }

    public func clearClipboard() {
        processedRevision = clipboard.clear()
        pendingRevision = nil
        onInactive?()
    }

    public func activateImage(_ image: ClipboardImage) -> Bool {
        guard clipboard.writeImage(image) else {
            onInactive?()
            return false
        }
        processedRevision = clipboard.revision
        pendingRevision = nil
        return true
    }

    /// Returns false without changing history. A failed system write may have cleared the clipboard.
    public func activate(_ text: String) -> Bool {
        guard clipboard.write(text) else {
            onInactive?()
            return false
        }
        processedRevision = clipboard.revision
        pendingRevision = nil
        return true
    }
}
