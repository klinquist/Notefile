import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct CreateItemSheet: View {
    private enum Field: Hashable {
        case name
        case emoji
    }

    enum Mode {
        case folder
        case note

        var title: String {
            switch self {
            case .folder: "New Folder"
            case .note: "New Note"
            }
        }

        var defaultEmoji: String {
            switch self {
            case .folder: "📁"
            case .note: "📝"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    let parentLabel: String?
    let suggestedAccentStyle: AccentStyle
    let submit: (String, String, AccentStyle) async throws -> Void

    @State private var name = ""
    @State private var emoji = ""
    @State private var accentStyle: AccentStyle = .mint
    @State private var errorMessage: String?
    @State private var isSaving = false
#if os(iOS)
    @State private var isEmojiKeyboardFocused = false
#endif
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        accentStyle.color.opacity(0.24),
                        accentStyle.color.opacity(0.08),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        detailCard {
                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Name")
                                HStack(spacing: 12) {
                                    TextField(mode == .note ? "Note Name" : "Folder Name", text: $name)
                                        .focused($focusedField, equals: .name)
                                        .submitLabel(.done)
                                        .onSubmit {
                                            guard canSubmit else { return }
                                            save()
                                        }
                                        .textFieldStyle(.plain)
                                        .font(.system(.title3, design: .rounded).weight(.semibold))

#if os(iOS)
                                    Button {
                                        focusedField = nil
                                        Task { @MainActor in
                                            isEmojiKeyboardFocused = true
                                        }
                                    } label: {
                                        Text(displayEmoji)
                                            .font(.system(size: 28))
                                            .frame(width: 36, alignment: .trailing)
                                    }
                                    .buttonStyle(.plain)
#else
                                    MacEmojiPickerField(
                                        text: $emoji,
                                        displayedEmoji: displayEmoji
                                    )
                                    .frame(width: 36, height: 32)
#endif
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(inputBackground)
                            }
                        }

                        detailCard {
                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Color")

                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)
                                    ],
                                    spacing: 12
                                ) {
                                    ForEach(AccentStyle.allCases) { style in
                                        colorButton(for: style)
                                    }
                                }
                            }
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.red.opacity(0.10))
                                )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
#if os(iOS)
            .overlay(alignment: .topLeading) {
                EmojiKeyboardField(
                    text: $emoji,
                    displayedEmoji: displayEmoji,
                    isFocused: $isEmojiKeyboardFocused
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
#endif
            .navigationTitle(mode.title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task {
                if emoji.isEmpty {
                    emoji = mode.defaultEmoji
                }

                accentStyle = suggestedAccentStyle

                guard focusedField == nil else { return }
                try? await Task.sleep(for: .milliseconds(150))
#if os(iOS)
                isEmojiKeyboardFocused = false
#endif
                focusedField = .name
            }
            .onChange(of: focusedField) { _, newValue in
#if os(iOS)
                if newValue != .emoji {
                    isEmojiKeyboardFocused = false
                }
#endif
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.title) {
                        save()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(sheetCardColor.opacity(0.92))
            )
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.8)
    }

    private func colorButton(for style: AccentStyle) -> some View {
        Button {
            accentStyle = style
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(style.color.opacity(0.18))
                        .frame(width: 48, height: 48)

                    Circle()
                        .fill(style.color)
                        .frame(width: 28, height: 28)

                    if accentStyle == style {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                Text(style.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(accentStyle == style ? style.color.opacity(0.14) : sheetBaseColor.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(accentStyle == style ? style.color.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(sheetBaseColor.opacity(0.88))
    }

    private var locationLabel: String {
        if let parentLabel {
            return parentLabel
        }
        return "Top Level"
    }

    private var displayEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? mode.defaultEmoji : emoji
    }

    private var sheetBaseColor: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .systemBackground)
#endif
    }

    private var sheetCardColor: Color {
#if os(macOS)
        Color(nsColor: .controlBackgroundColor)
#else
        Color(uiColor: .secondarySystemGroupedBackground)
#endif
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private func save() {
        guard canSubmit else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await submit(name, emoji, accentStyle)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSaving = false
                }
            }
        }
    }
}

#if os(iOS)
private struct EmojiKeyboardField: UIViewRepresentable {
    @Binding var text: String
    let displayedEmoji: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> EmojiUITextField {
        let textField = EmojiUITextField()
        textField.delegate = context.coordinator
        textField.textAlignment = .right
        textField.font = UIFont.systemFont(ofSize: 28)
        textField.tintColor = .clear
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.smartDashesType = .no
        textField.smartQuotesType = .no
        textField.smartInsertDeleteType = .no
        textField.text = displayedEmoji
        textField.addTarget(context.coordinator, action: #selector(Coordinator.textDidChange(_:)), for: .editingChanged)
        return textField
    }

    func updateUIView(_ uiView: EmojiUITextField, context: Context) {
        if uiView.text != displayedEmoji {
            uiView.text = displayedEmoji
        }

        if isFocused {
            if !uiView.isFirstResponder {
                uiView.becomeFirstResponder()
            }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textDidChange(_ textField: UITextField) {
            let raw = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let lastCharacter = raw.last {
                text.wrappedValue = String(lastCharacter)
            } else {
                text.wrappedValue = ""
            }
        }
    }
}

private final class EmojiUITextField: UITextField {
    override var textInputContextIdentifier: String? { "" }

    override var textInputMode: UITextInputMode? {
        for inputMode in UITextInputMode.activeInputModes where inputMode.primaryLanguage == "emoji" {
            return inputMode
        }
        return super.textInputMode
    }
}
#endif

#if os(macOS)
private struct MacEmojiPickerField: NSViewRepresentable {
    @Binding var text: String
    let displayedEmoji: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> EmojiPickerTextField {
        let textField = EmojiPickerTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.alignment = .right
        textField.font = .systemFont(ofSize: 28)
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.stringValue = displayedEmoji
        return textField
    }

    func updateNSView(_ nsView: EmojiPickerTextField, context: Context) {
        if nsView.stringValue != displayedEmoji {
            nsView.stringValue = displayedEmoji
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            let raw = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let lastCharacter = raw.last {
                text.wrappedValue = String(lastCharacter)
                textField.stringValue = String(lastCharacter)
            } else {
                text.wrappedValue = ""
            }
        }
    }
}

private final class EmojiPickerTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        NSApp.orderFrontCharacterPalette(nil)
    }
}
#endif
