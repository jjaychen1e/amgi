//
//  FilteredDeckTermPicker.swift
//  DecksFeature
//
//  Created by Junjie Chen on 23.10.2026.
//

import SwiftUI
import Theme
import AnkiKit

/// Pick tags or decks to fold into a filtered deck's search, so nobody has
/// to remember `tag:` / `deck:"…"` syntax or how to quote a name. Picked
/// names are included (any of them) or excluded (none of them).
struct FilteredDeckTermPicker: View {
    let kind: SearchTermSelection.Kind
    let load: () async throws -> [String]
    /// Returns an error message to show, or nil when the search was updated.
    let onAdd: (SearchTermSelection) async -> String?

    @State private var items: [String]?
    @State private var loadError: String?
    @State private var selected: Set<String> = []
    @State private var excluded = false
    @State private var query = ""
    @State private var isAdding = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(kind == .tag ? "Add Tags" : "Add Decks")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .alert(
                    "Couldn't add to the search",
                    isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                    presenting: errorMessage
                ) { _ in
                    Button("OK") {}
                } message: { message in
                    Text(message)
                }
        }
        .task { await loadItems() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            ContentUnavailableView(
                kind == .tag ? "Couldn't load tags" : "Couldn't load decks",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if let items {
            if items.isEmpty {
                ContentUnavailableView(
                    kind == .tag ? "No Tags" : "No Decks",
                    systemImage: kind == .tag ? "tag" : "folder",
                    description: Text(kind == .tag ? "Your notes don't have any tags yet." : "There are no decks to pick from.")
                )
            } else {
                list(items)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ items: [String]) -> some View {
        List {
            Section {
                Picker("Match", selection: $excluded) {
                    Text("Include").tag(false)
                    Text("Exclude").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } footer: {
                Text(explanation)
            }

            Section {
                ForEach(filtered(items), id: \.self) { name in
                    row(name)
                }
            }
        }
        .searchable(text: $query, prompt: kind == .tag ? "Search tags" : "Search decks")
    }

    private func row(_ name: String) -> some View {
        let isSelected = selected.contains(name)
        let components = name.components(separatedBy: "::")
        // The full path while searching; the indented leaf in the tree.
        let showsTree = query.isEmpty
        return Button {
            if isSelected { selected.remove(name) } else { selected.insert(name) }
        } label: {
            HStack {
                Text(showsTree ? (components.last ?? name) : name)
                    .foregroundStyle(palette.textPrimary)
                    .padding(.leading, showsTree ? CGFloat(components.count - 1) * 16 : 0)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(palette.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isAdding {
                ProgressView()
            } else {
                Button(selected.isEmpty ? "Add" : "Add (\(selected.count))") {
                    Task { await add() }
                }
                .disabled(selected.isEmpty)
            }
        }
    }

    private var explanation: String {
        switch (kind, excluded) {
        case (.tag, false): "Cards with any of the selected tags, including their subtags."
        case (.tag, true): "Leave out cards with any of the selected tags."
        case (.deck, false): "Cards from any of the selected decks, including their subdecks."
        case (.deck, true): "Leave out cards from the selected decks."
        }
    }

    private func filtered(_ items: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func loadItems() async {
        do {
            items = try await load()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        // Keep the list's order rather than the order of the taps.
        let names = (items ?? []).filter(selected.contains)
        if let failure = await onAdd(SearchTermSelection(kind: kind, names: names, excluded: excluded)) {
            errorMessage = failure
        } else {
            dismiss()
        }
    }
}

#if DEBUG
#Preview {
    FilteredDeckTermPicker(
        kind: .tag,
        load: { ["shopping", "travel", "travel::airport", "travel::hotel", "verbs"] },
        onAdd: { _ in nil }
    )
}
#endif
