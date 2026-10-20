import Foundation

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let capturedAt: Date
    public var lastUsedAt: Date

    public init(id: UUID = UUID(), text: String, capturedAt: Date = Date(), lastUsedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
    }

    public var preview: String {
        let prefix = text.prefix(71)
        let value = String(prefix).map { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? " " : String($0) }.joined()
        return String(value.prefix(70)) + (prefix.count > 70 ? "…" : "")
    }
}

public struct History: Sendable {
    public static let maximumEntryBytes = 1_048_576
    public static let maximumTotalBytes = 20 * maximumEntryBytes
    public private(set) var entries: [ClipboardEntry]
    public private(set) var capacity: Int

    public init(entries: [ClipboardEntry] = [], capacity: Int = 20) {
        self.capacity = capacity == 10 ? 10 : 20
        self.entries = []
        var bytes = 0
        for entry in entries where self.entries.count < self.capacity {
            let size = entry.text.utf8.count
            guard size > 0, size <= Self.maximumEntryBytes,
                  bytes + size <= Self.maximumTotalBytes,
                  !self.entries.contains(where: { $0.id == entry.id || $0.text.utf8.elementsEqual(entry.text.utf8) }) else { continue }
            self.entries.append(entry)
            bytes += size
        }
    }

    @discardableResult public mutating func capture(_ text: String, now: Date = Date()) -> UUID? {
        guard !text.isEmpty, text.utf8.count <= Self.maximumEntryBytes else { return nil }
        var entry: ClipboardEntry
        if let index = entries.firstIndex(where: { $0.text.utf8.elementsEqual(text.utf8) }) {
            entry = entries.remove(at: index)
            entry.lastUsedAt = now
        } else {
            entry = ClipboardEntry(text: text, capturedAt: now, lastUsedAt: now)
        }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(capacity))
        return entry.id
    }

    public mutating func setCapacity(_ value: Int) {
        capacity = value == 10 ? 10 : 20
        entries = Array(entries.prefix(capacity))
    }

    public mutating func clear() { entries.removeAll() }
}
