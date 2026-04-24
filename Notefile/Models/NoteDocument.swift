import Foundation

struct NoteEntry: Identifiable, Equatable {
    var id: UUID
    var timestamp: Date
    var text: String

    init(id: UUID = UUID(), timestamp: Date, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}

struct NoteDocument: Identifiable, Equatable {
    var relativePath: String
    var title: String
    var metadata: NoteMetadata
    var entries: [NoteEntry]

    var id: String { relativePath }

    var parentFolderPath: String? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? nil : parent
    }

    var fileName: String {
        (((relativePath as NSString).lastPathComponent) as NSString).deletingPathExtension
    }
}
