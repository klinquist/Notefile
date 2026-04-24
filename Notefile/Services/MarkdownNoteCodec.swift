import Foundation

enum MarkdownNoteCodec {
    private static let metadataHeading = "## Notefile"
    private static let storageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func storageTimestampString(for date: Date) -> String {
        storageDateFormatter.string(from: canonicalStorageTimestamp(for: date))
    }

    static func canonicalStorageTimestamp(for date: Date) -> Date {
        storageDateFormatter.date(from: storageDateFormatter.string(from: date)) ?? date
    }

    static func decode(relativePath: String, markdown: String, fallbackMetadata: NoteMetadata) -> NoteDocument {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let fallbackTitle = (((relativePath as NSString).lastPathComponent) as NSString).deletingPathExtension

        var cursor = 0
        var title = fallbackTitle.isEmpty ? "Untitled Note" : fallbackTitle
        if let firstLine = lines.first, firstLine.hasPrefix("# ") {
            title = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = 1
            if cursor < lines.count, lines[cursor].isEmpty {
                cursor += 1
            }
        }

        var metadata = fallbackMetadata
        if cursor < lines.count, lines[cursor] == metadataHeading {
            cursor += 1
            while cursor < lines.count, lines[cursor].isEmpty {
                cursor += 1
            }

            while cursor < lines.count {
                let line = lines[cursor]
                if line.hasPrefix("- Emoji: ") {
                    metadata.emoji = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines).ifBlank(fallbackMetadata.emoji)
                    cursor += 1
                } else if line.hasPrefix("- Color: ") {
                    let rawValue = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                    metadata.accentStyle = AccentStyle(rawValue: rawValue) ?? metadata.accentStyle
                    cursor += 1
                } else if line.isEmpty {
                    cursor += 1
                } else {
                    break
                }
            }
        }

        var entries: [NoteEntry] = []
        var currentTimestamp: Date?
        var buffer: [String] = []

        func flushEntry() {
            guard let currentTimestamp else { return }
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            entries.append(NoteEntry(timestamp: currentTimestamp, text: text))
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines.dropFirst(cursor) {
            if line.hasPrefix("## ") {
                flushEntry()
                let rawDate = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentTimestamp = storageDateFormatter.date(from: rawDate)
            } else if currentTimestamp != nil {
                buffer.append(line)
            }
        }

        flushEntry()

        return NoteDocument(
            relativePath: relativePath,
            title: title.isEmpty ? "Untitled Note" : title,
            metadata: metadata,
            entries: entries
        )
    }

    static func encode(_ note: NoteDocument) -> String {
        var chunks: [String] = [
            "# \(note.title.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty(or: "Untitled Note"))",
            "",
            metadataHeading,
            "- Emoji: \(note.metadata.emoji.ifBlank(NoteMetadata.default.emoji))",
            "- Color: \(note.metadata.accentStyle.rawValue)",
            ""
        ]

        for entry in note.entries {
            chunks.append("## \(storageTimestampString(for: entry.timestamp))")
            if !entry.text.isEmpty {
                chunks.append(entry.text)
            }
            chunks.append("")
        }

        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

private extension String {
    func nonEmpty(or fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }
}
