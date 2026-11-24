import SwiftUI

struct MarkdownView: View {
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .tracking(level == 1 ? -0.3 : -0.1)
                .padding(.top, level == 1 ? 8 : 4)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)
                .lineSpacing(3)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        inlineText(item)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                        inlineText(item)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 3)

                inlineText(text)
                    .foregroundStyle(.secondary)
            }

        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(
                .quaternary.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

        case .table(let headers, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                            inlineText(header)
                                .font(.callout.weight(.semibold))
                        }
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(headers.indices), id: \.self) { index in
                                inlineText(index < row.count ? row[index] : "")
                                    .font(.callout)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(
                .quaternary.opacity(0.55),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }

    private func inlineText(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )

        if let attributed = try? AttributedString(
            markdown: value,
            options: options
        ) {
            return Text(attributed)
        }

        return Text(value)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:
            return .title.bold()
        case 2:
            return .title2.bold()
        case 3:
            return .title3.bold()
        default:
            return .headline
        }
    }
}

private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case bullets(items: [String])
    case numbered(items: [String])
    case quote(text: String)
    case code(text: String)
    case table(headers: [String], rows: [[String]])
    case divider

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                index += 1
                var codeLines: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count {
                    index += 1
                }
                blocks.append(.code(text: codeLines.joined(separator: "\n")))
                continue
            }

            let headingLevel = trimmed.prefix { $0 == "#" }.count
            if headingLevel > 0 {
                let text = trimmed
                    .dropFirst(headingLevel)
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: headingLevel, text: text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if trimmed.contains("|"),
               index + 1 < lines.count,
               isTableSeparator(lines[index + 1]) {
                let headers = splitTableRow(trimmed)
                index += 2
                var rows: [[String]] = []

                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else {
                        break
                    }
                    rows.append(splitTableRow(rowLine))
                    index += 1
                }

                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if isBullet(trimmed) {
                var items: [String] = []
                while index < lines.count {
                    let itemLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBullet(itemLine) else {
                        break
                    }
                    items.append(String(itemLine.dropFirst(2)))
                    index += 1
                }
                blocks.append(.bullets(items: items))
                continue
            }

            if numberedContent(trimmed) != nil {
                var items: [String] = []
                while index < lines.count {
                    let itemLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let content = numberedContent(itemLine) else {
                        break
                    }
                    items.append(content)
                    index += 1
                }
                blocks.append(.numbered(items: items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else {
                        break
                    }
                    quoteLines.append(
                        String(quoteLine.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                continue
            }

            var paragraphLines = [line]
            index += 1

            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty
                    || nextTrimmed.hasPrefix("#")
                    || nextTrimmed.hasPrefix("```")
                    || isBullet(nextTrimmed)
                    || numberedContent(nextTrimmed) != nil
                    || nextTrimmed.hasPrefix(">")
                    || isDivider(nextTrimmed) {
                    break
                }
                paragraphLines.append(next)
                index += 1
            }

            blocks.append(
                .paragraph(text: paragraphLines.joined(separator: "\n"))
            )
        }

        return blocks
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ")
    }

    private static func numberedContent(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else {
            return nil
        }

        let prefix = line[..<dotIndex]
        guard !prefix.isEmpty,
              prefix.allSatisfy(\.isNumber),
              line.index(after: dotIndex) < line.endIndex else {
            return nil
        }

        let contentStart = line.index(after: dotIndex)
        guard line[contentStart] == " " else {
            return nil
        }

        return String(line[line.index(after: contentStart)...])
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else {
            return false
        }

        let cells = trimmed.split(separator: "|")
        return !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty
                && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") {
            value.removeFirst()
        }
        if value.hasSuffix("|") {
            value.removeLast()
        }

        return value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
