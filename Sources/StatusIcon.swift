import AppKit

/// Everything the status item draws: the mark and the values, inside one rounded border.
///
/// The whole thing is rendered into a single `NSImage` instead of being handed to the
/// button as an `attributedTitle`. Attributed strings cannot draw a rounded border around
/// a run of text (`.backgroundColor` is a square block), and enclosing the values in one
/// capsule is the point: it reads as a single item rather than as loose numbers sitting
/// between the other menu bar icons. Drawing it ourselves also keeps the spacing exact.
enum StatusIcon {
    /// One value shown in the menu bar: a percentage, or the agent count with its glyph.
    ///
    /// `Equatable` so `AppDelegate` can skip redrawing when nothing visible changed: the
    /// model publishes a 1 Hz clock and would otherwise rebuild this image every second.
    struct Segment: Equatable {
        var text: String
        var severity: Severity
        /// SF Symbol drawn before the text, used by the agents value.
        var symbol: String?
    }

    private static let height: CGFloat = 18
    private static let capsuleHeight: CGFloat = 16
    private static let markSize: CGFloat = 12
    /// Space between the capsule border and its contents.
    private static let padding: CGFloat = 5
    private static let markGap: CGFloat = 5
    /// Space on each side of the hairline that separates two values.
    private static let dividerGap: CGFloat = 5
    private static let symbolSize: CGFloat = 9
    private static let symbolGap: CGFloat = 3

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// Status item image for `segments`.
    ///
    /// When nothing is above its threshold the image is a template, so the menu bar tints
    /// it exactly like a system icon and light/dark are handled for free. As soon as one
    /// value goes orange or red the image has to carry its own colors, and it is then
    /// drawn against `appearance` so the neutral parts still match the menu bar.
    static func statusImage(segments: [Segment], appearance: NSAppearance?) -> NSImage {
        let worst = segments.map(\.severity).max(by: { $0.rank < $1.rank }) ?? .normal
        let isTemplate = worst == .normal
        let widths = segments.map { valueWidth(for: $0) }
        // With nothing to enclose ("Icon only") the capsule is just a box around the
        // mark, so it is dropped and the mark stands alone like any other menu bar icon.
        let hasValues = !segments.isEmpty
        let inner = markSize + (hasValues ? markGap : 0)
            + widths.reduce(0, +)
            + (dividerGap * 2 + 1) * CGFloat(max(widths.count - 1, 0))
        let total = ceil(inner + (hasValues ? padding * 2 : 0))

        let image = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            let draw = {
                let neutral = isTemplate ? NSColor.black : NSColor.controlTextColor
                // One capsule around everything. It takes the worst severity, so the
                // group itself turns orange or red without the values shouting twice.
                let capsule = NSRect(x: 0.5,
                                     y: (height - capsuleHeight) / 2 + 0.5,
                                     width: total - 1,
                                     height: capsuleHeight - 1)
                if hasValues {
                    let border = NSBezierPath(roundedRect: capsule,
                                              xRadius: capsule.height / 2,
                                              yRadius: capsule.height / 2)
                    border.lineWidth = 1
                    (isTemplate ? NSColor.black : worst.nsColor).withAlphaComponent(0.5).setStroke()
                    border.stroke()
                }

                drawMark(in: NSRect(x: hasValues ? padding : 0,
                                    y: (height - markSize) / 2,
                                    width: markSize,
                                    height: markSize),
                         color: neutral)

                var x = (hasValues ? padding : 0) + markSize + markGap
                for (index, segment) in segments.enumerated() {
                    if index > 0 {
                        let line = NSRect(x: x + dividerGap, y: capsule.minY + 3, width: 1,
                                          height: capsule.height - 6)
                        neutral.withAlphaComponent(0.3).setFill()
                        line.fill()
                        x += dividerGap * 2 + 1
                    }
                    let color = isTemplate ? NSColor.black : segment.severity.nsColor
                    drawValue(segment, at: x, color: color)
                    x += widths[index]
                }
            }
            if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
            return true
        }
        image.isTemplate = isTemplate
        // VoiceOver reads the image, so the values have to be in the description or the
        // status item announces itself without saying anything useful.
        let spoken = segments.map { $0.symbol == nil ? $0.text : "\($0.text) agents" }
        image.accessibilityDescription = (["Claude Code usage"] + spoken).joined(separator: ", ")
        return image
    }

    // MARK: - Values

    private static func valueWidth(for segment: Segment) -> CGFloat {
        var width = textSize(segment.text).width
        // Measure the glyph rather than assume it is square: SF Symbols are not, and a
        // guess here shifts everything drawn after it.
        if let symbol = segment.symbol, let glyph = glyph(for: symbol) {
            width += glyph.size.width + symbolGap
        }
        return ceil(width)
    }

    private static func glyph(for symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolSize,
                                                                 weight: .semibold))
        image?.isTemplate = true
        return image
    }

    private static func textSize(_ text: String) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private static func drawValue(_ segment: Segment, at x: CGFloat, color: NSColor) {
        var textX = x
        if let symbol = segment.symbol, let image = glyph(for: symbol) {
            let tinted = tint(image, with: color)
            tinted.draw(in: NSRect(x: textX,
                                   y: height / 2 - tinted.size.height / 2,
                                   width: tinted.size.width,
                                   height: tinted.size.height))
            textX += tinted.size.width + symbolGap
        }

        let size = textSize(segment.text)
        (segment.text as NSString).draw(at: NSPoint(x: textX, y: height / 2 - size.height / 2),
                                        withAttributes: [.font: font, .foregroundColor: color])
    }

    /// Template symbols ignore `foregroundColor` when drawn directly, so paint them.
    private static func tint(_ image: NSImage, with color: NSColor) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    // MARK: - Mark

    /// The leading mark: `Resources/claude-mark.png`, the white Claude silhouette. White
    /// plus alpha on purpose - as a template only the alpha is read, so one asset covers
    /// both light and dark menu bars, and `tint` recolors it when the image cannot be a
    /// template. The logo is Anthropic's trademark and the README says so; `build.sh`
    /// copies it in before `codesign` so the seal covers it.
    private static let markImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "claude-mark", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    /// Draws the bundled mark, falling back to a hand-drawn burst if the resource is
    /// missing (a stripped-down bundle should still show something).
    private static func drawMark(in rect: NSRect, color: NSColor) {
        guard let markImage else {
            color.setFill()
            drawFallbackMark(in: rect)
            return
        }
        tint(markImage, with: color).draw(in: rect)
    }

    /// Twelve tapered spokes, alternating long and short, around a solid core.
    ///
    /// Each spoke is filled on its own: merged into one path their winding directions
    /// cancel where they overlap and punch a hole through the middle.
    private static func drawFallbackMark(in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let spokes = 12
        let core = rect.width * 0.16
        let long = rect.width * 0.5
        let short = rect.width * 0.35
        let halfWidth = rect.width * 0.085

        for i in 0..<spokes {
            let angle = (Double(i) / Double(spokes)) * 2 * .pi + .pi / 2
            let outer = i.isMultiple(of: 2) ? long : short
            let dx = cos(angle), dy = sin(angle)
            // Perpendicular offset gives the spoke its width at the base.
            let px = -dy * halfWidth, py = dx * halfWidth

            let spoke = NSBezierPath()
            spoke.move(to: NSPoint(x: center.x + px, y: center.y + py))
            spoke.line(to: NSPoint(x: center.x + dx * outer, y: center.y + dy * outer))
            spoke.line(to: NSPoint(x: center.x - px, y: center.y - py))
            spoke.close()
            spoke.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: center.x - core,
                                    y: center.y - core,
                                    width: core * 2,
                                    height: core * 2)).fill()
    }
}
