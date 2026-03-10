import Foundation

struct NoteSummary: Identifiable, Equatable, Sendable {
    nonisolated let url: URL
    nonisolated let name: String
    nonisolated let title: String
    nonisolated let preview: String
    nonisolated let modifiedAt: Date
    nonisolated let relativePath: String

    nonisolated var id: String {
        url.path(percentEncoded: false)
    }
}

enum VaultItemKind: Equatable, Sendable {
    case folder
    case note(NoteSummary)
}

struct VaultItem: Identifiable, Equatable, Sendable {
    nonisolated let url: URL
    nonisolated let name: String
    nonisolated let relativePath: String
    nonisolated let kind: VaultItemKind
    nonisolated var children: [VaultItem]

    nonisolated var id: String {
        url.path(percentEncoded: false)
    }

    nonisolated var isFolder: Bool {
        if case .folder = kind {
            return true
        }

        return false
    }

    nonisolated var note: NoteSummary? {
        if case let .note(note) = kind {
            return note
        }

        return nil
    }

    nonisolated init(folderURL: URL, relativePath: String, children: [VaultItem]) {
        self.url = folderURL
        self.name = folderURL.lastPathComponent
        self.relativePath = relativePath
        self.kind = .folder
        self.children = children
    }

    nonisolated init(note: NoteSummary) {
        self.url = note.url
        self.name = note.name
        self.relativePath = note.relativePath
        self.kind = .note(note)
        self.children = []
    }
}
