import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct IconGenerator {
    static func main() throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                // Resize the supplied artwork without redrawing, cropping, or removing its background.
                guard
                    let image = CGImageSourceCreateThumbnailAtIndex(
                        source,
                        0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: size * scale,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                        ] as CFDictionary
                    )
                else { throw CocoaError(.fileReadCorruptFile) }
                let url = output.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png")
                guard
                    let destination = CGImageDestinationCreateWithURL(
                        url as CFURL,
                        UTType.png.identifier as CFString,
                        1,
                        nil
                    )
                else {
                    throw CocoaError(.fileWriteUnknown)
                }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}
