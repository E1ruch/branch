import SwiftUI

/// The app's search field, in place of the system `.searchable`, after
/// Telegram's: at rest a grey capsule with "Поиск" centred; tapped, it
/// turns light and lifts, the magnifier and the prompt slide to the left,
/// and a round ✕ slides in beside it. ✕ clears, hides the keyboard and
/// brings the rest state back.
///
/// The parent owns the focus, so it can focus the field itself (the
/// magnifier in the feed header) or let a scroll dismiss the keyboard.
public struct SearchBar: View {
    @Binding private var text: String
    private let prompt: String
    private let focused: FocusState<Bool>.Binding
    private let onSubmit: () -> Void
    private let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let height: CGFloat = 44

    public init(text: Binding<String>, prompt: String = "Поиск", focused: FocusState<Bool>.Binding,
                onSubmit: @escaping () -> Void = {}, onCancel: @escaping () -> Void = {}) {
        _text = text
        self.prompt = prompt
        self.focused = focused
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    /// Typing, or holding a query after the keyboard went away.
    private var isActive: Bool { focused.wrappedValue || !text.isEmpty }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0.18)
    }

    public var body: some View {
        HStack(spacing: Spacing.s) {
            field
            if isActive {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .frame(width: Self.height, height: Self.height)
                        .background(Circle().fill(RaisedStyle.fill).shadow(color: RaisedStyle.shadow, radius: 10, y: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(RaisedPressStyle())
                .accessibilityLabel("Отменить поиск")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(motion, value: isActive)
        .animation(motion, value: text.isEmpty)
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.vetkaSecondaryText)
            ZStack(alignment: .leading) {
                Text(prompt)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
                    .opacity(text.isEmpty ? 1 : 0)
                    .accessibilityHidden(true)
                TextField("", text: $text)
                    .focused(focused)
                    .submitLabel(.search)
                    .onSubmit(onSubmit)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .tint(Color.vetkaBrand)
                    .accessibilityLabel(prompt)
                    .accessibilityIdentifier("search.field")
            }
            // At rest the pair is as wide as the prompt, so it can sit in
            // the middle; active, the text takes the whole field.
            .fixedSize(horizontal: !isActive, vertical: false)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color(uiColor: Palette.iconSecondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить")
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: isActive ? .leading : .center)
        .frame(height: Self.height)
        .background {
            Capsule()
                .fill(isActive ? RaisedStyle.fill : Self.restFill)
                .shadow(color: isActive ? RaisedStyle.shadow : .clear, radius: 10, y: 2)
        }
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
    }

    private func cancel() {
        text = ""
        focused.wrappedValue = false
        onCancel()
    }

    /// At rest: a grey well, like the system field but on our palette.
    private static let restFill = Color(uiColor: Palette.surfaceTertiary)
    // Active, it is raised like the round buttons (RaisedStyle).
}
