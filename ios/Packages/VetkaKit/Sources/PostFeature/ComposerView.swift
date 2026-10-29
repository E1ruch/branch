import Core
import DesignSystem
import UIKit

/// The comment field at the bottom of a thread: grows with the text up to
/// a few lines, shows whom it answers, sends with the green arrow. Near the
/// length limit a counter shows what is left; over it, sending stops. In
/// edit mode it holds your comment's text and saves with a check mark, as
/// Telegram does. Signed out, it is a single button that asks to sign in.
///
/// Auto Layout is fine here: one view that changes when the user types,
/// not cells that change while scrolling.
final class ComposerView: UIView, UITextViewDelegate {
    private let replyBar = UIView()
    private let replyLabel = UILabel()
    private let cancelReplyButton = UIButton(type: .system)
    private let errorLabel = UILabel()
    private let field = UIView()
    let textView = UITextView()
    private let placeholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let counterLabel = UILabel()
    private let signInButton = UIButton(type: .system)
    private let topBorder = UIView()
    private var textHeight: NSLayoutConstraint!
    private var replyBarHeight: NSLayoutConstraint!
    private var errorHeight: NSLayoutConstraint!

    /// The comment this field answers; nil for a top-level comment.
    private(set) var replyTo: Int64?
    /// The comment being edited, and its text before the edit.
    private(set) var editing: Int64?
    private var originalText = ""
    var onSend: ((String, Int64?) -> Void)?
    var onEdit: ((_ id: Int64, _ text: String) -> Void)?
    var onSignIn: (() -> Void)?
    /// The field gained or lost the keyboard.
    var onEditingChanged: ((Bool) -> Void)?

    static let maxLines: CGFloat = 6
    /// The counter shows from here on, like Telegram's: early enough to
    /// plan, late enough not to nag.
    static let counterThreshold = Comment.maxLength * 4 / 5

    var isSignedIn = true {
        didSet {
            signInButton.isHidden = isSignedIn
            field.isHidden = !isSignedIn
            sendButton.isHidden = !isSignedIn
            if !isSignedIn {
                textView.resignFirstResponder()
                endReply()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.surface
        topBorder.backgroundColor = Palette.border

        replyLabel.font = .preferredFont(forTextStyle: .footnote)
        replyLabel.adjustsFontForContentSizeCategory = true
        replyLabel.textColor = Palette.textSecondary
        cancelReplyButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        cancelReplyButton.tintColor = Palette.iconSecondary
        cancelReplyButton.accessibilityLabel = "Отменить ответ"
        cancelReplyButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if editing != nil { endEdit() } else { endReply() }
        }, for: .touchUpInside)
        replyBar.clipsToBounds = true

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = Palette.destructive
        errorLabel.numberOfLines = 2

        field.backgroundColor = Palette.surfaceSecondary
        field.layer.cornerRadius = 19
        field.layer.cornerCurve = .continuous
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = Palette.textPrimary
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = "Комментарий"
        textView.accessibilityIdentifier = "composer.text"
        placeholder.text = "Комментарий…"
        placeholder.font = textView.font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = Palette.textTertiary
        placeholder.isAccessibilityElement = false

        sendButton.setImage(Self.sendImage, for: .normal)
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counterLabel.textAlignment = .center
        counterLabel.alpha = 0
        counterLabel.isAccessibilityElement = false
        sendButton.tintColor = Palette.iconDisabled
        sendButton.accessibilityLabel = "Отправить"
        sendButton.accessibilityIdentifier = "composer.send"
        sendButton.isEnabled = false
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)

        var signIn = UIButton.Configuration.filled()
        signIn.title = "Войдите, чтобы комментировать"
        signIn.baseBackgroundColor = Palette.surfaceSecondary
        signIn.baseForegroundColor = Palette.textSecondary
        signIn.cornerStyle = .capsule
        signInButton.configuration = signIn
        signInButton.isHidden = true
        signInButton.addAction(UIAction { [weak self] _ in self?.onSignIn?() }, for: .touchUpInside)

        for view in [topBorder, replyBar, errorLabel, field, sendButton, counterLabel, signInButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [replyLabel, cancelReplyButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            replyBar.addSubview(view)
        }
        for view in [textView, placeholder] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            field.addSubview(view)
        }

