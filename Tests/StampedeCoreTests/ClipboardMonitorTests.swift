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

@MainActor extension ClipboardMonitor {
    /// A background poll that first sees a revision, then the next one after the settle delay.
    func pollSettled(now: Date = Date()) {
        poll(now: now)
        poll(now: now.addingTimeInterval(ClipboardMonitor.settleDelay))
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
            monitor.pollSettled()
            XCTAssertEqual(images, 1)
            XCTAssertTrue(monitor.activateImage(image))
            monitor.pollSettled()
            XCTAssertEqual(images, 1)
            client.revision += 1
            client.result = .image(ImageCandidate(type: image.type, data: image.data!))
            monitor.pollSettled()
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
            monitor.pollSettled()
            XCTAssertTrue(captures.isEmpty)
            client.copy("next copy")
            monitor.pollSettled()
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
            monitor.pollSettled()
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
            monitor.pollSettled()
            XCTAssertTrue(monitor.activate("old"))
            monitor.pollSettled()
            client.copy("new")
            monitor.pollSettled()
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
            monitor.pollSettled()
            XCTAssertEqual(client.reads, 1)
            XCTAssertTrue(captures.isEmpty)
            client.onRead = nil
            client.result = .unavailable
            let now = Date()
            monitor.pollSettled(now: now)
            client.result = .text("from iPad")
            monitor.poll(now: now.addingTimeInterval(ClipboardMonitor.settleDelay + 1.1))
            XCTAssertEqual(captures, ["from iPad"])
            XCTAssertTrue(client.writes.isEmpty)
        }
    }

    func testFirstBackgroundPollOfRevisionWaitsForWriterToFinish() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            let now = Date()
            client.copy("password")
            monitor.poll(now: now)
            XCTAssertEqual(client.reads, 0, "The writer may not have added its concealed marker yet")
            client.result = .excluded
            monitor.poll(now: now.addingTimeInterval(ClipboardMonitor.settleDelay / 2))
            XCTAssertEqual(client.reads, 0)
            monitor.poll(now: now.addingTimeInterval(ClipboardMonitor.settleDelay))
            XCTAssertEqual(client.reads, 1)
            XCTAssertTrue(captures.isEmpty, "The marker added under the same revision is honored")
        }
    }

    func testUserInitiatedPollSkipsSettleDelayButNotUnavailableBackoff() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            let now = Date()
            client.copy("a")
            monitor.poll(userInitiated: true, now: now)
            client.copy("b")
            monitor.poll(now: now)
            monitor.poll(userInitiated: true, now: now)
            XCTAssertEqual(captures, ["a", "b"])
            client.copy("c")
            client.result = .unavailable
            monitor.poll(userInitiated: true, now: now)
            monitor.poll(userInitiated: true, now: now)
            XCTAssertEqual(client.reads, 3)
        }
    }

    func testForegroundPollSkipsSettleDelayButNotAccessCheckOrBackoff() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            var captures: [String] = []
            monitor.onCapture = { captures.append($0) }
            let now = Date()
            client.copy("a")
            monitor.poll(now: now)
            monitor.poll(foreground: true, now: now)
            client.copy("b")
            monitor.poll(foreground: true, now: now)
            XCTAssertEqual(
                captures,
                ["a", "b"],
                "Opening the menu or selecting an entry must not wait for the settle delay"
            )
            client.canReadInBackground = false
            client.copy("c")
            monitor.poll(foreground: true, now: now)
            XCTAssertEqual(client.reads, 2, "Foreground polls still need background read access")
            client.canReadInBackground = true
            client.result = .unavailable
            monitor.poll(foreground: true, now: now)
            monitor.poll(foreground: true, now: now)
            XCTAssertEqual(client.reads, 3)
        }
    }

    func testDeniedBackgroundAccessNeverReadsAndBaselineSkipsPausedCopy() async {
        await MainActor.run {
            let client = FakeClipboard()
            let monitor = ClipboardMonitor(clipboard: client)
            client.canReadInBackground = false
            client.copy("private")
            monitor.pollSettled()
            XCTAssertEqual(client.reads, 0)
            client.canReadInBackground = true
            monitor.baseline()
            monitor.pollSettled()
            XCTAssertEqual(client.reads, 0)
            client.copy("after pause")
            monitor.pollSettled()
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
