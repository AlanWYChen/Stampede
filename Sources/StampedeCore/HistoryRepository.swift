import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

public enum HistoryStorageError: LocalizedError {
    case keychain(OSStatus)
    case missingKey, missingFile, invalidFile, unsupportedVersion, invalidEntries
    public var errorDescription: String? {
        switch self {
        case .keychain: "The history encryption key is unavailable. Unlock your login Keychain and retry."
        case .missingFile: "The saved history file is missing. Try again or reset to start a new history."
        case .missingKey: "The saved history encryption key is missing. Existing history has not been replaced."
        case .invalidFile: "Saved history could not be authenticated or read. The original file has been preserved."
        case .unsupportedVersion: "This history was created by a newer version of Stampede. Update the app to open it."
        case .invalidEntries: "The saved history contains invalid entries. The original file has been preserved."
        }
    }
}

public protocol HistoryKeyProviding: Sendable {
    func key(createIfMissing: Bool) throws -> SymmetricKey
    func keyForReset() throws -> SymmetricKey
    func keyForRetry(createIfMissing: Bool) throws -> SymmetricKey
}

public extension HistoryKeyProviding {
    func keyForRetry(createIfMissing: Bool) throws -> SymmetricKey { try key(createIfMissing: createIfMissing) }
    func keyForReset() throws -> SymmetricKey { try key(createIfMissing: true) }
}

public struct HistoryKeyStore: HistoryKeyProviding {
    private let service: String
    // Keep the installed Keychain service stable so renaming the project preserves existing history.
    public init(service: String = "com.alanwychen.rotarystamp.history") { self.service = service }
    public func keyForReset() throws -> SymmetricKey {
        do { return try keyForRetry(createIfMissing: true) }
        catch HistoryStorageError.keychain(let status) where status == errSecSuccess {
            // A malformed key is unusable. Replace only on the user's explicit Reset action.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: service,
                                       kSecAttrAccount as String: "history-key-v1",
                                       kSecAttrSynchronizable as String: false]
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw HistoryStorageError.keychain(result) }
            return try keyForRetry(createIfMissing: true)
        }
    }

    public func key(createIfMissing: Bool) throws -> SymmetricKey {
        try lookupKey(createIfMissing: createIfMissing, allowInteraction: false)
    }

    public func keyForRetry(createIfMissing: Bool) throws -> SymmetricKey {
        try lookupKey(createIfMissing: createIfMissing, allowInteraction: true)
    }

    private func lookupKey(createIfMissing: Bool, allowInteraction: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "history-key-v1",
            kSecAttrSynchronizable as String: false
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never raise a repeated background Keychain prompt at login.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        lookup[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw HistoryStorageError.keychain(status) }
        guard createIfMissing else { throw HistoryStorageError.missingKey }
        let key = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        if added == errSecDuplicateItem { return try lookupKey(createIfMissing: false, allowInteraction: allowInteraction) }
        guard added == errSecSuccess else { throw HistoryStorageError.keychain(added) }
        return key
    }
}

public actor HistoryRepository {
    private struct Snapshot: Codable {
        let version: Int
        let entries: [ClipboardEntry]
    }
    public let fileURL: URL
    private let keyStore: any HistoryKeyProviding
    private var latestGeneration: UInt64 = 0
    private var loaded = false
    private let maximumFileBytes = 24 * 1_048_576

    public init(fileURL: URL, keyStore: any HistoryKeyProviding = HistoryKeyStore()) {
        self.fileURL = fileURL
        self.keyStore = keyStore
    }

    public func load(requireExisting: Bool = false, userInitiated: Bool = false) throws -> [ClipboardEntry] {
        loaded = false
        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        guard exists || !requireExisting else { throw HistoryStorageError.missingFile }
        let key = try userInitiated ? keyStore.keyForRetry(createIfMissing: !exists) : keyStore.key(createIfMissing: !exists)
        guard exists else { loaded = true; return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumFileBytes else {
            throw HistoryStorageError.invalidFile
        }
        let data = try Data(contentsOf: fileURL)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key) }
        catch { throw HistoryStorageError.invalidFile }
        let snapshot: Snapshot
        do { snapshot = try PropertyListDecoder().decode(Snapshot.self, from: plaintext) }
        catch { throw HistoryStorageError.invalidFile }
        guard snapshot.version == 1 else { throw HistoryStorageError.unsupportedVersion }
        let validated = History(entries: snapshot.entries)
        guard validated.entries == snapshot.entries else { throw HistoryStorageError.invalidEntries }
        loaded = true
        return snapshot.entries
    }

    /// Actor serialization plus monotonic generations prevents late old saves from resurrecting cleared entries.
    public func save(_ entries: [ClipboardEntry], generation: UInt64, userInitiated: Bool = false) throws {
        guard loaded else { throw HistoryStorageError.invalidFile }
        guard generation >= latestGeneration else { return }
        guard History(entries: entries).entries == entries else { throw HistoryStorageError.invalidEntries }
        let key = try userInitiated ? keyStore.keyForRetry(createIfMissing: false) : keyStore.key(createIfMissing: false)
        try writeSnapshot(entries, key: key)
        latestGeneration = generation
    }

    /// Destructive recovery is available only through an explicit user action.
    /// Retain a usable key; recreate a missing/unusable key, then atomically replace the snapshot.
    public func reset(generation: UInt64) throws {
        guard generation >= latestGeneration else { return }
        let key = try keyStore.keyForReset()
        try writeSnapshot([], key: key)
        latestGeneration = generation
        loaded = true
    }

    private func writeSnapshot(_ entries: [ClipboardEntry], key: SymmetricKey) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(Snapshot(version: 1, entries: entries))
        let encrypted = try AES.GCM.seal(plaintext, using: key).combined!
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: encrypted)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard rename(temporary.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
