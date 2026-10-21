import XCTest

@testable import StampedeCore

final class HistoryTests: XCTestCase {
    func testPromotionPreservesIdentityAndNextCopyWins() {
        var history = History()
        let a = history.capture("Alpha")!
        history.capture("Bravo")
        history.capture("Charlie")
        XCTAssertEqual(history.capture("Alpha"), a)
        XCTAssertEqual(history.entries.map(\.text), ["Alpha", "Charlie", "Bravo"])
        history.capture("Delta")
        XCTAssertEqual(history.entries.map(\.text), ["Delta", "Alpha", "Charlie", "Bravo"])
    }

    func testLimitsEvictOldestAndRejectOversizedText() {
        var history = History()
        for index in 0...20 { history.capture("\(index)") }
        XCTAssertEqual(history.entries.count, 20)
        XCTAssertEqual(history.entries.last?.text, "1")
        history.setCapacity(10)
        XCTAssertEqual(history.entries.count, 10)
        XCTAssertEqual(history.entries.last?.text, "11")
        XCTAssertNil(history.capture(String(repeating: "a", count: History.maximumEntryBytes + 1)))
        XCTAssertEqual(history.entries.count, 10)
    }

    func testExactBytesAndWhitespaceArePreserved() {
        var history = History()
        history.capture("é")
        history.capture("e\u{301}")
        history.capture(" \n\t ")
        XCTAssertEqual(history.entries.count, 3)
        XCTAssertEqual(history.entries[0].text, " \n\t ")
        XCTAssertNil(history.capture(""))
        XCTAssertFalse(history.entries[0].preview.contains("\n"))
    }

    func testLoadSanitizesDuplicateIDsAndInvalidEntries() {
        let id = UUID()
        let history = History(entries: [
            ClipboardEntry(id: id, text: "a"), ClipboardEntry(id: id, text: "b"), ClipboardEntry(text: ""),
        ])
        XCTAssertEqual(history.entries.map(\.text), ["a"])
    }
}
