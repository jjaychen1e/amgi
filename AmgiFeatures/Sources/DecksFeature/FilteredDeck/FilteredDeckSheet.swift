//
//  FilteredDeckSheet.swift
//  DecksFeature
//
//  Created by Junjie Chen on 22.10.2026.
//

import SwiftUI
import Theme
import AnkiKit
import AnkiClients
import Dependencies

/// Create or edit an Anki filtered deck: a name, a native Anki search, a
/// card limit and order, and whether answers reschedule the cards. Saving
/// rebuilds the deck; `onSaved` receives it so the caller can open it.
struct FilteredDeckSheet: View {
    let onSaved: (DeckInfo) -> Void

    @State private var model: FilteredDeckFormModel
    @State private var errorMessage: String?
    @State private var picker: PickerKind?
    @Environment(\.dismiss) private var dismiss

    init(deckId: DeckID = DeckID(0), onSaved: @escaping (DeckInfo) -> Void) {
        self.onSaved = onSaved
        _model = State(initialValue: FilteredDeckFormModel(deckId: deckId))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.isNew ? "New Filtered Deck" : "Edit Filtered Deck")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .alert(
                    model.isNew ? "Couldn't create filtered deck" : "Couldn't save filtered deck",
                    isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                    presenting: errorMessage
                ) { _ in
                    Button("OK") {}
                } message: { message in
                    Text(message)
                }
        }
        .interactiveDismissDisabled(model.isSaving)
        .task { await model.load() }
        .task(id: MatchKey(search: model.search, isLoaded: model.isLoaded)) {
            // Debounce typing; a newer keystroke cancels this task.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.refreshMatchCount()
        }
        .sheet(item: $picker) { kind in
            FilteredDeckTermPicker(
                kind: kind.selectionKind,
                load: { try await model.pickerItems(kind.selectionKind) },
                onAdd: { await model.addTerms($0) }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load filtered deck",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded:
            form
        }
    }

    private var form: some View {
        Form {
            Section("Name") {
                TextField("Deck name", text: $model.name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
            }

            Section {
                TextField("tag:travel", text: $model.search, axis: .vertical)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .lineLimit(1...4)
                    .accessibilityLabel("Search")
                HStack {
                    Button { picker = .tags } label: {
                        Label("Add Tags", systemImage: "tag")
                    }
                    Spacer()
                    Button { picker = .decks } label: {
                        Label("Add Decks", systemImage: "folder")
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Search")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(matchSummary)
                        .accessibilityIdentifier("filteredDeck.matchSummary")
                    Text("""
                    Pick tags or decks, or type Anki search syntax such as deck:"English" tag:shopping. \
                    Cards are picked whether due or not — add is:due for due cards only. \
                    Suspended and buried cards, and cards in another filtered deck, are skipped.
                    """)
                }
            }

            Section("Cards") {
                LabeledContent("Limit") {
                    TextField("100", text: $model.limitText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Card limit")
                }
                Picker("Order", selection: $model.order) {
                    ForEach(model.orderOptions) { option in
                        Text(option.label).tag(option.order)
                    }
                }
            }

            Section {
                Toggle("Reschedule cards based on my answers", isOn: $model.reschedule)
            } footer: {
                Text(model.reschedule
                     ? "On: answers update each card's real review schedule, as in its home deck."
                     : "Off: preview only. Answers don't change when cards are next due.")
            }
        }
        .disabled(model.isSaving)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
                .disabled(model.isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button(model.isNew ? "Create" : "Save") {
                    Task { await save() }
                }
                .disabled(!model.canSave)
            }
        }
    }

    private var matchSummary: String {
        switch model.match {
        case .counting:
            return "Counting matching cards…"
        case .invalid(let message):
            return "Search isn't valid yet: \(message)"
        case .count(0):
            return "No cards match this search."
        case .count(let count):
            let noun = count == 1 ? "1 card matches" : "\(count) cards match"
            guard let limit = model.limit else { return noun + "." }
            return count <= limit ? "\(noun) — all will be added." : "\(noun) — the first \(limit) will be added."
        }
    }

    private func save() async {
        switch await model.save() {
        case .success(let deck):
            onSaved(deck)
            dismiss()
        case .failure(.inFlight):
            break
        case .failure(.message(let message)):
            errorMessage = message
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    withDependencies {
        $0.deckClient = .previewValue
    } operation: {
        FilteredDeckSheet { _ in }
    }
}
#endif

private enum PickerKind: Identifiable {
    case tags
    case decks

    var id: Self { self }

    var selectionKind: SearchTermSelection.Kind {
        switch self {
        case .tags: .tag
        case .decks: .deck
        }
    }
}

private struct MatchKey: Equatable {
    let search: String
    let isLoaded: Bool
}
