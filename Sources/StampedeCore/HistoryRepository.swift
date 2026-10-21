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

private struct ImageCleanupError: LocalizedError {
    var errorDescription: String? { "History was saved, but some old encrypted image files could not be removed. Retry History Storage to finish cleanup." }
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
    private var committedBlobs = Set<UUID>()
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
        struct Header: Decodable { let version: Int }
        let version: Int
        do { version = try PropertyListDecoder().decode(Header.self, from: plaintext).version }
        catch { throw HistoryStorageError.invalidFile }
        guard [1, 2].contains(version) else { throw HistoryStorageError.unsupportedVersion }
        let snapshot: Snapshot
        do { snapshot = try PropertyListDecoder().decode(Snapshot.self, from: plaintext) }
        catch { throw HistoryStorageError.invalidFile }
        guard [1, 2].contains(snapshot.version) else { throw HistoryStorageError.unsupportedVersion }
        let validated = History(entries: snapshot.entries)
        guard validated.entries == snapshot.entries else { throw HistoryStorageError.invalidEntries }
        var entries = snapshot.entries
        committedBlobs.removeAll()
        for index in entries.indices {
            guard var image = entries[index].image else { continue }
            do {
                let url = blobURL(image.blobID)
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                guard size?.intValue == image.byteCount + 28 else { throw HistoryStorageError.invalidFile }
                let encrypted = try Data(contentsOf: url)
                let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key, authenticating: image.authenticatedContext)
                guard bytes.count == image.byteCount, Data(SHA256.hash(data: bytes)) == image.digest else { throw HistoryStorageError.invalidFile }
                let prepared = try ImageProcessor.prepare(ImageCandidate(type: image.type, data: bytes))
                guard prepared.width == image.width, prepared.height == image.height else { throw HistoryStorageError.invalidFile }
                image.data = bytes; image.thumbnail = prepared.thumbnail
                committedBlobs.insert(image.blobID)
            } catch {
                // A broken image does not hide healthy text or other images. Keep its descriptor for the disabled row.
                image.data = nil; image.thumbnail = nil
            }
            entries[index].image = image
        }
        loaded = true
        return entries
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
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let images = entries.compactMap(\.image)
        for image in images where !committedBlobs.contains(image.blobID) {
            guard let bytes = image.data else { continue }
            guard Data(SHA256.hash(data: bytes)) == image.digest else { throw HistoryStorageError.invalidEntries }
            if let available = try fileURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
               available < bytes.count + 2 * 1_048_576 { throw CocoaError(.fileWriteOutOfSpace) }
            let encrypted = try AES.GCM.seal(bytes, using: key, authenticating: image.authenticatedContext).combined!
            try atomicWrite(encrypted, to: blobURL(image.blobID))
            committedBlobs.insert(image.blobID)
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(Snapshot(version: 2, entries: entries))
        let encrypted = try AES.GCM.seal(plaintext, using: key).combined!
        try atomicWrite(encrypted, to: fileURL)
        let retained = Set(images.map(\.blobID))
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("images")
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard url.pathExtension == "enc", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !retained.contains(id) else { continue }
                do { try FileManager.default.removeItem(at: url) }
                catch { throw ImageCleanupError() }
                committedBlobs.remove(id)
            }
        }
        // Recover encrypted staging files left by a process interruption, including clear/reset.
        for folder in [fileURL.deletingLastPathComponent(), directory] where FileManager.default.fileExists(atPath: folder.path) {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                guard name.hasPrefix(".history-"), name.hasSuffix(".tmp"),
                      UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil else { continue }
                do { try FileManager.default.removeItem(at: url) }
                catch { throw ImageCleanupError() }
            }
        }
    }

    private func blobURL(_ id: UUID) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("images").appendingPathComponent("\(id.uuidString).enc")
    }

    private func atomicWrite(_ encrypted: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
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
        guard rename(temporary.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Commits an empty history without the key by deleting the snapshot, its image blobs, and staging files.
    /// Like `save`, it requires a successful load and ignores generations older than the last commit.
    public func erase(generation: UInt64) throws {
        guard loaded else { throw HistoryStorageError.invalidFile }
        guard generation >= latestGeneration else { return }
        committedBlobs.removeAll()
        let folder = fileURL.deletingLastPathComponent()
        let images = folder.appendingPathComponent("images")
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        for (directory, blobs) in [(folder, false), (images, true)] where FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                let blob = blobs && url.pathExtension == "enc" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
                let staging = name.hasPrefix(".history-") && name.hasSuffix(".tmp") && UUID(uuidString: String(name.dropFirst(9).dropLast(4))) != nil
                if blob || staging { try FileManager.default.removeItem(at: url) }
            }
        }
        latestGeneration = generation
    }
}
