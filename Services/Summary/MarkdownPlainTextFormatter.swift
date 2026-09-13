import Foundation

public enum MarkdownPlainTextFormatter {
    /// Repairs punctuation-only ASR artefacts for display and copy without
    /// mutating the persisted Markdown or the summary-generation pipeline.
    public static func presentationMarkdown(from markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var isInsideCodeFence = false

        return normalized.components(separatedBy: "\n").map { rawLine in
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
                return rawLine
            }
            guard !isInsideCodeFence else { return rawLine }
            return cleanRedundantLeadingSpeechMarker(rawLine)
        }.joined(separator: "\n")
    }

    public static func plainText(from markdown: String) -> String {
        let normalized = presentationMarkdown(from: markdown)

        var output: [String] = []
        var isInsideCodeFence = false
        var previousLineWasBlank = false

        for rawLine in normalized.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
                continue
            }

            var line = rawLine
            if !isInsideCodeFence {
                line = cleanBlockPrefix(line)
                line = cleanInlineMarkup(line)
            }
            line = line.replacingOccurrences(
                of: "[ \\t]+$",
                with: "",
                options: .regularExpression
            )

            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !previousLineWasBlank, !output.isEmpty {
                    output.append("")
                }
                previousLineWasBlank = true
            } else {
                output.append(line)
                previousLineWasBlank = false
            }
        }

        return output
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanBlockPrefix(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "^\\s{0,3}#{1,6}\\s+",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "^\\s{0,3}>\\s?",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "^(\\s*)[-+*]\\s+\\[[ xX]\\]\\s+",
                with: "$1• ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "^(\\s*)[-+*]\\s+",
                with: "$1• ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "^(\\s*)([0-9]+)[.)]\\s+",
                with: "$1$2. ",
                options: .regularExpression
            )
    }

    private static func cleanInlineMarkup(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: "!\\[([^\\]]*)\\]\\([^\\)]*\\)",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\[([^\\]]+)\\]\\([^\\)]+\\)",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "`([^`]+)`",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(\\*\\*|__)(.+?)\\1",
                with: "$2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "~~(.+?)~~",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?<![[:alnum:]])_([^_\\n]+)_(?![[:alnum:]])",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\s+#{1,6}\\s*$",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "\\\\([\\\\`*{}\\[\\]()#+\\-.!_>])",
                with: "$1",
                options: .regularExpression
            )
    }

    private static func cleanRedundantLeadingSpeechMarker(_ value: String) -> String {
        let unorderedPrefix = "^[ \\t]*[-+*][ \\t]+"
        if value.range(of: unorderedPrefix, options: .regularExpression) != nil {
            return value.replacingOccurrences(
                of: "^([ \\t]*[-+*][ \\t]+)[-–—][ \\t]*(?=[\\p{Lu}\\\"“'‘«(])",
                with: "$1",
                options: .regularExpression
            )
        }

        let orderedPrefix = "^[ \\t]*[0-9]+[.)][ \\t]+"
        if value.range(of: orderedPrefix, options: .regularExpression) != nil {
            return value.replacingOccurrences(
                of: "^([ \\t]*[0-9]+[.)][ \\t]+)[-–—][ \\t]*(?=[\\p{Lu}\\\"“'‘«(])",
                with: "$1",
                options: .regularExpression
            )
        }

        return value.replacingOccurrences(
            of: "^([ \\t]*)[-–—][ \\t]*(?=[\\p{Lu}\\\"“'‘«(])",
            with: "$1",
            options: .regularExpression
        )
    }
}
