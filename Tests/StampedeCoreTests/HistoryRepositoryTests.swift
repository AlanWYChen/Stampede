import CryptoKit
import XCTest

@testable import StampedeCore

struct TestKeyStore: HistoryKeyProviding {
    let data: Data

    init(data: Data = Data(repeating: 42, count: 32)) { self.data = data }

    func key(createIfMissing: Bool) throws -> SymmetricKey { SymmetricKey(data: data) }
}

struct MissingKeyStore: HistoryKeyProviding {
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        guard createIfMissing else { throw HistoryStorageError.missingKey }
        return SymmetricKey(data: Data(repeating: 9, count: 32))
    }
}
struct LockedKeyStore: HistoryKeyProviding {
    func key(createIfMissing: Bool) throws -> SymmetricKey { throw HistoryStorageError.keychain(-25308) }
}

/// Reject extra lookups so a regression cannot silently pass by returning the same key again.
private final class SingleAccessKeyStore: HistoryKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private let failFirstAttempt: Bool

    init(failFirstAttempt: Bool = false) { self.failFirstAttempt = failFirstAttempt }

    func key(createIfMissing: Bool) throws -> SymmetricKey {
        try lock.withLock {
            attempts += 1
            if failFirstAttempt && attempts == 1 { throw HistoryStorageError.keychain(-25308) }
            guard attempts == (failFirstAttempt ? 2 : 1) else {
                throw HistoryStorageError.keychain(-25308)
            }
            return try TestKeyStore().key(createIfMissing: createIfMissing)
        }
    }
}

