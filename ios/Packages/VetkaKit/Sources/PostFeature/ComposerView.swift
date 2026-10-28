import DesignSystem
import UIKit

/// The comment field at the bottom of a thread: grows with the text up to
/// a few lines, shows whom it answers, sends with the green arrow. Signed
/// out, it is a single button that asks to sign in.
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
    private let signInButton = UIButton(type: .system)
    private let topBorder = UIView()
    private var textHeight: NSLayoutConstraint!
    private var replyBarHeight: NSLayoutConstraint!
    private var errorHeight: NSLayoutConstraint!

    /// The comment this field answers; nil for a top-level comment.
    private(set) var replyTo: Int64?
    var onSend: ((String, Int64?) -> Void)?
    var onSignIn: (() -> Void)?

    static let maxLines: CGFloat = 6

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
        cancelReplyButton.addAction(UIAction { [weak self] _ in self?.endReply() }, for: .touchUpInside)
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

        sendButton.setImage(UIImage(systemName: "arrow.up.circle.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 30)), for: .normal)
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

        for view in [topBorder, replyBar, errorLabel, field, sendButton, signInButton] as [UIView] {
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

            signInButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            signInButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            signInButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            signInButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Replies

    func beginReply(to id: Int64, author: String) {
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

    /// A comment that did not go through comes back for another try.
    func restore(text: String, replyTo id: Int64?, author: String?, error: String) {
        if textView.text.isEmpty {
            textView.text = text
            textViewDidChange(textView)
        }
        if let id, let author {
            beginReply(to: id, author: author)
        }
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
        guard !text.isEmpty else { return }
        onSend?(text, replyTo)
    }

    /// After the model took the comment.
    func clear() {
        textView.text = ""
        textViewDidChange(textView)
        endReply()
    }

    func textViewDidChange(_ textView: UITextView) {
        let empty = textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        placeholder.isHidden = !textView.text.isEmpty
        if sendButton.isEnabled == empty {
            sendButton.isEnabled = !empty
            sendButton.tintColor = empty ? Palette.iconDisabled : Palette.accent
        }
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
}
