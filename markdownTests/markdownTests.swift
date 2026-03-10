import Foundation
import Testing
@testable import markdown

struct markdownTests {
    @Test
    func sanitizeFilenameRemovesInvalidCharacters() {
        #expect(VaultStore.sanitizeFilename("  Daily:/\\ Notes?*  ") == "Daily Notes")
    }

    @Test
    func uniqueFilenameIncrementsForCollisions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstNote = directory.appending(path: "Untitled Note.md", directoryHint: .notDirectory)
        try Data().write(to: firstNote)

        let nextFilename = try VaultStore.uniqueFilename(
            in: directory,
            baseName: "Untitled Note",
            fileManager: .default
        )

        #expect(nextFilename == "Untitled Note 2.md")
    }

    @Test
    func uniqueDirectoryNameIncrementsForCollisions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(
            at: directory.appending(path: "New Folder", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )

        let nextDirectoryName = try VaultStore.uniqueDirectoryName(
            in: directory,
            baseName: "New Folder",
            fileManager: .default
        )

        #expect(nextDirectoryName == "New Folder 2")
    }

    @Test
    func loadItemsBuildsNestedFoldersAndRelativePaths() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ideasFolder = directory.appending(path: "Ideas", directoryHint: .isDirectory)
        let draftsFolder = ideasFolder.appending(path: "Drafts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: draftsFolder, withIntermediateDirectories: true)

        try "# Home\n\nRoot note".write(
            to: directory.appending(path: "Home.md", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        try "## Launch Plan\n\nNested note".write(
            to: draftsFolder.appending(path: "Plan.md", directoryHint: .notDirectory),
            atomically: true,
            encoding: .utf8
        )

        let items = try await VaultStore.loadItems(in: directory, fileManager: .default)

        let ideas = try #require(items.first(where: { $0.isFolder && $0.name == "Ideas" }))
        #expect(ideas.relativePath == "Ideas")

        let drafts = try #require(ideas.children.first(where: { $0.isFolder && $0.name == "Drafts" }))
        let plan = try #require(drafts.children.first?.note)

        #expect(plan.name == "Plan")
        #expect(plan.title == "Launch Plan")
        #expect(plan.relativePath == "Ideas/Drafts/Plan.md")
    }

    @Test
    func createFolderCreatesUniqueNamesAtSameLevel() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await VaultStore.createFolder(in: directory, fileManager: .default)
        let second = try await VaultStore.createFolder(in: directory, fileManager: .default)

        #expect(first.lastPathComponent == "New Folder")
        #expect(second.lastPathComponent == "New Folder 2")
    }

    @Test
    func createNoteCreatesMarkdownInsideNestedFolder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let parentFolder = directory.appending(path: "Writing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parentFolder, withIntermediateDirectories: false)

        let noteURL = try await VaultStore.createNote(in: parentFolder, fileManager: .default)
        let items = try await VaultStore.loadItems(in: directory, fileManager: .default)

        #expect(noteURL.deletingLastPathComponent() == parentFolder)

        let writing = try #require(items.first(where: { $0.isFolder && $0.name == "Writing" }))
        let note = try #require(writing.children.first?.note)
        #expect(note.relativePath == "Writing/Untitled Note.md")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
