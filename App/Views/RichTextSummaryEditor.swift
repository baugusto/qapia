import AppKit
import SwiftUI

private extension NSAttributedString.Key {
    static let qapiaBold = NSAttributedString.Key("br.com.qapia.summary.bold")
    static let qapiaItalic = NSAttributedString.Key("br.com.qapia.summary.italic")
    static let qapiaHeadingLevel = NSAttributedString.Key("br.com.qapia.summary.heading-level")
}

@MainActor
final class SummaryRichTextController: ObservableObject {
    fileprivate weak var textView: NSTextView?

    func setParagraphStyle() {
        setHeadingLevel(nil)
    }

    func setHeadingStyle() {
        setHeadingLevel(2)
    }

    func toggleBold() {
        toggleInlineAttribute(.qapiaBold)
    }

    func toggleItalic() {
        toggleInlineAttribute(.qapiaItalic)
    }

    func toggleBulletedList() {
        toggleList(prefix: { _ in "• " }, matches: { $0.hasPrefix("• ") })
    }

    func toggleNumberedList() {
        toggleList(
            prefix: { "\($0 + 1). " },
            matches: { $0.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil }
        )
    }

    private func toggleInlineAttribute(_ key: NSAttributedString.Key) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            if (attributes[key] as? Bool) == true {
                attributes.removeValue(forKey: key)
            } else {
                attributes[key] = true
            }
            textView.typingAttributes = attributes
            applyTypingFont(to: textView)
            return
        }

        let storage = textView.textStorage!
        var everyCharacterHasAttribute = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if (value as? Bool) != true {
                everyCharacterHasAttribute = false
                stop.pointee = true
            }
        }
        if everyCharacterHasAttribute {
            storage.removeAttribute(key, range: range)
        } else {
            storage.addAttribute(key, value: true, range: range)
        }
        SummaryRichTextCodec.applyFonts(to: storage, in: range)
        textView.didChangeText()
    }

    private func setHeadingLevel(_ level: Int?) {
        guard let textView else { return }
        let storage = textView.textStorage!
        let paragraphRange = (textView.string as NSString).paragraphRange(
            for: textView.selectedRange()
        )
        if let level {
            storage.addAttribute(.qapiaHeadingLevel, value: level, range: paragraphRange)
        } else {
            storage.removeAttribute(.qapiaHeadingLevel, range: paragraphRange)
        }
        SummaryRichTextCodec.applyFonts(to: storage, in: paragraphRange)
        textView.didChangeText()
    }

    private func toggleList(
        prefix: (Int) -> String,
        matches: (String) -> Bool
    ) {
        guard let textView else { return }
        let source = textView.string as NSString
        let paragraphRange = source.paragraphRange(for: textView.selectedRange())
        var lineRanges: [NSRange] = []
        var cursor = paragraphRange.location
        while cursor < NSMaxRange(paragraphRange) {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            lineRanges.append(lineRange)
            let next = NSMaxRange(lineRange)
            guard next > cursor else { break }
            cursor = next
        }

        let nonEmptyLines = lineRanges.filter {
            !source.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !nonEmptyLines.isEmpty else { return }
        let removeTargetPrefix = nonEmptyLines.allSatisfy {
            matches(source.substring(with: $0).trimmingCharacters(in: .newlines))
        }

        let storage = textView.textStorage!
        storage.beginEditing()
        for (index, lineRange) in nonEmptyLines.enumerated().reversed() {
            let rawLine = source.substring(with: lineRange)
            let newline = rawLine.hasSuffix("\n") ? "\n" : ""
            let body = rawLine
                .trimmingCharacters(in: .newlines)
                .replacingOccurrences(
                    of: #"^(?:•\s+|\d+[.)]\s+)"#,
                    with: "",
                    options: .regularExpression
                )
            let replacement = (removeTargetPrefix ? "" : prefix(index)) + body + newline
            storage.replaceCharacters(in: lineRange, with: replacement)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func applyTypingFont(to textView: NSTextView) {
        var attributes = textView.typingAttributes
        let headingLevel = attributes[.qapiaHeadingLevel] as? Int
        var font = NSFont.systemFont(
            ofSize: headingLevel == nil ? 13 : 17,
            weight: headingLevel == nil ? .regular : .bold
        )
        if (attributes[.qapiaBold] as? Bool) == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if (attributes[.qapiaItalic] as? Bool) == true {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        attributes[.font] = font
        textView.typingAttributes = attributes
    }
}

struct RichTextSummaryEditor: NSViewRepresentable {
    @Binding var markdown: String
    let controller: SummaryRichTextController
    let onFocusChange: (Bool) -> Void
    let layoutWidth: CGFloat
    @Binding var contentHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> FocusReportingTextView {
        let textView = FocusReportingTextView()
        textView.delegate = context.coordinator
        textView.focusChangeHandler = { focused in
            context.coordinator.parent.onFocusChange(focused)
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(
            SummaryRichTextCodec.attributedString(from: markdown)
        )
        context.coordinator.lastMarkdown = markdown
        controller.textView = textView
        updateLayout(of: textView)

        DispatchQueue.main.async { [weak textView] in
            textView?.window?.makeFirstResponder(textView)
        }
        return textView
    }

    func updateNSView(_ textView: FocusReportingTextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = textView
        if markdown != context.coordinator.lastMarkdown {
            context.coordinator.isApplyingExternalValue = true
            textView.textStorage?.setAttributedString(
                SummaryRichTextCodec.attributedString(from: markdown)
            )
            context.coordinator.lastMarkdown = markdown
            context.coordinator.isApplyingExternalValue = false
        }
        updateLayout(of: textView)
    }

    private func updateLayout(of textView: NSTextView) {
        guard layoutWidth > 1,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return }
        let contentWidth = max(1, layoutWidth - (textView.textContainerInset.width * 2))
        textContainer.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let measuredHeight = max(
            190,
            ceil(
                layoutManager.usedRect(for: textContainer).height
                    + (textView.textContainerInset.height * 2)
            )
        )
        if abs(contentHeight - measuredHeight) > 0.5 {
            DispatchQueue.main.async { contentHeight = measuredHeight }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextSummaryEditor
        var lastMarkdown = ""
        var isApplyingExternalValue = false

        init(parent: RichTextSummaryEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalValue,
                  let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            let value = SummaryRichTextCodec.markdown(from: storage)
            guard value != lastMarkdown else { return }
            lastMarkdown = value
            parent.markdown = value
            parent.updateLayout(of: textView)
            textView.invalidateIntrinsicContentSize()
        }
    }
}

final class FocusReportingTextView: NSTextView {
    var focusChangeHandler: ((Bool) -> Void)?
    private var outsideClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeOutsideClickMonitor()
        } else {
            installOutsideClickMonitorIfNeeded()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChangeHandler?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChangeHandler?(false) }
        return accepted
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged, let textContainer else { return }
        textContainer.containerSize = NSSize(
            width: max(1, newSize.width - (textContainerInset.width * 2)),
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager?.ensureLayout(for: textContainer)
    }

    private func installOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  event.window === self.window,
                  self.window?.firstResponder === self else { return event }
            let editorFrame = self.convert(self.bounds, to: nil)
            // The formatting bar is the editor's immediate SwiftUI sibling.
            // Keep focus while its controls are being used.
            let toolbarFrame = NSRect(
                x: editorFrame.minX,
                y: editorFrame.maxY,
                width: editorFrame.width,
                height: 42
            )
            guard !editorFrame.contains(event.locationInWindow),
                  !toolbarFrame.contains(event.locationInWindow) else { return event }
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}

enum SummaryRichTextCodec {
    private static let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")

    static func attributedString(from markdown: String) -> NSAttributedString {
        let blocks = SummaryMarkdownParser.parse(markdown)
        let result = NSMutableAttributedString()

        for (index, block) in blocks.enumerated() {
            let rendered: NSMutableAttributedString
            switch block.kind {
            case let .heading(level, text):
                rendered = inlineString(text)
                rendered.addAttribute(
                    .qapiaHeadingLevel,
                    value: level,
                    range: NSRange(location: 0, length: rendered.length)
                )
            case let .paragraph(text):
                rendered = inlineString(text)
            case let .unorderedItem(text, _):
                rendered = NSMutableAttributedString(string: "• ")
                rendered.append(inlineString(text))
            case let .orderedItem(number, text, _):
                rendered = NSMutableAttributedString(string: "\(number). ")
                rendered.append(inlineString(text))
            case let .quote(text):
                rendered = NSMutableAttributedString(string: "“")
                rendered.append(inlineString(text))
                rendered.append(NSAttributedString(string: "”"))
                rendered.addAttribute(
                    .qapiaItalic,
                    value: true,
                    range: NSRange(location: 0, length: rendered.length)
                )
            case let .code(text):
                rendered = NSMutableAttributedString(string: text)
            case .divider:
                rendered = NSMutableAttributedString(string: "────────")
            }

            applyFonts(to: rendered, in: NSRange(location: 0, length: rendered.length))
            applyBlockPresentation(block.kind, to: rendered)
            result.append(rendered)
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: separator(after: block.kind, before: blocks[index + 1].kind)))
            }
        }

        return result
    }

    static func markdown(from attributedString: NSAttributedString) -> String {
        let source = attributedString.string as NSString
        var lines: [String] = []
        var cursor = 0
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            let raw = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if raw.isEmpty {
                lines.append("")
            } else {
                let rawLength = (raw as NSString).length
                let contentRange = NSRange(location: lineRange.location, length: rawLength)
                let headingLevel = attributedString.attribute(
                    .qapiaHeadingLevel,
                    at: contentRange.location,
                    effectiveRange: nil
                ) as? Int
                let prefixLength = visibleListPrefixLength(in: raw)
                let bodyRange = NSRange(
                    location: contentRange.location + prefixLength,
                    length: max(0, contentRange.length - prefixLength)
                )
                let body = inlineMarkdown(from: attributedString, range: bodyRange)
                if let headingLevel {
                    lines.append(String(repeating: "#", count: min(max(headingLevel, 1), 6)) + " " + body)
                } else if raw.hasPrefix("• ") {
                    lines.append("- " + body)
                } else if prefixLength > 0 {
                    let prefix = (raw as NSString).substring(to: prefixLength)
                        .replacingOccurrences(of: ") ", with: ". ")
                    lines.append(prefix + body)
                } else {
                    lines.append(body)
                }
            }
            let next = NSMaxRange(lineRange)
            guard next > cursor else { break }
            cursor = next
        }

        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func applyFonts(to value: NSMutableAttributedString, in range: NSRange) {
        guard value.length > 0, range.length > 0 else { return }
        let safeRange = NSIntersectionRange(range, NSRange(location: 0, length: value.length))
        value.enumerateAttributes(in: safeRange) { attributes, effectiveRange, _ in
            let headingLevel = attributes[.qapiaHeadingLevel] as? Int
            let baseSize: CGFloat = headingLevel == nil ? 13 : (headingLevel == 1 ? 19 : headingLevel == 2 ? 17 : 15)
            var font = NSFont.systemFont(
                ofSize: baseSize,
                weight: headingLevel == nil ? .regular : .bold
            )
            if (attributes[.qapiaBold] as? Bool) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if (attributes[.qapiaItalic] as? Bool) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            value.addAttribute(.font, value: font, range: effectiveRange)
        }
    }

    private static func inlineString(_ source: String) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        let result = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        result.enumerateAttribute(
            inlineIntentKey,
            in: NSRange(location: 0, length: result.length)
        ) { value, range, _ in
            let intent = (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
            if intent & 2 != 0 { result.addAttribute(.qapiaBold, value: true, range: range) }
            if intent & 1 != 0 { result.addAttribute(.qapiaItalic, value: true, range: range) }
        }
        result.removeAttribute(inlineIntentKey, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func applyBlockPresentation(
        _ kind: SummaryMarkdownBlock.Kind,
        to value: NSMutableAttributedString
    ) {
        guard value.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: value.length)
        let paragraphStyle = NSMutableParagraphStyle()
        let foregroundColor: NSColor

        switch kind {
        case .heading:
            paragraphStyle.lineSpacing = 3
            foregroundColor = .labelColor
        case .unorderedItem, .orderedItem:
            paragraphStyle.lineSpacing = 4
            paragraphStyle.paragraphSpacing = 7
            paragraphStyle.firstLineHeadIndent = 0
            paragraphStyle.headIndent = 17
            foregroundColor = .secondaryLabelColor
        case .paragraph:
            paragraphStyle.lineSpacing = 5
            foregroundColor = .secondaryLabelColor
        case .quote:
            paragraphStyle.lineSpacing = 4
            paragraphStyle.firstLineHeadIndent = 12
            paragraphStyle.headIndent = 12
            foregroundColor = .secondaryLabelColor
        case .code:
            paragraphStyle.lineSpacing = 3
            foregroundColor = .secondaryLabelColor
        case .divider:
            foregroundColor = .separatorColor
        }

        value.addAttribute(.paragraphStyle, value: paragraphStyle, range: fullRange)
        value.addAttribute(.foregroundColor, value: foregroundColor, range: fullRange)
        switch kind {
        case .unorderedItem:
            value.addAttribute(
                .foregroundColor,
                value: editorAccentColor,
                range: NSRange(location: 0, length: min(1, value.length))
            )
        case .orderedItem:
            let prefixLength = min(visibleListPrefixLength(in: value.string), value.length)
            if prefixLength > 0 {
                value.addAttribute(
                    .foregroundColor,
                    value: editorAccentColor,
                    range: NSRange(location: 0, length: prefixLength)
                )
            }
        default:
            break
        }
    }

    private static let editorAccentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.51, green: 0.565, blue: 1, alpha: 1)
            : NSColor(calibratedRed: 0.396, green: 0.455, blue: 0.969, alpha: 1)
    }

    private static func inlineMarkdown(
        from value: NSAttributedString,
        range: NSRange
    ) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        value.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
            var text = (value.string as NSString).substring(with: effectiveRange)
            text = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "*", with: "\\*")
                .replacingOccurrences(of: "_", with: "\\_")
            let bold = (attributes[.qapiaBold] as? Bool) == true
            let italic = (attributes[.qapiaItalic] as? Bool) == true
            if bold && italic {
                result += "***\(text)***"
            } else if bold {
                result += "**\(text)**"
            } else if italic {
                result += "*\(text)*"
            } else {
                result += text
            }
        }
        return result
    }

    private static func visibleListPrefixLength(in line: String) -> Int {
        let source = line as NSString
        let range = source.range(of: #"^(?:•\s+|\d+[.)]\s+)"#, options: .regularExpression)
        return range.location == NSNotFound ? 0 : range.length
    }

    private static func separator(
        after current: SummaryMarkdownBlock.Kind,
        before next: SummaryMarkdownBlock.Kind
    ) -> String {
        switch (current, next) {
        case (.unorderedItem, .unorderedItem), (.orderedItem, .orderedItem): "\n"
        default: "\n\n"
        }
    }
}
