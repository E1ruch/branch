import DesignSystem
import SwiftUI
import UIKit

/// How formatted text looks. The `.md*` attributes say what the text is;
/// fonts and colors are derived from them on every change, so pasted text
/// never brings foreign styles along.
@MainActor
enum MarkdownStyler {
    static var baseFont: UIFont { .preferredFont(forTextStyle: .body) }

    static func paragraph(indent: CGFloat = 0, hanging: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 2
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        return style
    }

    /// What a character typed into an unformatted line gets.
    static var plainAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: Palette.textPrimary, .paragraphStyle: paragraph()]
    }

    static func restyle(_ textView: UITextView) {
        // Never while the keyboard composes a character (IME, dictation).
        guard textView.markedTextRange == nil else { return }
        let storage = textView.textStorage
        let ns = storage.string as NSString
        let base = baseFont
        storage.beginEditing()

        // A paragraph format covers the whole line, as its first character says.
        var location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if let block = storage.attribute(.mdBlock, at: paragraph.location, effectiveRange: nil) {
                storage.addAttribute(.mdBlock, value: block, range: paragraph)
            } else {
                storage.removeAttribute(.mdBlock, range: paragraph)
            }
            location = NSMaxRange(paragraph)
        }

        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, run, _ in
            var styled: [NSAttributedString.Key: Any] = [:]
            for key in NSAttributedString.Key.markdownKeys {
                if let value = attrs[key] { styled[key] = value }
            }
            let block = (attrs[.mdBlock] as? String).flatMap(MarkdownBlock.init)

            var font = block == .heading ? UIFont.systemFont(ofSize: base.pointSize + 3, weight: .bold) : base
            var traits: UIFontDescriptor.SymbolicTraits = []
            if attrs[.mdBold] != nil { traits.insert(.traitBold) }
            if attrs[.mdItalic] != nil || block == .quote { traits.insert(.traitItalic) }
            if attrs[.mdCode] != nil {
                font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: traits.contains(.traitBold) ? .bold : .regular)
            } else if !traits.isEmpty,
                      let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            styled[.font] = font

            var color = block == .quote ? Palette.textSecondary : Palette.textPrimary
            if attrs[.mdStrike] != nil {
                styled[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                color = Palette.textSecondary
            }
            if attrs[.mdCode] != nil {
                styled[.backgroundColor] = Palette.surfaceTertiary
            }
            if attrs[.mdLink] != nil {
                color = Palette.link
                styled[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            styled[.foregroundColor] = color
            styled[.paragraphStyle] = block == .quote ? paragraph(indent: 14) : paragraph()
            storage.setAttributes(styled, range: run)
        }

        // List items: a green bullet, wrapped lines aligned with the text.
        let bulletWidth = (MarkdownCodec.bullet as NSString).size(withAttributes: [.font: base]).width
        location = 0
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            if ns.substring(with: paragraph).hasPrefix(MarkdownCodec.bullet) {
                storage.addAttribute(.foregroundColor, value: Palette.accent, range: NSRange(location: paragraph.location, length: 1))
                storage.addAttribute(.paragraphStyle, value: Self.paragraph(hanging: bulletWidth), range: paragraph)
            }
            location = NSMaxRange(paragraph)
        }
        storage.endEditing()
        updateTypingAttributes(textView)
    }

    /// At the start of a line the next character takes that line's format,
    /// not the end of the line above (a heading must not leak downwards).
    static func updateTypingAttributes(_ textView: UITextView) {
        let storage = textView.textStorage
        let ns = storage.string as NSString
        let caret = textView.selectedRange.location
        guard ns.length > 0 else {
            textView.typingAttributes = plainAttributes
            return
        }
        let paragraph = ns.paragraphRange(for: NSRange(location: min(caret, ns.length), length: 0))
        guard caret == paragraph.location else { return } // inside a line: UIKit's own choice is right
        var attributes = plainAttributes
        let lineIsEmpty = paragraph.length == 0 || ns.character(at: paragraph.location) == 0x0A
        if !lineIsEmpty, let block = storage.attribute(.mdBlock, at: paragraph.location, effectiveRange: nil) {
            attributes[.mdBlock] = block
        }
        textView.typingAttributes = attributes
    }
}

/// Runs the selection menu's formatting on the editor.
@MainActor
final class MarkdownEditor {
    fileprivate weak var textView: UITextView?
    fileprivate var onEdit: (() -> Void)?

