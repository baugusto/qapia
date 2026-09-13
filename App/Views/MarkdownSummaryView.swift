import QapiaCore
import SwiftUI

struct MarkdownSummaryView: View {
    let markdown: String

    private var blocks: [SummaryMarkdownBlock] {
        SummaryMarkdownParser.parse(
            MarkdownPlainTextFormatter.presentationMarkdown(from: markdown)
        )
    }

    var body: some View {
        // Meeting summaries contain a small, finite number of semantic
        // blocks. A regular stack avoids LazyVStack placement invalidations
        // while the enclosing document scroll view is being measured.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func blockView(_ block: SummaryMarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level, text):
            InlineMarkdownText(
                source: text,
                font: .system(
                    size: level == 1 ? 19 : level == 2 ? 17 : 15,
                    weight: level <= 2 ? .bold : .semibold
                ),
                color: .primary,
                lineSpacing: 3
            )
            .padding(.top, block.isFirst ? 0 : level == 1 ? 8 : 4)

        case let .paragraph(text):
            InlineMarkdownText(
                source: text,
                font: .system(size: 13),
                color: .secondary,
                lineSpacing: 5
            )

        case let .unorderedItem(text, level):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(level == 0 ? QapiaColors.accent : Color.secondary.opacity(0.55))
                    .frame(width: level == 0 ? 5 : 4, height: level == 0 ? 5 : 4)
                InlineMarkdownText(
                    source: text,
                    font: .system(size: 13),
                    color: .secondary,
                    lineSpacing: 4
                )
            }
            .padding(.leading, CGFloat(level) * 18)

        case let .orderedItem(number, text, level):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(QapiaColors.accent)
                    .frame(minWidth: 20, alignment: .trailing)
                InlineMarkdownText(
                    source: text,
                    font: .system(size: 13),
                    color: .secondary,
                    lineSpacing: 4
                )
            }
            .padding(.leading, CGFloat(level) * 18)

        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(QapiaColors.accent.opacity(0.65))
                    .frame(width: 3)
                InlineMarkdownText(
                    source: text,
                    font: .system(size: 13).italic(),
                    color: .secondary,
                    lineSpacing: 4
                )
            }
            .padding(.vertical, 2)

        case let .code(text):
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QapiaColors.surfaceHover)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .divider:
            Divider()
                .padding(.vertical, 2)
        }
    }
}

private struct InlineMarkdownText: View {
    let source: String
    let font: Font
    let color: Color
    let lineSpacing: CGFloat

    private var attributedText: AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    var body: some View {
        Text(attributedText)
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SummaryMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedItem(text: String, level: Int)
        case orderedItem(number: Int, text: String, level: Int)
        case quote(String)
        case code(String)
        case divider
    }

    let id: Int
    let kind: Kind
    let isFirst: Bool
}

enum SummaryMarkdownParser {
    static func parse(_ markdown: String) -> [SummaryMarkdownBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var kinds: [SummaryMarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { kinds.append(.paragraph(text)) }
            paragraph.removeAll()
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            kinds.append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                if isInsideCodeFence { flushCode() }
                isInsideCodeFence.toggle()
                continue
            }

            if isInsideCodeFence {
                codeLines.append(rawLine)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                kinds.append(.divider)
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                kinds.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let item = unorderedItem(from: rawLine) {
                flushParagraph()
                kinds.append(.unorderedItem(text: item.text, level: item.level))
                continue
            }

            if let item = orderedItem(from: rawLine) {
                flushParagraph()
                kinds.append(.orderedItem(number: item.number, text: item.text, level: item.level))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                kinds.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        flushCode()

        return kinds.enumerated().map { index, kind in
            SummaryMarkdownBlock(id: index, kind: kind, isFirst: index == 0)
        }
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        let text = line.dropFirst(level)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\s+#{1,6}\\s*$", with: "", options: .regularExpression)
        return (level, text)
    }

    private static func unorderedItem(from line: String) -> (text: String, level: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { value, character in
            value + (character == "\t" ? 4 : 1)
        }
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard content.count >= 2,
              let marker = content.first,
              ["-", "+", "*"].contains(marker),
              content.dropFirst().first == " " else { return nil }
        return (String(content.dropFirst(2)), min(leadingSpaces / 2, 3))
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String, level: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { value, character in
            value + (character == "\t" ? 4 : 1)
        }
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = content.prefix(while: { $0.isNumber })
        guard let number = Int(digits), !digits.isEmpty else { return nil }
        let suffix = content.dropFirst(digits.count)
        guard suffix.count >= 2,
              suffix.first == "." || suffix.first == ")",
              suffix.dropFirst().first == " " else { return nil }
        return (number, String(suffix.dropFirst(2)), min(leadingSpaces / 2, 3))
    }
}
