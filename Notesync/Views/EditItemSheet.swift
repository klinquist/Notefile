import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct EditItemSheet: View {
    private enum Field: Hashable {
        case name
    }

    @Environment(\.dismiss) private var dismiss

    let kind: BrowserItem.Kind
    let initialName: String
    let initialAccentStyle: AccentStyle
    let submit: (String, AccentStyle) async throws -> Void

    @State private var name: String
    @State private var accentStyle: AccentStyle
    @State private var customColor: Color
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var focusedField: Field?

    init(
        kind: BrowserItem.Kind,
        initialName: String,
        initialAccentStyle: AccentStyle,
        submit: @escaping (String, AccentStyle) async throws -> Void
    ) {
        self.kind = kind
        self.initialName = initialName
        self.initialAccentStyle = initialAccentStyle
        self.submit = submit
        _name = State(initialValue: initialName)
        _accentStyle = State(initialValue: initialAccentStyle)
        _customColor = State(initialValue: initialAccentStyle.color)
    }

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
                                TextField(kind == .note ? "Note Name" : "Folder Name", text: $name)
                                    .focused($focusedField, equals: .name)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        guard canSubmit else { return }
                                        save()
                                    }
                                    .textFieldStyle(.plain)
                                    .font(.system(.title3, design: .rounded).weight(.semibold))
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

                                customColorPicker
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
            .navigationTitle(kind == .note ? "Edit Note" : "Edit Folder")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .task {
                guard focusedField == nil else { return }
                try? await Task.sleep(for: .milliseconds(150))
                focusedField = .name
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
            customColor = style.color
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

    private var customColorPicker: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentStyle.color.opacity(0.18))
                    .frame(width: 46, height: 46)

                Circle()
                    .fill(customColor)
                    .frame(width: 28, height: 28)

                if isCustomColorSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Custom")
                    .font(.subheadline.weight(.semibold))
                Text("Pick any color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ColorPicker("Custom Color", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: customColor) { _, newValue in
                    accentStyle = .custom(from: newValue)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isCustomColorSelected ? customColor.opacity(0.14) : sheetBaseColor.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isCustomColorSelected ? customColor.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(sheetBaseColor.opacity(0.88))
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

    private var isCustomColorSelected: Bool {
        if case .custom = accentStyle {
            return true
        }
        return false
    }

    private func save() {
        guard canSubmit else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await submit(trimmedName, accentStyle)
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