    /// Puts the cursor at the end of the text. Direct, not through a
    /// SwiftUI update: a focus change queued behind the title's resign gets
    /// lost.
    func focus() {
        guard let textView, !textView.isFirstResponder else { return }
        textView.becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak textView] in
            guard let textView, !textView.isFirstResponder else { return }
            textView.becomeFirstResponder()
        }
    }

    /// Whether every character of the selection has `format` (a check mark
    /// in the menu; applying it again takes it off).
    func isApplied(_ format: MarkdownFormat, in range: NSRange) -> Bool {
        guard let textView, range.length > 0 else { return false }
        let storage = textView.textStorage
        switch format {
        case .bold, .italic, .strikethrough, .code:
            return covers(storage, format.key!, range)
        case .link:
            return covers(storage, .mdLink, range)
        case .heading, .quote:
            let value = format == .heading ? MarkdownBlock.heading.rawValue : MarkdownBlock.quote.rawValue
            return paragraphs(in: range, of: storage.string as NSString).allSatisfy {
                $0.length > 0 && storage.attribute(.mdBlock, at: $0.location, effectiveRange: nil) as? String == value
            }
        case .list:
            let ns = storage.string as NSString
            return paragraphs(in: range, of: ns).allSatisfy { ns.substring(with: $0).hasPrefix(MarkdownCodec.bullet) }
        case .plain:
            return false
        }
    }

    func apply(_ format: MarkdownFormat) {
        guard let textView else { return }
        let range = textView.selectedRange
        let storage = textView.textStorage
        let on = isApplied(format, in: range)

        switch format {
        case .bold, .italic, .strikethrough, .code:
            guard range.length > 0, let key = format.key else { return }
            if on { storage.removeAttribute(key, range: range) } else { storage.addAttribute(key, value: true, range: range) }
        case .link:
            guard range.length > 0 else { return }
            if on {
                storage.removeAttribute(.mdLink, range: range)
            } else {
                askForLink { [weak self, weak textView] url in
                    guard let self, let textView else { return }
                    textView.textStorage.addAttribute(.mdLink, value: url, range: range)
                    self.finish(textView, selection: range)
                }
                return
            }
        case .heading, .quote:
            let value = format == .heading ? MarkdownBlock.heading.rawValue : MarkdownBlock.quote.rawValue
            for paragraph in paragraphs(in: range, of: storage.string as NSString) where paragraph.length > 0 {
                if on {
                    storage.removeAttribute(.mdBlock, range: paragraph)
                } else {
                    storage.addAttribute(.mdBlock, value: value, range: paragraph)
                }
            }
        case .list:
            finish(textView, selection: toggleBullets(in: textView, range: range, on: on))
            return
        case .plain:
            for key in NSAttributedString.Key.markdownKeys where key != .mdBlock {
                storage.removeAttribute(key, range: range)
            }
            for paragraph in paragraphs(in: range, of: storage.string as NSString) {
                storage.removeAttribute(.mdBlock, range: paragraph)
            }
        }
        finish(textView, selection: range)
    }

    private func finish(_ textView: UITextView, selection: NSRange) {
        MarkdownStyler.restyle(textView)
        textView.selectedRange = selection
        Haptics.selection()
        onEdit?()
    }

    /// "• " at the start of each selected line, or off again.
    private func toggleBullets(in textView: UITextView, range: NSRange, on: Bool) -> NSRange {
        let storage = textView.textStorage
        let bullet = MarkdownCodec.bullet
        let length = (bullet as NSString).length
        var selection = range
        // From the last line up, so earlier ranges stay valid.
        for paragraph in paragraphs(in: range, of: storage.string as NSString).reversed() {
            let line = (storage.string as NSString).substring(with: paragraph)
            if on {
                guard line.hasPrefix(bullet) else { continue }
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: length), with: "")
                if paragraph.location < selection.location {
                    selection.location -= length
                } else {
                    selection.length = max(0, selection.length - length)
                }
            } else if !line.hasPrefix(bullet) {
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: 0),
                                          with: NSAttributedString(string: bullet, attributes: MarkdownStyler.plainAttributes))
                if paragraph.location <= selection.location {
                    selection.location += length
                } else {
                    selection.length += length
                }
            }
        }
        return selection
    }

    private func covers(_ storage: NSTextStorage, _ key: NSAttributedString.Key, _ range: NSRange) -> Bool {
        var covered = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if value == nil { covered = false; stop.pointee = true }
        }
        return covered
    }

    private func paragraphs(in range: NSRange, of ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        let span = ns.paragraphRange(for: range)
        var location = span.location
        repeat {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            result.append(paragraph)
            location = NSMaxRange(paragraph)
        } while location < NSMaxRange(span)
        return result
    }

    /// The address for a link: a small alert, prefilled from the clipboard.
    private func askForLink(_ done: @escaping (String) -> Void) {
        guard var presenter = textView?.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let alert = UIAlertController(title: "Ссылка", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            if let copied = UIPasteboard.general.url?.absoluteString, copied.hasPrefix("http") {
                field.text = copied
            } else {
                field.text = "https://"
            }
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Готово", style: .default) { [weak alert] _ in
            var url = (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !url.isEmpty, url != "https://" else { return }
            if !url.contains("://") { url = "https://" + url }
            done(url)
        })
        presenter.present(alert, animated: true)
    }
}

