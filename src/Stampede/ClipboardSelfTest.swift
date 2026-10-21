import AppKit
import CryptoKit
import ImageIO
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
            SecItemDelete(
                [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                ] as CFDictionary
            )
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
        // Synthetic two-frame, lossless WebP; Image I/O has no WebP encoder.
        if type == "org.webmproject.webp" {
            return Data(
                base64Encoded:
                    "UklGRoQAAABXRUJQVlA4WAoAAAASAAAAnwAATwAAQU5JTQYAAAAAAAAAAABBTk1GKAAAAAAAAAAAAJ8AAE8AAGQAAAJWUDhMDwAAAC+fwBMQBxD9jwIGIqL/AQBBTk1GKAAAAAAAAAAAAJ8AAE8AAGQAAABWUDhMDwAAAC+fwBMABxDR//4HIqL/AQA="
            )
        }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 160,
                pixelsHigh: 80,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 640,
                bitsPerPixel: 32
            ), let bytes = bitmap.bitmapData
        else { return nil }
        for y in 0..<80 {
            for x in 0..<160 {
                let offset = y * 640 + x * 4
                bytes[offset] = UInt8(x)
                bytes[offset + 1] = UInt8(100 + y)
                bytes[offset + 2] = 220
                bytes[offset + 3] = x < 80 ? 128 : 255
            }
        }
        guard let image = bitmap.cgImage else { return nil }
        let output = NSMutableData()
        let frames = type == "com.compuserve.gif" ? 2 : 1
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, frames, nil) else {
            return nil
        }
        for _ in 0..<frames { CGImageDestinationAddImage(destination, image, nil) }
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
        let imageFileOnly = NSPasteboardItem()
        imageFileOnly.setString("file:///nonexistent/image.png", forType: .fileURL)
        board.clearContents()
        guard board.writeObjects([imageFileOnly]), client.read() == .excluded else { return false }
        guard client.write("selected history entry"), client.read() == .text("selected history entry") else {
            return false
        }
        for identifier in ClipboardImage.supportedTypes {
            guard let data = sampleImageData(type: identifier) else { return false }
            let type = NSPasteboard.PasteboardType(identifier)
            let item = NSPasteboardItem()
            item.setData(data, forType: type)
            item.setString("https://example.com/image", forType: .URL)
            item.setString("https://example.com/image", forType: .string)
            // Multiple representations form one entry; animation originals outrank still fallbacks.
            if type == .png, let tiff = sampleImageData(type: "public.tiff") { item.setData(tiff, forType: .tiff) }
            if ["com.compuserve.gif", "org.webmproject.webp"].contains(identifier),
                let png = sampleImageData()
            {
                item.setData(png, forType: .png)
            }
            board.clearContents()
            guard board.writeObjects([item]), case .image(let candidate) = client.read(),
                candidate.type == type.rawValue, candidate.data == data, candidate.sourceHost == "example.com",
                let image = try? ImageProcessor.prepare(candidate), image.width == 160, image.height == 80,
                client.writeImage(image), case .image(let restored) = client.read(), restored.data == data,
                restored.type == type.rawValue,
                let source = CGImageSourceCreateWithData(restored.data as CFData, nil),
                let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                decoded.width == 160, decoded.height == 80,
                CGImageSourceGetCount(source)
                    == (["com.compuserve.gif", "org.webmproject.webp"].contains(identifier) ? 2 : 1),
                !["public.png", "public.tiff"].contains(identifier) || decoded.alphaInfo != .none
            else { return false }
            let sensitiveImage = NSPasteboardItem()
            sensitiveImage.setData(data, forType: type)
            sensitiveImage.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            board.clearContents()
            guard board.writeObjects([sensitiveImage]), client.read() == .excluded else { return false }
            let fileImage = NSPasteboardItem()
            // Match the WeChat/Qt image + temporary-file-reference combination.
            // Deliberately point to a nonexistent file: capture must use only the supplied image bytes.
            fileImage.setString("file:///nonexistent/stampede-selftest/image", forType: .fileURL)
            fileImage.setString(
                "file:///nonexistent/stampede-selftest/image",
                forType: .init("com.trolltech.anymime.text--uri-list")
            )
            fileImage.setData(Data(), forType: .init("com.trolltech.anymime.application--x-qt-image"))
            fileImage.setData(data, forType: type)
            board.clearContents()
            guard board.writeObjects([fileImage]), case .image(let fileCandidate) = client.read(),
                fileCandidate.type == identifier, fileCandidate.data == data
            else { return false }
            let concealedFileImage = NSPasteboardItem()
            concealedFileImage.setString("file:///nonexistent/stampede-selftest/image", forType: .fileURL)
            concealedFileImage.setData(data, forType: type)
            concealedFileImage.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
            board.clearContents()
            guard board.writeObjects([concealedFileImage]), client.read() == .excluded else { return false }
        }
        let revision = client.clear()
        return revision == client.revision && client.read() == .excluded
    }
}
