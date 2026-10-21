import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import StampedeCore

final class ImageSupportTests: XCTestCase {
    static func fixture(
        type: String = UTType.png.identifier,
        frames: Int = 1,
        width: Int = 8,
        height: Int = 4,
        orientation: Int = 1
    ) throws -> Data {
        let pixels = [UInt8](repeating: 128, count: width * height * 4)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type as CFString, frames, nil)!
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("history.enc")
    }

    func testSupportedFormatsKeepOriginalBytesAndCreateBoundedThumbnails() throws {
        for type in ClipboardImage.supportedTypes {
            let data = try Self.fixture(type: type, width: 320, height: 160)
            let image = try ImageProcessor.prepare(
                ImageCandidate(type: type, data: data, sourceApp: "Safari", sourceHost: "example.com")
            )
            XCTAssertEqual(image.data, data)
            XCTAssertEqual(image.width, 320)
            XCTAssertEqual(image.height, 160)
            XCTAssertEqual(image.label, "Image · 320 × 160 · Safari · example.com")
            let source = CGImageSourceCreateWithData(try XCTUnwrap(image.thumbnail) as CFData, nil)!
            let thumb = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            XCTAssertEqual(thumb.width, 128)
            XCTAssertEqual(thumb.height, 64)
            if [UTType.png.identifier, UTType.tiff.identifier].contains(type) {
                XCTAssertNotEqual(thumb.alphaInfo, .none)
            }
        }
    }

    func testLongHostLabelKeepsRegistrableEnd() {
        let host = "www.apple.com." + String(repeating: "a", count: 28) + ".evil.example"
        let image = ClipboardImage(
            type: UTType.png.identifier,
            data: Data([1]),
            width: 1,
            height: 1,
            sourceApp: "Safari Technology Preview",
            sourceHost: host
        )
        XCTAssertEqual(
            image.label,
            "Image · 1 × 1 · Safari Technology Previe… · …" + String(repeating: "a", count: 27) + ".evil.example"
        )
    }

    func testCapturedHostsAreLowercaseASCIIAndKeepTheirEnd() {
        XCTAssertEqual(ClipboardImage.sanitizedHost(fromURL: "HTTPS://WWW.Example.COM/image.png"), "www.example.com")
        XCTAssertNil(ClipboardImage.sanitizedHost(fromURL: "https://www.apple.com%20login.evil.example/image.png"))
        XCTAssertNil(ClipboardImage.sanitizedHost(fromURL: "ftp://example.com/image.png"))
        XCTAssertNil(ClipboardImage.sanitizedHost(fromURL: nil))
        XCTAssertTrue(
            ClipboardImage.sanitizedHost(fromURL: "https://\u{430}pple.com/image.png")?.unicodeScalars.allSatisfy(
                \.isASCII
            ) ?? true
        )
        let long = Array(repeating: "abcdefghi", count: 22).joined(separator: ".") + ".evil.example"
        XCTAssertEqual(ClipboardImage.sanitizedHost(fromURL: "https://\(long)/image.png"), String(long.suffix(200)))
    }

    func testMalformedMismatchedMultiFrameAndOversizedImagesAreRejected() throws {
        XCTAssertThrowsError(
            try ImageProcessor.prepare(ImageCandidate(type: UTType.png.identifier, data: Data("no image".utf8)))
        )
        XCTAssertThrowsError(
            try ImageProcessor.prepare(ImageCandidate(type: UTType.tiff.identifier, data: Self.fixture()))
        )
        XCTAssertThrowsError(
            try ImageProcessor.prepare(
                ImageCandidate(
                    type: UTType.tiff.identifier,
                    data: Self.fixture(type: UTType.tiff.identifier, frames: 2)
                )
            )
        )
        XCTAssertThrowsError(
            try ImageProcessor.prepare(
                ImageCandidate(
                    type: UTType.png.identifier,
                    data: Data(repeating: 0, count: ClipboardImage.maximumBytes + 1)
                )
            )
        )
        XCTAssertThrowsError(
            try ImageProcessor.prepare(
                ImageCandidate(type: UTType.png.identifier, data: Self.fixture(width: 8193, height: 1))
            )
        )
    }

    func testOrientationUsesDisplayedDimensionsWithoutChangingOriginal() throws {
        let data = try Self.fixture(type: UTType.tiff.identifier, orientation: 6)
        let image = try ImageProcessor.prepare(ImageCandidate(type: UTType.tiff.identifier, data: data))
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 8)
        XCTAssertEqual(image.data, data)
    }

    func testDelayedImageKeepsObservedOrderAndCannotDemoteSelectedImage() throws {
        let image = try ImageProcessor.prepare(ImageCandidate(type: UTType.png.identifier, data: Self.fixture()))
        let start = Date()
        var history = History()
        history.capture("newer", now: start.addingTimeInterval(2))
        let id = history.capture(ClipboardEntry(image: image, capturedAt: start, lastUsedAt: start))
        XCTAssertEqual(history.entries.first?.text, "newer")
        XCTAssertEqual(history.capture(ClipboardEntry(image: image, lastUsedAt: start.addingTimeInterval(3))), id)
        history.capture(ClipboardEntry(image: image, lastUsedAt: start.addingTimeInterval(1)))
        XCTAssertEqual(history.entries.first?.id, id)
        XCTAssertEqual(history.entries.count, 2)
    }

    func testMixedByteBudgetEvictsOldestAndOversizeDoesNotEvict() {
        var history = History()
        for index in 0..<6 {
            let data = Data(repeating: UInt8(index), count: ClipboardImage.maximumBytes)
            history.capture(
                ClipboardEntry(image: ClipboardImage(type: UTType.png.identifier, data: data, width: 1, height: 1))
            )
        }
        XCTAssertEqual(history.entries.count, 5)
        let ids = history.entries.map(\.id)
        let bad = ClipboardImage(
            type: UTType.png.identifier,
            data: Data(repeating: 0, count: ClipboardImage.maximumBytes + 1),
            width: 1,
            height: 1
        )
        XCTAssertNil(history.capture(ClipboardEntry(image: bad)))
        XCTAssertEqual(history.entries.map(\.id), ids)
    }

    func testCaptureTicketsInvalidateOnLifecycleChangesAndEviction() {
        var coordinator = CaptureCoordinator()
        let old = coordinator.reserve(bytes: 20)!
        coordinator.invalidate()  // Clear, reset, pause, and capacity changes all invalidate pending jobs.
        XCTAssertFalse(coordinator.accepts(old, capacity: 20))
        coordinator.finish(old)
        let delayed = coordinator.reserve(bytes: ClipboardImage.maximumBytes)!
        XCTAssertNil(coordinator.reserve(bytes: 1))
        for _ in 0..<20 { _ = coordinator.observe() }
        XCTAssertFalse(coordinator.accepts(delayed, capacity: 20))
        coordinator.finish(delayed)
        XCTAssertNotNil(coordinator.reserve(bytes: 1))
    }

    func testEncryptedImagesReloadAndReorderingDoesNotRewriteBlob() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await repository.load()
        let image = try ImageProcessor.prepare(ImageCandidate(type: UTType.png.identifier, data: Self.fixture()))
        let entry = ClipboardEntry(image: image)
        try await repository.save([entry, ClipboardEntry(text: "text")], generation: 1)
        let blob = file.deletingLastPathComponent().appendingPathComponent("images/\(image.blobID.uuidString).enc")
        let sealed = try Data(contentsOf: blob)
        XCTAssertNil(sealed.range(of: try XCTUnwrap(image.data)))
        let reopened = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.first, entry)
        try await reopened.save(Array(loaded.reversed()), generation: 1)
        XCTAssertEqual(try Data(contentsOf: blob), sealed)
        try await reopened.save([], generation: 3)
        try await reopened.save(loaded, generation: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
    }

    func testJPEGAndHEICSurviveEncryptedRestart() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await repository.load()
        var entries: [ClipboardEntry] = []
        for type in [UTType.jpeg.identifier, UTType.heic.identifier] {
            let data = try Self.fixture(type: type, width: 160, height: 80)
            let image = try ImageProcessor.prepare(ImageCandidate(type: type, data: data))
            entries.append(ClipboardEntry(image: image))
        }
        try await repository.save(entries, generation: 1)
        let restored = try await HistoryRepository(fileURL: file, keyStore: TestKeyStore()).load()
        XCTAssertEqual(restored, entries)
        XCTAssertEqual(restored.compactMap { $0.image?.type }, [UTType.jpeg.identifier, UTType.heic.identifier])
    }

    func testTamperedBlobDisablesOnlyImageAndResetRemovesBlobs() async throws {
        let file = try temporaryFile()
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        _ = try await repository.load()
        let image = try ImageProcessor.prepare(ImageCandidate(type: UTType.png.identifier, data: Self.fixture()))
        try await repository.save([ClipboardEntry(image: image), ClipboardEntry(text: "healthy")], generation: 1)
        let blob = file.deletingLastPathComponent().appendingPathComponent("images/\(image.blobID.uuidString).enc")
        var bytes = try Data(contentsOf: blob)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: blob)
        let reopened = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let loaded = try await reopened.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertNil(loaded[0].image?.data)
        XCTAssertEqual(loaded[1].text, "healthy")
        let orphan = blob.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).enc")
        let staging = blob.deletingLastPathComponent().appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let unrelated = blob.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("encrypted orphan".utf8).write(to: orphan)
        try Data("encrypted staging".utf8).write(to: staging)
        try Data("leave alone".utf8).write(to: unrelated)
        try FileManager.default.removeItem(at: blob)
        let missing = try await HistoryRepository(fileURL: file, keyStore: TestKeyStore()).load()
        XCTAssertNil(missing[0].image?.data)
        XCTAssertEqual(missing[1].text, "healthy")
        try await reopened.reset(generation: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLegacyV1MigrationPreservesIdentityOrderAndTimestamps() async throws {
        struct LegacyEntry: Codable {
            let id: UUID
            let text: String
            let capturedAt: Date
            let lastUsedAt: Date
        }
        struct Legacy: Codable {
            let version: Int
            let entries: [LegacyEntry]
        }
        let file = try temporaryFile()
        let old = LegacyEntry(
            id: UUID(),
            text: "e\u{301}\n🦬",
            capturedAt: Date(timeIntervalSince1970: 1),
            lastUsedAt: Date(timeIntervalSince1970: 2)
        )
        let data = try PropertyListEncoder().encode(Legacy(version: 1, entries: [old]))
        let sealed = try AES.GCM.seal(data, using: TestKeyStore().key(createIfMissing: false)).combined!
        try sealed.write(to: file)
        let repository = HistoryRepository(fileURL: file, keyStore: TestKeyStore())
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.first?.id, old.id)
        XCTAssertEqual(loaded.first?.capturedAt, old.capturedAt)
        XCTAssertEqual(loaded.first?.lastUsedAt, old.lastUsedAt)
        XCTAssertEqual(loaded.first?.text.utf8.map { $0 }, old.text.utf8.map { $0 })
        XCTAssertEqual(try Data(contentsOf: file), sealed, "Load must preserve v1 until a successful v2 commit")
        try await repository.save(loaded, generation: 1)
        let reread = try await HistoryRepository(fileURL: file, keyStore: TestKeyStore()).load()
        XCTAssertEqual(reread, loaded)
    }
}