/// The post's text, shown formatted as it will look: no asterisks or
/// hashes on screen. The binding carries markdown (what the draft and the
/// server keep); MarkdownCodec converts both ways.
struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let editor: MarkdownEditor
    let placeholder: String
    let minHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 8, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.tintColor = Palette.accent
        textView.smartInsertDeleteType = .no
        textView.delegate = context.coordinator
        textView.accessibilityLabel = "Текст поста"
        textView.accessibilityIdentifier = "compose.body"
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.load(text, into: textView)

        let placeholderLabel = context.coordinator.placeholderLabel
        placeholderLabel.text = placeholder
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = Palette.textTertiary
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
        ])
        placeholderLabel.isHidden = textView.textStorage.length > 0

        editor.textView = textView
        editor.onEdit = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.publish(textView)
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if text != context.coordinator.lastMarkdown {
            // The draft changed from outside (discarded, restored).
            context.coordinator.load(text, into: textView)
            textView.invalidateIntrinsicContentSize()
        }
        context.coordinator.placeholderLabel.isHidden = textView.textStorage.length > 0
        if isFocused && !textView.isFirstResponder {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        } else if !isFocused && textView.isFirstResponder {
            DispatchQueue.main.async { textView.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: max(minHeight, ceil(fitting)))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView
        let placeholderLabel = UILabel()
        /// The markdown last sent to or received from the binding.
        var lastMarkdown = ""

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func load(_ markdown: String, into textView: UITextView) {
            lastMarkdown = markdown
            textView.attributedText = MarkdownCodec.attributed(from: markdown)
            MarkdownStyler.restyle(textView)
        }

        /// The text changed on screen: restyle it and hand markdown up.
        func publish(_ textView: UITextView) {
            MarkdownStyler.restyle(textView)
            placeholderLabel.isHidden = textView.textStorage.length > 0
            let markdown = MarkdownCodec.markdown(from: textView.textStorage)
            if markdown != lastMarkdown {
                lastMarkdown = markdown
                parent.text = markdown
            }
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChange(_ textView: UITextView) {
            publish(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            MarkdownStyler.updateTypingAttributes(textView)
        }

        /// Return in a list item starts the next one; on an empty item it
        /// ends the list.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", range.length == 0 else { return true }
            let ns = textView.textStorage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard line.hasPrefix(MarkdownCodec.bullet.trimmingCharacters(in: .whitespaces)) else { return true }
            let bulletLength = (MarkdownCodec.bullet as NSString).length
            if line.trimmingCharacters(in: .whitespaces) == "•" {
                // An empty item: the list ends here.
                textView.textStorage.replaceCharacters(in: NSRange(location: paragraph.location, length: min(bulletLength, ns.length - paragraph.location)), with: "")
                textView.selectedRange = NSRange(location: paragraph.location, length: 0)
            } else {
                textView.textStorage.replaceCharacters(
                    in: range, with: NSAttributedString(string: "\n" + MarkdownCodec.bullet,
                                                        attributes: MarkdownStyler.plainAttributes))
                textView.selectedRange = NSRange(location: range.location + 1 + bulletLength, length: 0)
            }
            publish(textView)
            return false
        }

        /// Formatting, the Telegram way: select text, then "Форматирование".
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let editor = parent.editor
            func action(_ format: MarkdownFormat) -> UIAction {
                UIAction(title: format.title, image: UIImage(systemName: format.symbol),
                         state: editor.isApplied(format, in: range) ? .on : .off) { _ in editor.apply(format) }
            }
            let formats = UIMenu(title: "Форматирование", image: UIImage(systemName: "textformat"), children: [
                UIMenu(options: .displayInline, children: [.bold, .italic, .strikethrough, .code, .link].map(action)),
                UIMenu(options: .displayInline, children: [.heading, .quote, .list].map(action)),
                UIMenu(options: .displayInline, children: [action(.plain)]),
            ])
            return UIMenu(children: [formats] + suggestedActions)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }
    }
}
