import Foundation

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public var image: ClipboardImage?
    public let capturedAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), text: String, capturedAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.image = nil
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
    }

    public init(id: UUID = UUID(), image: ClipboardImage, capturedAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id; self.text = ""; self.image = image
        self.capturedAt = capturedAt; self.lastUsedAt = lastUsedAt
    }
    public var byteCount: Int { image?.byteCount ?? text.utf8.count }
    public var valid: Bool { image.map { text.isEmpty && $0.isValid } ?? (!text.isEmpty && byteCount <= History.maximumEntryBytes) }
    public func sameContent(as other: ClipboardEntry) -> Bool {
        if let a = image, let b = other.image { return a.type == b.type && a.digest == b.digest && (a.data == nil || b.data == nil || a.data == b.data) }
        return image == nil && other.image == nil && text.utf8.elementsEqual(other.text.utf8)
    }
    public var preview: String {
        if let image { return image.label }

        let prefix = text.prefix(71)
        // Joiners are format characters, but emoji sequences and Persian or Indic words need them.
        let controls = CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))
        let value = String(prefix).map { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains(where: { controls.contains($0) }) ? " " : String($0) }.joined()
        return String(value.prefix(70)) + (prefix.count > 70 ? "…" : "")
    }
}

public struct History: Sendable {
    public static let maximumEntryBytes = 1_048_576
    public static let maximumTotalBytes = 100 * maximumEntryBytes
    public private(set) var entries: [ClipboardEntry]
    public private(set) var capacity: Int

    public init(entries: [ClipboardEntry] = [], capacity: Int = 20) {
        self.capacity = capacity == 10 ? 10 : 20
        self.entries = []
        var bytes = 0
        for entry in entries where self.entries.count < self.capacity {
            let size = entry.byteCount
            guard entry.valid,
                  bytes + size <= Self.maximumTotalBytes,
                  !self.entries.contains(where: { $0.id == entry.id || $0.sameContent(as: entry) }) else { continue }
            self.entries.append(entry)
            bytes += size
        }
    }

    @discardableResult public mutating func capture(_ text: String, now: Date = Date()) -> UUID? {
        capture(ClipboardEntry(text: text, capturedAt: now, lastUsedAt: now))
    }

    /// Observed timestamps preserve order when an older image finishes after newer text.
    @discardableResult public mutating func capture(_ candidate: ClipboardEntry) -> UUID? {
        guard candidate.valid else { return nil }
        var entry = candidate
        if let index = entries.firstIndex(where: { $0.sameContent(as: candidate) }) {
            if entries[index].lastUsedAt > candidate.lastUsedAt { return entries[index].id }
            let old = entries.remove(at: index)
            entry = candidate.image.map { ClipboardEntry(id: old.id, image: $0, capturedAt: old.capturedAt, lastUsedAt: candidate.lastUsedAt) }
                ?? ClipboardEntry(id: old.id, text: candidate.text, capturedAt: old.capturedAt, lastUsedAt: candidate.lastUsedAt)
        }
        let index = entries.firstIndex(where: { $0.lastUsedAt <= entry.lastUsedAt }) ?? entries.endIndex
        entries.insert(entry, at: index)
        trim()
        return entries.contains(where: { $0.id == entry.id }) ? entry.id : nil
    }

    private mutating func trim() {
        entries = Array(entries.prefix(capacity))
        var bytes = entries.reduce(0) { $0 + $1.byteCount }
        while bytes > Self.maximumTotalBytes, let last = entries.popLast() { bytes -= last.byteCount }
    }

    public mutating func setCapacity(_ value: Int) {
        capacity = value == 10 ? 10 : 20
        trim()
    }

    public mutating func clear() { entries.removeAll() }
}
