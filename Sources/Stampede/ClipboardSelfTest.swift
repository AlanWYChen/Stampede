import AppKit
import CryptoKit
import Security
#if canImport(StampedeCore)
import StampedeCore
#endif

/// Integration checks deliberately use a private pasteboard, never the user's general clipboard.
@MainActor enum ClipboardSelfTest {
    static func keychainRoundTrip() -> Bool {
        let service = "com.alanwychen.stampede.selftest.\(UUID().uuidString)"
        defer {
            // Only remove this run's disposable test item, never the production history key.
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }
        do {
            let first = try HistoryKeyStore(service: service).key(createIfMissing: true)
            let second = try HistoryKeyStore(service: service).key(createIfMissing: false)
            return first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) }
        } catch {
            print("Keychain integration error: \(error.localizedDescription)")
            return false
        }
    }

    static func run() -> Bool {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let client = SystemClipboardClient(pasteboard: board)
        guard client.write("Alpha\n🦬"), client.read() == .text("Alpha\n🦬") else { return false }
        let concealed = NSPasteboardItem()
        concealed.setString("ignored", forType: .string)
        concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents()
        guard board.writeObjects([concealed]), client.read() == .excluded else { return false }
        let file = NSPasteboardItem()
        file.setString("file:///tmp/example.txt", forType: .fileURL)
        file.setString("example.txt", forType: .string)
        board.clearContents()
        guard board.writeObjects([file]), client.read() == .excluded else { return false }
        guard client.write("selected history entry"), client.read() == .text("selected history entry") else { return false }
        let revision = client.clear()
        return revision == client.revision && client.read() == .excluded
    }
}
