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
            } header: {
                Text("Search")
            } footer: {
                Text("""
                Anki search syntax, e.g. tag:travel or deck:"English" tag:shopping. \
                Cards are picked from any deck, whether due or not — add is:due to limit to due cards. \
                Suspended and buried cards, and cards in another filtered deck, are skipped.
                """)
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
