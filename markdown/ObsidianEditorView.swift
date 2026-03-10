import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct ObsidianEditorView: View {
    let note: NoteSummary
    @Binding var text: String
    let syncStatus: String
    let isUsingICloud: Bool
    let isSaving: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            editorSurface
            Divider()
            statusBar
        }
        .background(Color(obsidianCanvasColor))
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()

            VStack(spacing: 2) {
                Text(note.name)
                    .font(.system(size: 15, weight: .semibold))

                Text(note.relativePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "book.closed")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(obsidianBarColor))
    }

    private var editorSurface: some View {
        HStack {
            Spacer(minLength: 0)
            editor
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .background(Color(obsidianCanvasColor))
    }

    @ViewBuilder
    private var editor: some View {
        #if os(macOS)
        LiveMarkdownTextEditor(text: $text)
        #else
        TextEditor(text: $text)
            .font(.system(size: 18, weight: .regular, design: .default))
            .scrollContentBackground(.hidden)
            .padding(.top, 10)
            .background(Color.clear)
        #endif
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Label(syncStatus, systemImage: isUsingICloud ? "icloud" : "internaldrive")
                .foregroundStyle(.secondary)

            if isSaving {
                Text("Saving...")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(wordCount) words")
            Text("\(text.count) characters")
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(obsidianBarColor))
    }

    private var wordCount: Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

#if os(macOS)
private struct LiveMarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.insertionPointColor = .labelColor
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 24)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 760, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        context.coordinator.apply(text: text, to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text

        if textView.string != text {
            context.coordinator.apply(text: text, to: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        private var isApplying = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else {
                return
            }

            text.wrappedValue = textView.string
            restyle(textView)
        }

        func apply(text: String, to textView: NSTextView) {
            let selectedRange = textView.selectedRange()

            isApplying = true
            textView.textStorage?.setAttributedString(MarkdownEditorStyler.styledText(for: text))
            textView.setSelectedRange(clampedRange(selectedRange, length: (text as NSString).length))
            isApplying = false
        }

        private func restyle(_ textView: NSTextView) {
            let selectedRange = textView.selectedRange()

            isApplying = true
            textView.textStorage?.setAttributedString(MarkdownEditorStyler.styledText(for: textView.string))
            textView.setSelectedRange(clampedRange(selectedRange, length: (textView.string as NSString).length))
            isApplying = false
        }

        private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
            let location = min(range.location, length)
            let maxLength = max(0, length - location)
            return NSRange(location: location, length: min(range.length, maxLength))
        }
    }
}

private enum MarkdownEditorStyler {
    private static let bodyFont = NSFont.systemFont(ofSize: 20, weight: .regular)
    private static let markerFont = NSFont.systemFont(ofSize: 18, weight: .semibold)
    private static let codeFont = NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)
    private static let bodyColor = NSColor.labelColor
    private static let secondaryColor = NSColor.secondaryLabelColor
    private static let tertiaryColor = NSColor.tertiaryLabelColor
    private static let quoteColor = NSColor(calibratedWhite: 0.34, alpha: 1)

    static func styledText(for text: String) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.18
        paragraphStyle.paragraphSpacing = 12

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var isInsideCodeBlock = false

        nsText.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, substringRange, _, _ in
            let line = nsText.substring(with: substringRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineRange = substringRange

            if trimmed.hasPrefix("```") {
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 1.08
                style.paragraphSpacing = 8
                attributed.addAttributes([
                    .font: codeFont,
                    .foregroundColor: tertiaryColor,
                    .paragraphStyle: style
                ], range: lineRange)
                isInsideCodeBlock.toggle()
                return
            }

            if isInsideCodeBlock {
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 1.08
                style.paragraphSpacing = 8
                attributed.addAttributes([
                    .font: codeFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: style,
                    .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.7)
                ], range: lineRange)
                return
            }

            if let heading = headingStyle(for: line) {
                let markerRange = NSRange(location: lineRange.location, length: heading.markerLength)
                let titleRange = NSRange(
                    location: lineRange.location + heading.titleOffset,
                    length: max(0, lineRange.length - heading.titleOffset)
                )
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 0.96
                style.paragraphSpacing = heading.level == 1 ? 18 : 12

                attributed.addAttributes([
                    .font: heading.titleFont,
                    .foregroundColor: bodyColor,
                    .paragraphStyle: style
                ], range: titleRange)
                attributed.addAttributes([
                    .font: markerFont,
                    .foregroundColor: tertiaryColor,
                    .paragraphStyle: style
                ], range: markerRange)
                return
            }

            if trimmed.hasPrefix(">") {
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 1.14
                style.paragraphSpacing = 10
                attributed.addAttributes([
                    .foregroundColor: quoteColor,
                    .font: NSFont.systemFont(ofSize: 19, weight: .regular),
                    .paragraphStyle: style
                ], range: lineRange)

                if let markerIndex = line.firstIndex(of: ">") {
                    let markerOffset = line.distance(from: line.startIndex, to: markerIndex)
                    attributed.addAttributes([
                        .foregroundColor: tertiaryColor,
                        .font: markerFont
                    ], range: NSRange(location: lineRange.location + markerOffset, length: 1))
                }
                return
            }

            if isListLine(trimmed) {
                let style = NSMutableParagraphStyle()
                style.lineHeightMultiple = 1.12
                style.paragraphSpacing = 8
                attributed.addAttribute(.paragraphStyle, value: style, range: lineRange)
            }
        }

        return attributed
    }

    private static func headingStyle(for line: String) -> (level: Int, markerLength: Int, titleOffset: Int, titleFont: NSFont)? {
        let characters = Array(line)
        var count = 0

        while count < characters.count, characters[count] == "#", count < 6 {
            count += 1
        }

        guard count > 0, count < characters.count, characters[count] == " " else {
            return nil
        }

        let fontSize: CGFloat
        switch count {
        case 1:
            fontSize = 44
        case 2:
            fontSize = 34
        case 3:
            fontSize = 28
        case 4:
            fontSize = 24
        case 5:
            fontSize = 21
        default:
            fontSize = 19
        }

        return (count, count, count + 1, NSFont.systemFont(ofSize: fontSize, weight: .bold))
    }

    private static func isListLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return true
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let marker = parts.first else {
            return false
        }

        return marker.hasSuffix(".") && marker.dropLast().allSatisfy(\.isNumber)
    }
}
#endif

#if os(macOS)
private let obsidianCanvasColor = NSColor(calibratedWhite: 0.965, alpha: 1)
private let obsidianBarColor = NSColor(calibratedWhite: 0.952, alpha: 1)
#elseif os(iOS)
private let obsidianCanvasColor = UIColor(red: 0.965, green: 0.965, blue: 0.969, alpha: 1)
private let obsidianBarColor = UIColor(red: 0.952, green: 0.952, blue: 0.956, alpha: 1)
#endif
