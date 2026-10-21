import AppKit
import CryptoKit
import Security
import ImageIO
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

    static func sampleImageData(type: String = "public.png") -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 640, bitsPerPixel: 32), let bytes = bitmap.bitmapData else { return nil }
        for y in 0..<80 { for x in 0..<160 {
            let offset = y * 640 + x * 4
            bytes[offset] = UInt8(x); bytes[offset + 1] = UInt8(100 + y)
            bytes[offset + 2] = 220; bytes[offset + 3] = x < 80 ? 128 : 255
        } }
        guard let image = bitmap.cgImage else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
        for identifier in ClipboardImage.supportedTypes {
            guard let data = sampleImageData(type: identifier) else { return false }
            let type = NSPasteboard.PasteboardType(identifier)
            let item = NSPasteboardItem()
            item.setData(data, forType: type)
            item.setString("https://example.com/image", forType: .URL)
            item.setString("https://example.com/image", forType: .string)
            // Both representations still form one entry; PNG is preferred when present.
            if type == .png, let tiff = sampleImageData(type: "public.tiff") { item.setData(tiff, forType: .tiff) }
            board.clearContents()
            guard board.writeObjects([item]), case .image(let candidate) = client.read(),
                  candidate.type == type.rawValue, candidate.data == data, candidate.sourceHost == "example.com",
                  let image = try? ImageProcessor.prepare(candidate), image.width == 160, image.height == 80,
                  client.writeImage(image), case .image(let restored) = client.read(), restored.data == data,
                  restored.type == type.rawValue,
                  let source = CGImageSourceCreateWithData(restored.data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  decoded.width == 160, decoded.height == 80,
                  (!["public.png", "public.tiff"].contains(identifier) || decoded.alphaInfo != .none) else { return false }
            let sensitiveImage = NSPasteboardItem()
            sensitiveImage.setData(data, forType: type)
            sensitiveImage.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            board.clearContents()
            guard board.writeObjects([sensitiveImage]), client.read() == .excluded else { return false }
            let fileImage = NSPasteboardItem()
            fileImage.setString("file:///tmp/image.png", forType: .fileURL)
            fileImage.setData(data, forType: type)
            board.clearContents()
            guard board.writeObjects([fileImage]), client.read() == .excluded else { return false }
        }
        let revision = client.clear()
        return revision == client.revision && client.read() == .excluded
    }
}
