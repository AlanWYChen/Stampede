import XCTest

@testable import StampedeCore

@MainActor final class FakeClipboard: ClipboardClient {
    var revision = 0
    var canReadInBackground = true
    var result: ClipboardRead = .excluded
    var writeSucceeds = true
    var reads = 0
    var writes: [String] = []
    var imageWrites = 0

    func writeImage(_ image: ClipboardImage) -> Bool {
        imageWrites += 1
        revision += 1
        result = .excluded
        return writeSucceeds
    }

    var onRead: (() -> Void)?

    func read() -> ClipboardRead {
        reads += 1
        onRead?()
        return result
    }

    func write(_ text: String) -> Bool {
        writes.append(text)
        revision += 1
        result = writeSucceeds ? .text(text) : .excluded
        return writeSucceeds
    }

    func clear() -> Int {
        revision += 1
        result = .excluded
        return revision
    }

    func copy(_ text: String) {
        revision += 1
        result = .text(text)
    }
}

final class ClipboardMonitorTests: XCTestCase {
    func testImageObservationAndActivationSuppressOnlyOwnWrite() async throws {
        let image = try ImageProcessor.prepare(ImageCandidate(type: "public.png", data: ImageSupportTests.fixture()))
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var images = 0
            monitor.onImage = { _, revision in
                images += 1
                XCTAssertEqual(revision, client.revision)
            }
            client.result = .image(ImageCandidate(type: image.type, data: image.data!))
            monitor.poll()
            XCTAssertEqual(images, 1)
            XCTAssertTrue(monitor.activateImage(image))
            monitor.poll()
            XCTAssertEqual(images, 1)
            client.revision += 1
            client.result = .image(ImageCandidate(type: image.type, data: image.data!))
            monitor.poll()
            XCTAssertEqual(images, 2)
            client.writeSucceeds = false
            let processed = monitor.processedRevision
            XCTAssertFalse(monitor.activateImage(image))
            XCTAssertEqual(monitor.processedRevision, processed)
        }
    }

    func testClearClipboardSuppressesOnlyItsOwnRevisionAndKeepsNextCopy() async {
        await MainActor.run {
            let client = FakeClipboard()
            client.copy("current")
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            monitor.clearClipboard()
            XCTAssertEqual(client.result, .excluded)
            monitor.poll()
            XCTAssertTrue(captures.isEmpty)
            client.copy("next copy")
            monitor.poll()
            XCTAssertEqual(captures, ["next copy"])
        }
    }

    func testExplicitAccessCheckReadsUnchangedClipboardWithoutCapturingOrWriting() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            client.copy("already observed")
            monitor.baseline()
            client.canReadInBackground = false
            var captured = false
            monitor.onCapture = { _ in captured = true }
            let revision = monitor.processedRevision
            monitor.probeAccess()
            monitor.probeAccess()
            XCTAssertEqual(client.reads, 2, "Every explicit check must work even when the clipboard is unchanged")
            XCTAssertFalse(captured, "Permission checks must not add or promote history")
            XCTAssertTrue(client.writes.isEmpty)
            XCTAssertEqual(monitor.processedRevision, revision)
        }
    }

    func testExplicitAccessCheckBypassesPendingPayloadBackoff() async {
        await MainActor.run {
            let client = FakeClipboard()
            client.result = .unavailable
            let monitor = ClipboardMonitor(clipboard: client)
            monitor.poll(now: Date())
            let reads = client.reads
            monitor.probeAccess()
            XCTAssertEqual(client.reads, reads + 1)
        }
    }

    func testOnlyUndecidedOrAskStatesNeedPermissionProbe() {
        XCTAssertTrue(ClipboardAccessState.notDetermined.needsPermissionProbe)
        XCTAssertTrue(ClipboardAccessState.ask.needsPermissionProbe)
        XCTAssertFalse(ClipboardAccessState.allowed.needsPermissionProbe)
        XCTAssertFalse(ClipboardAccessState.denied.needsPermissionProbe)
        XCTAssertFalse(ClipboardAccessState.unknown.needsPermissionProbe)
    }

    func testOwnWriteDoesNotDuplicateOrSuppressNextExternalCopy() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            client.copy("a")
            monitor.poll()
            XCTAssertTrue(monitor.activate("old"))
            monitor.poll()
            client.copy("new")
            monitor.poll()
            XCTAssertEqual(captures, ["a", "new"])
        }
    }

    func testUnstableReadsAreDiscardedAndDelayedPayloadIsRetried() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            client.copy("stale")
            client.onRead = { client.revision += 1 }
            monitor.poll()
            XCTAssertTrue(captures.isEmpty)
            client.onRead = nil
            client.result = .unavailable
            let now = Date()
            monitor.poll(now: now)
            client.result = .text("from iPad")
            monitor.poll(now: now.addingTimeInterval(1.1))
            XCTAssertEqual(captures, ["from iPad"])
            XCTAssertTrue(client.writes.isEmpty)
        }
    }

    func testDeniedBackgroundAccessNeverReadsAndBaselineSkipsPausedCopy() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            client.canReadInBackground = false
            client.copy("private")
            monitor.poll()
            XCTAssertEqual(client.reads, 0)
            client.canReadInBackground = true
            monitor.baseline()
            monitor.poll()
            XCTAssertEqual(client.reads, 0)
            client.copy("after pause")
            monitor.poll()
            XCTAssertEqual(client.reads, 1)
        }
    }

    func testFailedWriteDoesNotMarkRevisionAsOwnWrite() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            client.writeSucceeds = false
            XCTAssertFalse(monitor.activate("entry"))
            XCTAssertNil(monitor.processedRevision)
        }
    }

    func testUnavailablePayloadRetryIsBounded() async {
        await MainActor.run {
            let client = FakeClipboard()
            client.result = .unavailable
            let monitor = ClipboardMonitor(clipboard: client)
            let now = Date()
            for index in 0..<50 { monitor.poll(now: now.addingTimeInterval(Double(index * 10))) }
            XCTAssertEqual(client.reads, 4)
        }
    }
}
