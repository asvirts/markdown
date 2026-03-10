//
//  VaultStore.swift
//  markdown
//
//  Created by Andrew Virts on 3/10/26.
//

import Foundation
import Combine

@MainActor
final class VaultStore: ObservableObject {
    private let fileManager: FileManager
    private var vaultURL: URL?
    private var saveTask: Task<Void, Never>?

    @Published var rootItems: [VaultItem] = []
    @Published var selectedNote: NoteSummary?
    @Published var editorText = ""
    @Published var searchText = ""
    @Published var storageDescription = "Preparing vault…"
    @Published var syncStatus = "Checking iCloud"
    @Published var isUsingICloud = false
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var lastError: String?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var filteredItems: [VaultItem] {
        guard !searchText.isEmpty else {
            return rootItems
        }

        return Self.filter(items: rootItems, matching: searchText)
    }

    func loadVault() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let location = try await Self.resolveVaultLocation(fileManager: fileManager)
            vaultURL = location.url
            isUsingICloud = location.isUsingICloud
            storageDescription = location.label
            syncStatus = location.isUsingICloud ? "Syncing through iCloud" : "Stored locally on this device"
            try await refreshVault(selecting: selectedNote?.id, reloadSelectedContents: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reloadFromDisk() async {
        guard vaultURL != nil else {
            await loadVault()
            return
        }

        do {
            try await refreshVault(selecting: selectedNote?.id, reloadSelectedContents: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createNote() async {
        await createNote(in: nil)
    }

    func createNote(in parentFolderURL: URL?) async {
        guard let vaultURL else {
            await loadVault()
            return
        }

        do {
            let containerURL = resolvedContainerURL(preferredParentURL: parentFolderURL) ?? vaultURL
            let url = try await Self.createNote(in: containerURL, fileManager: fileManager)
            try await refreshVault(selecting: url.path(percentEncoded: false), reloadSelectedContents: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createFolder(in parentFolderURL: URL?) async -> URL? {
        guard let vaultURL else {
            await loadVault()
            return nil
        }

        do {
            let containerURL = resolvedContainerURL(preferredParentURL: parentFolderURL) ?? vaultURL
            let url = try await Self.createFolder(in: containerURL, fileManager: fileManager)
            try await refreshVault(selecting: selectedNote?.id, reloadSelectedContents: false)
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func delete(notes: [NoteSummary]) async {
        guard !notes.isEmpty else {
            return
        }

        do {
            try await Task.detached(priority: .userInitiated) { [fileManager] in
                for note in notes {
                    if fileManager.fileExists(atPath: note.url.path(percentEncoded: false)) {
                        try fileManager.removeItem(at: note.url)
                    }
                }
            }.value

            let retainedSelection = selectedNote.map { selected in
                notes.contains(where: { $0.id == selected.id }) ? nil : selected.id
            } ?? nil

            try await refreshVault(selecting: retainedSelection, reloadSelectedContents: true)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectNote(withID id: NoteSummary.ID?) async {
        guard let id else {
            selectedNote = nil
            editorText = ""
            return
        }

        guard let note = note(withID: id, in: rootItems) else {
            return
        }

        await loadContents(of: note)
    }

    func updateEditorText(_ text: String) {
        editorText = text
        scheduleSave()
    }

    func dismissError() {
        lastError = nil
    }

    private func loadContents(of note: NoteSummary) async {
        selectedNote = note

        do {
            editorText = try await Self.readContents(of: note.url, fileManager: fileManager)
        } catch {
            editorText = ""
            lastError = error.localizedDescription
        }
    }

    private func scheduleSave() {
        guard let note = selectedNote else {
            return
        }

        saveTask?.cancel()
        let text = editorText

        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else {
                return
            }

            isSaving = true
            defer { isSaving = false }

            do {
                try await Self.write(contents: text, to: note.url)
                try await refreshVault(selecting: note.id, reloadSelectedContents: false)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func refreshVault(selecting selectedID: NoteSummary.ID?, reloadSelectedContents: Bool) async throws {
        guard let vaultURL else {
            return
        }

        let items = try await Self.loadItems(in: vaultURL, fileManager: fileManager)
        rootItems = items
        let notes = Self.flattenNotes(in: items)

        let nextSelection = selectedID.flatMap { id in
            notes.first(where: { $0.id == id })
        } ?? notes.first

        if let nextSelection {
            selectedNote = nextSelection
            if reloadSelectedContents {
                await loadContents(of: nextSelection)
            }
        } else {
            selectedNote = nil
            editorText = ""
        }
    }

    private func resolvedContainerURL(preferredParentURL: URL?) -> URL? {
        if let preferredParentURL {
            return preferredParentURL
        }

        if let selectedNote {
            return selectedNote.url.deletingLastPathComponent()
        }

        return vaultURL
    }

    private func note(withID id: NoteSummary.ID, in items: [VaultItem]) -> NoteSummary? {
        for item in items {
            if let note = item.note, note.id == id {
                return note
            }

            if let note = note(withID: id, in: item.children) {
                return note
            }
        }

        return nil
    }
}

extension VaultStore {
    struct VaultLocation {
        let url: URL
        let label: String
        let isUsingICloud: Bool
    }

    nonisolated static func resolveVaultLocation(fileManager: FileManager) async throws -> VaultLocation {
        if fileManager.ubiquityIdentityToken != nil {
            let ubiquityURL = await Task.detached(priority: .userInitiated) {
                fileManager.url(forUbiquityContainerIdentifier: nil)
            }.value

            if let ubiquityURL {
                let documentsURL = ubiquityURL
                    .appending(path: "Documents", directoryHint: .isDirectory)
                    .appending(path: "Vault", directoryHint: .isDirectory)

                try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)

                return VaultLocation(
                    url: documentsURL,
                    label: "iCloud Drive / Vault",
                    isUsingICloud: true
                )
            }
        }

        let localURL = URL.documentsDirectory.appending(path: "Vault", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: localURL, withIntermediateDirectories: true)

        return VaultLocation(
            url: localURL,
            label: "On My Device / Vault",
            isUsingICloud: false
        )
    }

    nonisolated static func createNote(in vaultURL: URL, fileManager: FileManager) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let filename = try uniqueFilename(in: vaultURL, baseName: "Untitled Note", fileManager: fileManager)
            let noteURL = vaultURL.appending(path: filename, directoryHint: .notDirectory)
            let title = noteURL.deletingPathExtension().lastPathComponent
            let template = "# \(title)\n\n"
            try template.write(to: noteURL, atomically: true, encoding: .utf8)
            return noteURL
        }.value
    }

    nonisolated static func loadItems(in vaultURL: URL, fileManager: FileManager) async throws -> [VaultItem] {
        try await Task.detached(priority: .userInitiated) {
            try loadItems(in: vaultURL, rootURL: vaultURL, fileManager: fileManager)
        }.value
    }

    nonisolated static func createFolder(in parentFolderURL: URL, fileManager: FileManager) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folderName = try uniqueDirectoryName(in: parentFolderURL, baseName: "New Folder", fileManager: fileManager)
            let folderURL = parentFolderURL.appending(path: folderName, directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
            return folderURL
        }.value
    }

    nonisolated static func readContents(of url: URL, fileManager: FileManager) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            if fileManager.isUbiquitousItem(at: url) {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
            }

            return try readContents(of: url, fileManager: fileManager)
        }.value
    }

    nonisolated static func readContents(of url: URL, fileManager: FileManager) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    nonisolated static func write(contents: String, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    nonisolated static func uniqueFilename(in vaultURL: URL, baseName: String, fileManager: FileManager) throws -> String {
        let sanitized = sanitizeFilename(baseName)
        var candidate = "\(sanitized).md"
        var index = 2

        while fileManager.fileExists(atPath: vaultURL.appending(path: candidate).path(percentEncoded: false)) {
            candidate = "\(sanitized) \(index).md"
            index += 1
        }

        return candidate
    }

    nonisolated static func uniqueDirectoryName(in vaultURL: URL, baseName: String, fileManager: FileManager) throws -> String {
        let sanitized = sanitizeFilename(baseName)
        var candidate = sanitized
        var index = 2

        while fileManager.fileExists(atPath: vaultURL.appending(path: candidate, directoryHint: .isDirectory).path(percentEncoded: false)) {
            candidate = "\(sanitized) \(index)"
            index += 1
        }

        return candidate
    }

    nonisolated static func sanitizeFilename(_ rawName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let components = rawName.components(separatedBy: invalidCharacters)
        let collapsed = components.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return collapsed.isEmpty ? "Untitled Note" : collapsed
    }

    nonisolated static func extractTitle(from contents: String, fallback: String) -> String {
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            let headingPrefixCount = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingPrefixCount) {
                let markerIndex = trimmed.index(trimmed.startIndex, offsetBy: headingPrefixCount)
                if markerIndex < trimmed.endIndex, trimmed[markerIndex] == " " {
                    let title = trimmed[trimmed.index(after: markerIndex)...].trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        return title
                    }
                }
            }

            if !trimmed.isEmpty {
                return String(trimmed)
            }
        }

        return fallback
    }

    nonisolated static func notePreview(from contents: String) -> String {
        contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })?
            .prefix(140)
            .description ?? "Empty note"
    }

    nonisolated static func flattenNotes(in items: [VaultItem]) -> [NoteSummary] {
        items.flatMap { item in
            if let note = item.note {
                return [note]
            }

            return flattenNotes(in: item.children)
        }
    }

    nonisolated static func filter(items: [VaultItem], matching searchText: String) -> [VaultItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return items
        }

        return items.compactMap { item in
            if item.isFolder {
                let filteredChildren = filter(items: item.children, matching: query)
                let folderMatches = item.name.localizedCaseInsensitiveContains(query)
                    || item.relativePath.localizedCaseInsensitiveContains(query)

                guard folderMatches || !filteredChildren.isEmpty else {
                    return nil
                }

                return VaultItem(
                    folderURL: item.url,
                    relativePath: item.relativePath,
                    children: filteredChildren.isEmpty ? item.children : filteredChildren
                )
            }

            guard let note = item.note else {
                return nil
            }

            let matches = note.name.localizedCaseInsensitiveContains(query)
                || note.title.localizedCaseInsensitiveContains(query)
                || note.preview.localizedCaseInsensitiveContains(query)
                || note.relativePath.localizedCaseInsensitiveContains(query)

            return matches ? item : nil
        }
    }

    nonisolated private static func loadItems(in directoryURL: URL, rootURL: URL, fileManager: FileManager) throws -> [VaultItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        return try urls
            .compactMap { url -> VaultItem? in
                let values = try url.resourceValues(forKeys: Set(keys))

                if values.isDirectory == true {
                    let children = try loadItems(in: url, rootURL: rootURL, fileManager: fileManager)
                    return VaultItem(
                        folderURL: url,
                        relativePath: relativePath(for: url, relativeTo: rootURL),
                        children: children
                    )
                }

                guard values.isRegularFile == true, url.pathExtension.lowercased() == "md" else {
                    return nil
                }

                let contents = try readContents(of: url, fileManager: fileManager)
                let filename = url.deletingPathExtension().lastPathComponent
                let title = extractTitle(from: contents, fallback: filename)
                let preview = notePreview(from: contents)
                let note = NoteSummary(
                    url: url,
                    name: filename,
                    title: title,
                    preview: preview,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    relativePath: relativePath(for: url, relativeTo: rootURL)
                )

                return VaultItem(note: note)
            }
            .sorted(by: sortItems)
    }

    nonisolated private static func sortItems(_ lhs: VaultItem, _ rhs: VaultItem) -> Bool {
        switch (lhs.isFolder, rhs.isFolder) {
        case (true, false):
            return true
        case (false, true):
            return false
        default:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    nonisolated private static func relativePath(for url: URL, relativeTo rootURL: URL) -> String {
        let rootPath = normalizedPath(rootURL.standardizedFileURL.path(percentEncoded: false))
        let itemPath = normalizedPath(url.standardizedFileURL.path(percentEncoded: false))

        guard itemPath.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return itemPath.replacingOccurrences(of: prefix, with: "")
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        if path.count > 1, path.hasSuffix("/") {
            return String(path.dropLast())
        }

        return path
    }
}