final class HistoryRepositoryTests: XCTestCase {
    private func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("history.enc")
    }

    func testInitializedKeyIsReusedForSavesReloadAndReset() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: SingleAccessKeyStore())
        _ = try await repository.load()
        let entries = [ClipboardEntry(text: "first copy")]
        try await repository.save(entries, generation: 1)
        try await repository.save(entries, generation: 2, userInitiated: true)
        let restored = try await repository.load(userInitiated: true)
        XCTAssertEqual(restored, entries)
        try await repository.reset(generation: 3)
        try await repository.save([ClipboardEntry(text: "after reset")], generation: 4)
        let reopened = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let saved = try await reopened.load(requireExisting: true)
        XCTAssertEqual(saved.map(\.text), ["after reset"])
    }

    func testExistingHistoryKeyIsReusedAfterLoad() async throws {
        let file = try temporaryFile()
        let writer = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await writer.load()
        try await writer.save([ClipboardEntry(text: "existing")], generation: 1)
        let reader = HistoryRepository(fileURL: file, keyStore: SingleAccessKeyStore())
        _ = try await reader.load(requireExisting: true)
        let entries = [ClipboardEntry(text: "new copy")]
        try await reader.save(entries, generation: 1)
        let restored = try await reader.load()
        XCTAssertEqual(restored, entries)
    }

    func testFailedKeyLookupCanBeRetriedAndSuccessfulKeyIsCached() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: SingleAccessKeyStore(failFirstAttempt: true))
        do {
            _ = try await repository.load()
            XCTFail("The first lookup should fail")
        } catch HistoryStorageError.keychain {} catch { XCTFail("Unexpected: \(error)") }
        _ = try await repository.load(userInitiated: true)
        let entries = [ClipboardEntry(text: "after unlocking")]
        try await repository.save(entries, generation: 1)
        let restored = try await repository.load()
        XCTAssertEqual(restored, entries)
    }

    func testResetCachesItsKeyForSubsequentSaves() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: SingleAccessKeyStore())
        try await repository.reset(generation: 1)
        let entries = [ClipboardEntry(text: "after recovery")]
        try await repository.save(entries, generation: 2)
        let restored = try await repository.load()
        XCTAssertEqual(restored, entries)
    }

    func testCorruptHistoryResetReusesSuccessfullyRetrievedKey() async throws {
        let file = try temporaryFile()
        try Data("corrupted snapshot".utf8).write(to: file)
        let repository = HistoryRepository(fileURL: file, keyStore: SingleAccessKeyStore())
        do {
            _ = try await repository.load()
            XCTFail("Corruption should fail")
        } catch HistoryStorageError.invalidFile {} catch { XCTFail("Unexpected: \(error)") }
        try await repository.reset(generation: 1)
        let restored = try await repository.load()
        XCTAssertTrue(restored.isEmpty)
    }

    func testMissingKeyRequiresExplicitResetAndRejectsLateSave() async throws {
        let file = try temporaryFile()
        let original = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await original.load()
        try await original.save([ClipboardEntry(text: "previous history")], generation: 1)
        let bytes = try Data(contentsOf: file)
        let recovery = HistoryRepository(fileURL: file, keyStore: MissingKeyStore())
        do {
            _ = try await recovery.load()
            XCTFail("A missing key must not be generated during load")
        } catch HistoryStorageError.missingKey {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try await recovery.reset(generation: 5)
        try await recovery.save([ClipboardEntry(text: "late old data")], generation: 4)
        let reopened = HistoryRepository(fileURL: file, keyStore: TestKeyStore(data: Data(repeating: 9, count: 32)))
        let restored = try await reopened.load(requireExisting: true)
        XCTAssertTrue(restored.isEmpty)
        try await reopened.save([ClipboardEntry(text: "new copy")], generation: 1)
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.map(\.text), ["new copy"])
    }

    func testCorruptedHistoryCanBeResetAndReloaded() async throws {
        let file = try temporaryFile()
        try Data("corrupted snapshot".utf8).write(to: file)
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        do {
            _ = try await repository.load()
            XCTFail("Corruption must be reported")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("corrupted snapshot".utf8))
        try await repository.reset(generation: 1)
        let loaded = try await repository.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testPreviouslySavedMissingFileRequiresRecoveryButFirstRunDoesNot() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        do {
            _ = try await repository.load(requireExisting: true)
            XCTFail("Missing saved history must be reported")
        } catch HistoryStorageError.missingFile {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await repository.reset(generation: 1)
        let loaded = try await repository.load(requireExisting: true)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLockedKeychainResetPreservesOriginalFile() async throws {
        let file = try temporaryFile()
        let bytes = Data("preserve me".utf8)
        try bytes.write(to: file)
        let repository = HistoryRepository(fileURL: file, keyStore: LockedKeyStore())
        do {
            try await repository.reset(generation: 1)
            XCTFail("Cannot reset without an available key")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testRetryLoadsExistingHistoryWithoutResettingIt() async throws {
        let file = try temporaryFile()
        let writer = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await writer.load()
        let entries = [ClipboardEntry(text: "preserved history")]
        try await writer.save(entries, generation: 1)
        let valid = try Data(contentsOf: file)
        try Data("corruption".utf8).write(to: file)
        let reader = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        do {
            _ = try await reader.load()
            XCTFail("Corruption should fail")
        } catch {}
        try valid.write(to: file)
        let retried = try await reader.load(userInitiated: true)
        XCTAssertEqual(retried, entries)
    }

    func testEncryptedRoundTripSurvivesNewRepositoryAndPreservesOrder() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let empty = try await repository.load()
        XCTAssertTrue(empty.isEmpty)
        let entries = [ClipboardEntry(text: "secret-unicode-🦬\n\t"), ClipboardEntry(text: "older")]
        try await repository.save(entries, generation: 1)
        let encrypted = try Data(contentsOf: file)
        XCTAssertNil(encrypted.range(of: Data(entries[0].text.utf8)))
        let second = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let restored = try await second.load()
        XCTAssertEqual(restored, entries)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testClearCannotBeUndoneByLateSave() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await repository.load()
        try await repository.save([ClipboardEntry(text: "old")], generation: 1)
        try await repository.save([], generation: 3)
        try await repository.save([ClipboardEntry(text: "late old save")], generation: 2)
        let reopened = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let restored = try await reopened.load()
        XCTAssertTrue(restored.isEmpty)
    }

    func testTamperedOrWrongKeyDoesNotOverwriteSavedFile() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await repository.load()
        try await repository.save([ClipboardEntry(text: "private")], generation: 1)
        let original = try Data(contentsOf: file)
        let wrongKey = HistoryRepository(fileURL: file, keyStore: TestKeyStore(data: Data(repeating: 13, count: 32)))
        do {
            _ = try await wrongKey.load()
            XCTFail("Wrong key should fail")
        } catch {}
        do {
            try await wrongKey.save([], generation: 2)
            XCTFail("Failed load must block writes")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnsupportedSchemaAndInvalidSnapshotAreRejected() async throws {
        struct Future: Codable {
            let version: Int
            let entries: [ClipboardEntry]
        }
        let file = try temporaryFile()
        let plaintext = try PropertyListEncoder().encode(Future(version: 999, entries: []))
        let sealed = try AES.GCM.seal(plaintext, using: TestKeyStore().key(createIfMissing: false)).combined!
        try sealed.write(to: file)
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        do {
            _ = try await repository.load()
            XCTFail("Future schema should fail")
        } catch HistoryStorageError.unsupportedVersion {} catch { XCTFail("Unexpected failure: \(error)") }
    }
}
