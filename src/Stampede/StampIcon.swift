import AppKit

/// Shared vector artwork inspired by the supplied stacked-clipboard reference.
@MainActor enum StampIcon {
    private static func rounded(_ rect: NSRect, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    private static func drawClipboard(in rect: NSRect, detailed: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 100, yBy: rect.height / 100)
        transform.concat()
        NSColor.black.setStroke()
        NSColor.black.setFill()

        func stroke(_ path: NSBezierPath, width: CGFloat = 4.4) {
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }

        // Only the exposed edges of the rear sheets are drawn, so the menu template stays transparent.
        if detailed {
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 26, y: 27))
            back.line(to: NSPoint(x: 24, y: 27))
            back.curve(
                to: NSPoint(x: 21, y: 30),
                controlPoint1: NSPoint(x: 22, y: 27),
                controlPoint2: NSPoint(x: 21, y: 28)
            )
            back.line(to: NSPoint(x: 21, y: 61))
            back.curve(
                to: NSPoint(x: 24, y: 64),
                controlPoint1: NSPoint(x: 21, y: 63),
                controlPoint2: NSPoint(x: 22, y: 64)
            )
            back.line(to: NSPoint(x: 26, y: 64))
            stroke(back, width: 4)
        }
        let middle = NSBezierPath()
        middle.move(to: NSPoint(x: 34, y: 23))
        middle.line(to: NSPoint(x: 31, y: 23))
        middle.curve(
            to: NSPoint(x: 27, y: 27),
            controlPoint1: NSPoint(x: 28.5, y: 23),
            controlPoint2: NSPoint(x: 27, y: 24.5)
        )
        middle.line(to: NSPoint(x: 27, y: 66))
        middle.curve(
            to: NSPoint(x: 31, y: 70),
            controlPoint1: NSPoint(x: 27, y: 68.5),
            controlPoint2: NSPoint(x: 28.5, y: 70)
        )
        middle.line(to: NSPoint(x: 34, y: 70))
        stroke(middle)

        let board = NSBezierPath()
        board.move(to: NSPoint(x: 43, y: 75))
        board.line(to: NSPoint(x: 40, y: 75))
        board.curve(
            to: NSPoint(x: 36, y: 71),
            controlPoint1: NSPoint(x: 37.5, y: 75),
            controlPoint2: NSPoint(x: 36, y: 73.5)
        )
        board.line(to: NSPoint(x: 36, y: 25))
        board.curve(
            to: NSPoint(x: 40, y: 21),
            controlPoint1: NSPoint(x: 36, y: 22.5),
            controlPoint2: NSPoint(x: 37.5, y: 21)
        )
        board.line(to: NSPoint(x: 75, y: 21))
        board.curve(
            to: NSPoint(x: 79, y: 25),
            controlPoint1: NSPoint(x: 77.5, y: 21),
            controlPoint2: NSPoint(x: 79, y: 22.5)
        )
        board.line(to: NSPoint(x: 79, y: 69))
        board.curve(
            to: NSPoint(x: 75, y: 73),
            controlPoint1: NSPoint(x: 79, y: 71.5),
            controlPoint2: NSPoint(x: 77.5, y: 73)
        )
        board.line(to: NSPoint(x: 70, y: 73))
        stroke(board)

        let clip = NSBezierPath()
        clip.move(to: NSPoint(x: 48, y: 67))
        clip.line(to: NSPoint(x: 67, y: 67))
        clip.curve(
            to: NSPoint(x: 70, y: 70),
            controlPoint1: NSPoint(x: 69, y: 67),
            controlPoint2: NSPoint(x: 70, y: 68)
        )
        clip.line(to: NSPoint(x: 70, y: 73))
        clip.curve(
            to: NSPoint(x: 67, y: 76),
            controlPoint1: NSPoint(x: 70, y: 75),
            controlPoint2: NSPoint(x: 69, y: 76)
        )
        clip.line(to: NSPoint(x: 64, y: 76))
        clip.curve(
            to: NSPoint(x: 58, y: 82),
            controlPoint1: NSPoint(x: 64, y: 79.5),
            controlPoint2: NSPoint(x: 61.5, y: 82)
        )
        clip.curve(
            to: NSPoint(x: 52, y: 76),
            controlPoint1: NSPoint(x: 54.5, y: 82),
            controlPoint2: NSPoint(x: 52, y: 79.5)
        )
        clip.line(to: NSPoint(x: 48, y: 76))
        clip.curve(
            to: NSPoint(x: 45, y: 73),
            controlPoint1: NSPoint(x: 46, y: 76),
            controlPoint2: NSPoint(x: 45, y: 75)
        )
        clip.line(to: NSPoint(x: 45, y: 70))
        clip.curve(
            to: NSPoint(x: 48, y: 67),
            controlPoint1: NSPoint(x: 45, y: 68),
            controlPoint2: NSPoint(x: 46, y: 67)
        )
        clip.close()
        clip.append(NSBezierPath(ovalIn: NSRect(x: 55.7, y: 73.7, width: 4.6, height: 4.6)))
        clip.windingRule = .evenOdd
        clip.fill()

        let lines: [(CGFloat, CGFloat)] = detailed ? [(56.5, 70), (46.5, 70), (36.5, 66)] : [(54, 69), (40, 66)]
        for (y, end) in lines {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 46, y: y))
            line.line(to: NSPoint(x: end, y: y))
            stroke(line)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        drawClipboard(in: NSRect(x: -3, y: -3, width: 26, height: 26), detailed: false)
        image.unlockFocus()
        // The menu bar automatically adapts black pixels to light/dark appearances.
        image.isTemplate = true
        return image
    }

    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let p = CGFloat(pixels)
        let tile = NSRect(x: p * 0.045, y: p * 0.045, width: p * 0.91, height: p * 0.91)
        rounded(tile, radius: p * 0.205, color: .white)
        drawClipboard(in: NSRect(x: 0, y: 0, width: p, height: p), detailed: pixels >= 64)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
