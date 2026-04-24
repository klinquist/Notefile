import SwiftUI

struct NotefileSettingsView: View {
    @AppStorage(AppPreferences.newEntryThresholdMinutesKey)
    private var newEntryThresholdMinutes = AppPreferences.defaultNewEntryThresholdMinutes

    @AppStorage(AppPreferences.noteFontSizeKey)
    private var noteFontSize = AppPreferences.defaultNoteFontSize

#if os(macOS)
    @EnvironmentObject private var localMirrorSyncService: LocalMirrorSyncService
#endif

    var body: some View {
        Form {
            notesSection

#if os(macOS)
            mirrorSection
#endif
        }
#if os(macOS)
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 540, minHeight: 320)
#endif
    }

    private var notesSection: some View {
        Section("Notes") {
            Stepper(value: thresholdBinding, in: 0...60) {
                LabeledContent("New Entry Threshold") {
                    Text(thresholdLabel)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Note Font Size") {
                    Text("\(Int(noteFontSize.rounded()))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(value: fontSizeBinding, in: AppPreferences.minimumNoteFontSize...AppPreferences.maximumNoteFontSize, step: 1)

                Text("Preview text size")
                    .font(.system(size: fontSizeBinding.wrappedValue))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

#if os(macOS)
    private var mirrorSection: some View {
        Section("Mirror") {
            LabeledContent("Mirror Folder") {
                Text(localMirrorSyncService.mirroredFolderURL?.path ?? "Not configured")
                    .foregroundStyle(.secondary)
            }

            Text(localMirrorSyncService.statusText)
                .foregroundStyle(.secondary)

            HStack {
                Button("Choose Folder") {
                    localMirrorSyncService.chooseFolder()
                }

                Button("Sync Now") {
                    Task {
                        await localMirrorSyncService.syncNow()
                    }
                }
                .disabled(localMirrorSyncService.mirroredFolderURL == nil)
            }
        }
    }
#endif

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { AppPreferences.normalizedNewEntryThresholdMinutes(newEntryThresholdMinutes) },
            set: { newEntryThresholdMinutes = AppPreferences.normalizedNewEntryThresholdMinutes($0) }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { AppPreferences.normalizedNoteFontSize(noteFontSize) },
            set: { noteFontSize = AppPreferences.normalizedNoteFontSize($0) }
        )
    }

    private var thresholdLabel: String {
        let value = thresholdBinding.wrappedValue
        if value == 0 {
            return "Disabled"
        }
        if value == 1 {
            return "1 minute"
        }
        return "\(value) minutes"
    }
}
