import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = VaultStore()
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    @State private var expandedFolderIDs: Set<String> = []

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            sidebar
        } detail: {
            detail
        }
        .task {
            await store.loadVault()
            syncExpandedFolders(with: store.rootItems)
        }
        .onChange(of: scenePhase) {
            let newPhase = scenePhase
            guard newPhase == .active else {
                return
            }

            Task {
                await store.reloadFromDisk()
                syncExpandedFolders(with: store.rootItems)
            }
        }
        .onChange(of: store.rootItems) {
            syncExpandedFolders(with: store.rootItems)
        }
        .onChange(of: store.selectedNote?.id) {
            revealSelectedNote()
        }
        .alert("Storage Unavailable", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                store.dismissError()
            }
        } message: {
            Text(store.lastError ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if store.filteredItems.isEmpty, store.isLoading {
                ProgressView("Loading Vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.filteredItems.isEmpty {
                ContentUnavailableView(
                    store.searchText.isEmpty ? "No Notes Yet" : "No Matches",
                    systemImage: store.searchText.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(store.searchText.isEmpty ? "Create a note or folder to start building your vault." : "Try a different search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    SidebarTreeView(
                        items: store.filteredItems,
                        depth: 0,
                        expandedFolderIDs: expandedFolderIDs,
                        selectedNoteID: store.selectedNote?.id,
                        searchText: store.searchText,
                        onToggleFolder: toggleFolder,
                        onSelectNote: select(note:),
                        onCreateNote: createNote(in:),
                        onCreateFolder: createFolder(in:),
                        onDeleteNote: delete(note:)
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }
                .background(Color.clear)
            }
        }
        .searchable(text: searchBinding, prompt: "Search files")
        .navigationTitle("Vault")
        .modifier(NavigationSubtitleModifier(subtitle: store.storageDescription))
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    createNote(in: nil)
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }

                Button {
                    createFolder(in: nil)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }

                Button {
                    Task {
                        await store.reloadFromDisk()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var detail: some View {
        Group {
            if let note = store.selectedNote {
                ObsidianEditorView(
                    note: note,
                    text: editorBinding,
                    syncStatus: store.syncStatus,
                    isUsingICloud: store.isUsingICloud,
                    isSaving: store.isSaving
                )
            } else if store.isLoading {
                ProgressView("Loading Vault...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Select a Note",
                    systemImage: "sidebar.left",
                    description: Text("Choose a note from the vault or create a new one.")
                )
            }
        }
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { store.editorText },
            set: { store.updateEditorText($0) }
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { store.searchText },
            set: { store.searchText = $0 }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.lastError != nil }, set: { _ in store.dismissError() })
    }

    private func toggleFolder(_ id: String) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
        }
    }

    private func createNote(in parentURL: URL?) {
        Task {
            await store.createNote(in: parentURL)
            revealSelectedNote()
        }
    }

    private func createFolder(in parentURL: URL?) {
        Task {
            if let folderURL = await store.createFolder(in: parentURL) {
                expandedFolderIDs.insert(folderURL.path(percentEncoded: false))
                if let parentURL {
                    expandedFolderIDs.insert(parentURL.path(percentEncoded: false))
                }
            }
        }
    }

    private func select(note: NoteSummary) {
        preferredCompactColumn = .detail
        Task {
            await store.selectNote(withID: note.id)
        }
    }

    private func delete(note: NoteSummary) {
        Task {
            await store.delete(notes: [note])
        }
    }

    private func syncExpandedFolders(with items: [VaultItem]) {
        let rootFolderIDs = items.compactMap { item in
            item.isFolder ? item.id : nil
        }
        expandedFolderIDs.formUnion(rootFolderIDs)
        revealSelectedNote()
    }

    private func revealSelectedNote() {
        guard let noteID = store.selectedNote?.id else {
            return
        }

        expandedFolderIDs.formUnion(ancestorFolderIDs(forNoteID: noteID, in: store.rootItems))
    }

    private func ancestorFolderIDs(forNoteID noteID: String, in items: [VaultItem]) -> [String] {
        for item in items where item.isFolder {
            if let nestedMatch = matchingFolderPath(forNoteID: noteID, in: item) {
                return nestedMatch
            }
        }

        return []
    }

    private func matchingFolderPath(forNoteID noteID: String, in folder: VaultItem) -> [String]? {
        for child in folder.children {
            if child.note?.id == noteID {
                return [folder.id]
            }

            if child.isFolder, let nestedPath = matchingFolderPath(forNoteID: noteID, in: child) {
                return [folder.id] + nestedPath
            }
        }

        return nil
    }
}

private struct SidebarTreeView: View {
    let items: [VaultItem]
    let depth: Int
    let expandedFolderIDs: Set<String>
    let selectedNoteID: String?
    let searchText: String
    let onToggleFolder: (String) -> Void
    let onSelectNote: (NoteSummary) -> Void
    let onCreateNote: (URL?) -> Void
    let onCreateFolder: (URL?) -> Void
    let onDeleteNote: (NoteSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.id) { item in
                itemView(item)
            }
        }
    }

    private func itemView(_ item: VaultItem) -> AnyView {
        if item.isFolder {
            return AnyView(folderRow(item))
        }

        if let note = item.note {
            return AnyView(noteRow(note))
        }

        return AnyView(EmptyView())
    }

    private func folderRow(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.14)) {
                    onToggleFolder(item.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expandedFolderIDs.contains(item.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: expandedFolderIDs.contains(item.id) ? "folder.fill" : "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(item.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 16)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("New Note") {
                    onCreateNote(item.url)
                }

                Button("New Folder") {
                    onCreateFolder(item.url)
                }
            }

            if expandedFolderIDs.contains(item.id) {
                SidebarTreeView(
                    items: item.children,
                    depth: depth + 1,
                    expandedFolderIDs: expandedFolderIDs,
                    selectedNoteID: selectedNoteID,
                    searchText: searchText,
                    onToggleFolder: onToggleFolder,
                    onSelectNote: onSelectNote,
                    onCreateNote: onCreateNote,
                    onCreateFolder: onCreateFolder,
                    onDeleteNote: onDeleteNote
                )
            }
        }
    }

    private func noteRow(_ note: NoteSummary) -> some View {
        let isSelected = selectedNoteID == note.id
        let showsPath = !searchText.isEmpty || note.relativePath.contains("/")

        return Button {
            onSelectNote(note)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.name)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)

                    if showsPath {
                        Text(note.relativePath)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .secondary : .tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16 + 18)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.secondary.opacity(0.14) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Note in Folder") {
                onCreateNote(note.url.deletingLastPathComponent())
            }

            Button("New Folder in Folder") {
                onCreateFolder(note.url.deletingLastPathComponent())
            }

            Divider()

            Button("Delete Note", role: .destructive) {
                onDeleteNote(note)
            }
        }
    }
}

private struct NavigationSubtitleModifier: ViewModifier {
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}
