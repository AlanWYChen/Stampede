import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoded originals live in encrypted blobs. Data and thumbnails exist only in memory.
public struct ClipboardImage: Codable, Equatable, Sendable {
    public let blobID: UUID
    public let type: String
    public let byteCount: Int
    public let digest: Data
    public let width: Int
    public let height: Int
    public var sourceApp: String?
    public var sourceHost: String?
    public var data: Data?
    public var thumbnail: Data?

    private enum CodingKeys: String, CodingKey {
        case blobID, type, byteCount, digest, width, height, sourceApp, sourceHost
    }

    /// Prefer lossless clipboard representations, then the original compressed photo formats.
    public static let supportedTypes = [
        UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
    ]

    public var isValid: Bool {
        Self.supportedTypes.contains(type) && byteCount > 0 && byteCount <= Self.maximumBytes && width > 0 && height > 0
            && width <= 8192 && height <= 8192 && width * height <= 16_000_000 && digest.count == 32
            && (data == nil || data!.count == byteCount) && (sourceApp?.utf8.count ?? 0) <= 256
            && (sourceHost?.utf8.count ?? 0) <= 256
    }

    public static let maximumBytes = 20 * 1_048_576

    public init(
        type: String,
        data: Data,
        width: Int,
        height: Int,
        thumbnail: Data? = nil,
        sourceApp: String? = nil,
        sourceHost: String? = nil
    ) {
        blobID = UUID()
        self.type = type
        byteCount = data.count
        digest = Data(SHA256.hash(data: data))
        self.data = data
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
        self.sourceApp = sourceApp
        self.sourceHost = sourceHost
    }

    public var label: String {
        func compact(_ value: String?, limit: Int, keepEnd: Bool = false) -> String? {
            guard let value else { return nil }
            let clean = value.map {
                $0.isWhitespace || $0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
                    ? " " : String($0)
            }.joined()
            if keepEnd, clean.count > limit { return "…" + String(clean.suffix(limit)) }
            return String(clean.prefix(limit)) + (clean.count > limit ? "…" : "")
        }
        // Hosts keep their registrable end so a look-alike prefix cannot push the real domain out of view.
        let origin = [compact(sourceApp, limit: 24), compact(sourceHost, limit: 40, keepEnd: true)].compactMap { $0 }
            .joined(separator: " · ")
        return "Image · \(width) × \(height)" + (origin.isEmpty ? "" : " · \(origin)")
    }

    /// An HTTP(S) URL's host as lowercase `[a-z0-9.-]` (IDNs stay punycode), else nil; long hosts keep their
    /// registrable end.
    public static func sanitizedHost(fromURL string: String?) -> String? {
        guard let url = string.flatMap(URL.init(string:)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            let host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty,
            host.unicodeScalars.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.-".unicodeScalars.contains($0) })
        else { return nil }
        return String(host.suffix(200))
    }

    public var authenticatedContext: Data { Data("\(blobID.uuidString):\(type)".utf8) }
}

public struct ImageCandidate: Equatable, Sendable {
    public let type: String
    public let data: Data
    public let sourceApp: String?
    public let sourceHost: String?

    public init(type: String, data: Data, sourceApp: String? = nil, sourceHost: String? = nil) {
        self.type = type
        self.data = data
        self.sourceApp = sourceApp
        self.sourceHost = sourceHost
    }
}

public enum ImageProcessingError: LocalizedError {
    case tooLarge, invalid

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Image was too large to save (20 MiB, 16 megapixels, or 8,192 pixels per edge)."
        case .invalid:
            "Image could not be saved. Only valid, single-frame PNG, TIFF, JPEG, and HEIC images are supported."
        }
    }
}

/// Image I/O parsing and downsampling run on a serial actor, never in menu tracking.
public actor ImageProcessor {
    public init() {}

    public func process(_ candidate: ImageCandidate) throws -> ClipboardImage {
        try Self.prepare(candidate)
    }

    public static func prepare(_ candidate: ImageCandidate) throws -> ClipboardImage {
        guard candidate.data.count <= ClipboardImage.maximumBytes else { throw ImageProcessingError.tooLarge }
        guard ClipboardImage.supportedTypes.contains(candidate.type),
            let source = CGImageSourceCreateWithData(
                candidate.data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetType(source) as String? == candidate.type,
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let h = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else { throw ImageProcessingError.invalid }
        let width = w.intValue
        let height = h.intValue
        guard width > 0, height > 0, width <= 8192, height <= 8192,
            width * height <= 16_000_000
        else { throw ImageProcessingError.tooLarge }
        guard (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8 <= 16,
            (properties[kCGImagePropertyColorModel] as? String) != "CMYK",
            let thumb = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 128,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        else { throw ImageProcessingError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ImageProcessingError.invalid
        }
        CGImageDestinationAddImage(destination, thumb, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.invalid }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return ClipboardImage(
            type: candidate.type,
            data: candidate.data,
            width: (5...8).contains(orientation) ? height : width,
            height: (5...8).contains(orientation) ? width : height,
            thumbnail: output as Data,
            sourceApp: candidate.sourceApp,
            sourceHost: candidate.sourceHost
        )
    }
}