        textHeight = textView.heightAnchor.constraint(equalToConstant: 38)
        replyBarHeight = replyBar.heightAnchor.constraint(equalToConstant: 0)
        errorHeight = errorLabel.heightAnchor.constraint(equalToConstant: 0)
        let hairline = 1 / UITraitCollection.current.displayScale
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: hairline),

            replyBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            replyBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            replyBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            replyBarHeight,
            replyLabel.leadingAnchor.constraint(equalTo: replyBar.leadingAnchor),
            replyLabel.centerYAnchor.constraint(equalTo: replyBar.centerYAnchor),
            replyLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelReplyButton.leadingAnchor, constant: -8),
            cancelReplyButton.trailingAnchor.constraint(equalTo: replyBar.trailingAnchor),
            cancelReplyButton.centerYAnchor.constraint(equalTo: replyBar.centerYAnchor),
            cancelReplyButton.widthAnchor.constraint(equalToConstant: 36),

            errorLabel.topAnchor.constraint(equalTo: replyBar.bottomAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            errorHeight,

            field.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 2),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.topAnchor.constraint(equalTo: field.topAnchor),
            textView.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            textHeight,
            placeholder.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 15),
            placeholder.centerYAnchor.constraint(equalTo: field.topAnchor, constant: 19),

            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            sendButton.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 40),
            sendButton.heightAnchor.constraint(equalToConstant: 38),
            counterLabel.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            counterLabel.bottomAnchor.constraint(equalTo: sendButton.topAnchor, constant: -2),

            signInButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            signInButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            signInButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            signInButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Replies

    func beginReply(to id: Int64, author: String) {
        if editing != nil { endEdit() }
        replyTo = id
        replyLabel.text = "Ответ для \(author)"
        setBar(replyBarHeight, to: 28)
        textView.becomeFirstResponder()
    }

    func endReply() {
        guard replyTo != nil else { return }
        replyTo = nil
        setBar(replyBarHeight, to: 0)
    }

    // MARK: Editing

    private static let sendImage = UIImage(systemName: "arrow.up.circle.fill",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 30))
    private static let saveImage = UIImage(systemName: "checkmark.circle.fill",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 30))

    /// Puts your comment's text in the field; the check mark saves it.
    /// `text` differs from `original` when a failed save comes back.
    func beginEdit(_ id: Int64, text: String, original: String? = nil) {
        endReply()
        editing = id
        originalText = original ?? text
        textView.text = text
        replyLabel.text = "Редактирование"
        cancelReplyButton.accessibilityLabel = "Отменить редактирование"
        sendButton.setImage(Self.saveImage, for: .normal)
        sendButton.accessibilityLabel = "Сохранить"
        textViewDidChange(textView)
        setBar(replyBarHeight, to: 28)
        textView.becomeFirstResponder()
        let end = textView.endOfDocument
        textView.selectedTextRange = textView.textRange(from: end, to: end)
    }

    /// Leaves edit mode; the field is empty again for a new comment.
    func endEdit() {
        guard editing != nil else { return }
        editing = nil
        originalText = ""
        textView.text = ""
        cancelReplyButton.accessibilityLabel = "Отменить ответ"
        sendButton.setImage(Self.sendImage, for: .normal)
        sendButton.accessibilityLabel = "Отправить"
        textViewDidChange(textView)
        setBar(replyBarHeight, to: 0)
    }

    /// An edit that did not save comes back for another try.
    func restoreEdit(_ id: Int64, text: String, original: String, error: String) {
        beginEdit(id, text: text, original: original)
        showError(error)
    }

    /// A comment that did not go through comes back for another try.
    func restore(text: String, replyTo id: Int64?, author: String?, error: String) {
        if textView.text.isEmpty {
            textView.text = text
            textViewDidChange(textView)
        }
        if let id, let author {
            beginReply(to: id, author: author)
        }
        showError(error)
    }

    private func showError(_ error: String) {
        errorLabel.text = error
        setBar(errorHeight, to: ceil(errorLabel.font.lineHeight) + 4)
    }

    private func setBar(_ constraint: NSLayoutConstraint, to height: CGFloat) {
        guard constraint.constant != height else { return }
        constraint.constant = height
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.superview?.layoutIfNeeded()
        }
    }

    // MARK: Typing and sending

    private func send() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend(text) else { return }
        if let editing {
            onEdit?(editing, text)
        } else {
            onSend?(text, replyTo)
        }
    }

    /// Something to send, within the limit; an edit must change the text.
    private func canSend(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.count <= Comment.maxLength
            && (editing == nil || text != originalText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// After the model took the comment.
    func clear() {
        textView.text = ""
        textViewDidChange(textView)
        endReply()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        onEditingChanged?(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        onEditingChanged?(false)
    }

    func textViewDidChange(_ textView: UITextView) {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendable = canSend(text)
        placeholder.isHidden = !textView.text.isEmpty
        if sendButton.isEnabled != sendable {
            sendButton.isEnabled = sendable
            sendButton.tintColor = sendable ? Palette.accent : Palette.iconDisabled
        }
        updateCounter(length: text.unicodeScalars.count)
        if errorHeight.constant > 0 {
            setBar(errorHeight, to: 0)
        }
        // Grows to a few lines, then scrolls inside.
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let maxHeight = ceil(font.lineHeight * Self.maxLines) + textView.textContainerInset.top + textView.textContainerInset.bottom
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        let height = min(max(38, ceil(fitting)), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        if textHeight.constant != height {
            textHeight.constant = height
            UIView.animate(withDuration: 0.15) { self.superview?.layoutIfNeeded() }
        }
    }

    /// What is left, above the send button: from the threshold on, red and
    /// negative past the limit (pasted text is kept, not cut, so it can be
    /// trimmed by hand).
    private func updateCounter(length: Int) {
        let left = Comment.maxLength - length
        let visible = length >= Self.counterThreshold
        counterLabel.text = left.formatted()
        counterLabel.textColor = left < 0 ? Palette.destructive : Palette.textSecondary
        textView.accessibilityValue = visible ? "Осталось символов: \(left)" : nil
        let alpha: CGFloat = visible ? 1 : 0
        guard counterLabel.alpha != alpha else { return }
        UIView.animate(withDuration: 0.2) { self.counterLabel.alpha = alpha }
    }
}
