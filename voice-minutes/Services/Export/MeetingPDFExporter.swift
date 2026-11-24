import CoreGraphics
import CoreText
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders the generated Markdown minutes into a paginated PDF.
enum MeetingPDFExporter {
    static func makePDF(
        title: String,
        metadata: String,
        markdown: String
    ) throws -> Data {
        let attributedText = makeAttributedText(
            title: title,
            metadata: metadata,
            markdown: markdown
        )
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw PDFExportError.cannotCreateConsumer
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw PDFExportError.cannotCreateContext
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let contentRect = mediaBox.insetBy(dx: 48, dy: 48)
        let totalLength = attributedText.length
        var location = 0

        while location < totalLength {
            context.beginPDFPage(nil)

            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else {
                context.endPDFPage()
                break
            }

            location = visibleRange.location + visibleRange.length
            context.endPDFPage()
        }

        context.closePDF()
        return data as Data
    }

    private static func makeAttributedText(
        title: String,
        metadata: String,
        markdown: String
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()

        output.append(
            styled(
                title + "\n",
                fontName: "PingFangSC-Semibold",
                fontSize: 22,
                color: CGColor(gray: 0.08, alpha: 1),
                paragraphSpacing: 10
            )
        )
        output.append(
            styled(
                metadata + "\n",
                fontName: "PingFangSC-Regular",
                fontSize: 9,
                color: CGColor(gray: 0.45, alpha: 1),
                paragraphSpacing: 14
            )
        )

        var insideCodeBlock = false

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("```") {
                insideCodeBlock.toggle()
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isTableSeparator(trimmed) {
                continue
            }

            if trimmed.isEmpty {
                output.append(
                    styled(
                        "\n",
                        fontName: "PingFangSC-Regular",
                        fontSize: 11,
                        color: CGColor(gray: 0.2, alpha: 1),
                        paragraphSpacing: 4
                    )
                )
                continue
            }

            let headingLevel = trimmed.prefix { $0 == "#" }.count
            if headingLevel > 0 {
                let heading = trimmed
                    .dropFirst(headingLevel)
                    .trimmingCharacters(in: .whitespaces)
                let fontSize: CGFloat = headingLevel == 1 ? 18 : (headingLevel == 2 ? 14 : 12)
                output.append(
                    styled(
                        heading + "\n",
                        fontName: "PingFangSC-Semibold",
                        fontSize: fontSize,
                        color: CGColor(gray: 0.1, alpha: 1),
                        paragraphSpacing: 6
                    )
                )
                continue
            }

            let text = plainText(from: line)
            output.append(
                styled(
                    text + "\n",
                    fontName: insideCodeBlock
                        ? "Menlo-Regular"
                        : "PingFangSC-Regular",
                    fontSize: insideCodeBlock ? 9 : 11,
                    color: CGColor(gray: 0.18, alpha: 1),
                    paragraphSpacing: insideCodeBlock ? 0 : 3
                )
            )
        }

        return output
    }

    private static func styled(
        _ text: String,
        fontName: String,
        fontSize: CGFloat,
        color: CGColor,
        paragraphSpacing: CGFloat
    ) -> NSAttributedString {
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        paragraphStyle.paragraphSpacing = paragraphSpacing

        return NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    private static func plainText(from line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespaces)

        if result.hasPrefix(">") {
            result = "  " + result.dropFirst()
        }

        if result.hasPrefix("- ") || result.hasPrefix("* ") {
            result = "• " + result.dropFirst(2)
        }

        if result.hasPrefix("|"), result.hasSuffix("|") {
            result = result
                .dropFirst()
                .dropLast()
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "  |  ")
        }

        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else {
            return false
        }

        let cells = line.split(separator: "|")
        return !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }
}

enum PDFExportError: LocalizedError {
    case cannotCreateConsumer
    case cannotCreateContext

    var errorDescription: String? {
        let language = InterfaceLanguage.current

        switch self {
        case .cannotCreateConsumer:
            return language.text("export.error.cannotCreateOutput")
        case .cannotCreateContext:
            return language.text("export.error.cannotCreateContext")
        }
    }
}
